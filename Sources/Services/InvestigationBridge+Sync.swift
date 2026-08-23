import Foundation

// MARK: - Investigation Bridge: domain syncs
//
// syncBlocky() / syncStocks() push the domain databases into the MaestroDB
// "Investigations" base. See InvestigationBridge.swift for the schema and
// upsert machinery.

extension InvestigationBridge {

    // MARK: - Blocky sync

    /// Push all Blocky investigations (cases, wallets, transactions, notes)
    /// into MaestroDB. Returns counts synced per table.
    func syncBlocky() throws -> [String: Int] {
        try ensureSchema()
        let blocky = BlockyDatabase.shared
        var counts: [String: Int] = [:]

        let investigations = (try? blocky.listInvestigations()) ?? []
        for inv in investigations {
            try upsertRow(tableKey: "cases", sourceKey: "blocky:investigation:\(inv.id)", values: [
                "Name": inv.name,
                "Domain": "Blockchain",
                "Status": "Open",
                "Source": "blocky",
                "Source ID": inv.id,
                "Created": Self.dateOnly(inv.createdAt),
                "Notes": inv.description ?? "",
            ])
            counts["cases", default: 0] += 1

            let wallets = (try? blocky.listWallets(investigationId: inv.id)) ?? []
            for w in wallets {
                try upsertRow(tableKey: "wallets", sourceKey: "blocky:wallet:\(w.id)", values: [
                    "Case": inv.name,
                    "Address": w.address,
                    "Chain": w.chain,
                    "Label": w.userLabel ?? "",
                    "Entity": w.entityLabel ?? "",
                    "Balance": Self.num(w.balance),
                    "Flagged": w.isFlagged ? "true" : "",
                    "Flag Reason": w.flagReason ?? "",
                    "Source ID": w.id,
                ])
                counts["wallets", default: 0] += 1
            }

            if !wallets.isEmpty {
                var seenTxKeys = Set<String>()
                for w in wallets {
                    let txs = (try? blocky.transactionsForWallet(address: w.address, limit: 100)) ?? []
                    for tx in txs {
                        let key = "\(tx.chain):\(tx.txHash)"
                        guard seenTxKeys.insert(key).inserted else { continue }
                        try upsertRow(tableKey: "transactions", sourceKey: "blocky:tx:\(key)", values: [
                            "Hash": tx.txHash,
                            "Chain": tx.chain,
                            "From": tx.fromAddress,
                            "To": tx.toAddress,
                            "Value": String(tx.value),
                            "Fee": Self.num(tx.fee),
                            "Timestamp": tx.timestamp ?? "",
                            "Source ID": key,
                        ])
                        counts["transactions", default: 0] += 1
                    }
                }
            }

            let notes = (try? blocky.notesForInvestigation(investigationId: inv.id)) ?? []
            for n in notes {
                try upsertRow(tableKey: "notes", sourceKey: "blocky:note:\(n.id)", values: [
                    "Subject": inv.name,
                    "Content": n.content,
                    "Author": n.author,
                    "Created": Self.dateOnly(n.createdAt),
                    "Source ID": n.id,
                ])
                counts["notes", default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - Stocks sync

    /// Push all Stocks groups (as cases), tracked stocks, insider txs, proxy
    /// filings, and notes into MaestroDB.
    func syncStocks() throws -> [String: Int] {
        try ensureSchema()
        let stocks = StocksDatabase.shared
        var counts: [String: Int] = [:]

        let groups = (try? stocks.listGroups()) ?? []
        for group in groups {
            try upsertRow(tableKey: "cases", sourceKey: "stocks:group:\(group.id)", values: [
                "Name": group.name,
                "Domain": "Stocky",
                "Status": "Monitoring",
                "Source": "stocks",
                "Source ID": group.id,
                "Created": Self.dateOnly(group.createdAt),
            ])
            counts["cases", default: 0] += 1

            let tracked = (try? stocks.listStocks(groupId: group.id)) ?? []
            for stock in tracked {
                try upsertRow(tableKey: "stocks", sourceKey: "stocks:tracked:\(stock.id)", values: [
                    "Case": group.name,
                    "Symbol": stock.symbol,
                    "Name": stock.name ?? "",
                    "Flagged": stock.isFlagged ? "true" : "",
                    "Flag Reason": stock.flagReason ?? "",
                    "Source ID": stock.id,
                ])
                counts["stocks", default: 0] += 1

                let insiders = (try? stocks.insiderTransactions(symbol: stock.symbol)) ?? []
                for tx in insiders {
                    let txType = ["Purchase", "Sale", "Option Exercise", "Gift"].contains(tx.transactionType)
                        ? tx.transactionType : "Other"
                    try upsertRow(tableKey: "insider", sourceKey: "stocks:insider:\(tx.id)", values: [
                        "Symbol": tx.symbol,
                        "Insider": tx.insiderName,
                        "Title": tx.title ?? "",
                        "Type": txType,
                        "Shares": Self.num(tx.shares),
                        "Price Per Share": Self.num(tx.pricePerShare),
                        "Total Value": Self.num(tx.totalValue),
                        "Date": tx.transactionDate ?? tx.filingDate ?? "",
                        "Source ID": tx.id,
                    ])
                    counts["insider", default: 0] += 1
                }

                let proxies = (try? stocks.proxyFilings(symbol: stock.symbol)) ?? []
                for p in proxies {
                    var proposalLines = ""
                    if let json = p.proposals, let data = json.data(using: .utf8),
                       let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        proposalLines = arr.compactMap { item -> String? in
                            guard let num = item["number"] as? Int,
                                  let title = item["title"] as? String else { return nil }
                            return "\(num). \(title)"
                        }.joined(separator: "\n")
                    }
                    try upsertRow(tableKey: "proxy", sourceKey: "stocks:proxy:\(p.id)", values: [
                        "Symbol": p.symbol,
                        "Company": p.companyName ?? "",
                        "Filing Date": p.filingDate,
                        "Meeting Date": p.meetingDate ?? "",
                        "Proposals": proposalLines,
                        "URL": p.url ?? "",
                        "Source ID": p.id,
                    ])
                    counts["proxy", default: 0] += 1
                }

                let notes = (try? stocks.notes(symbol: stock.symbol)) ?? []
                for n in notes {
                    try upsertRow(tableKey: "notes", sourceKey: "stocks:note:\(n.id)", values: [
                        "Subject": stock.symbol,
                        "Content": n.content,
                        "Author": n.author,
                        "Created": Self.dateOnly(n.createdAt),
                        "Source ID": n.id,
                    ])
                    counts["notes", default: 0] += 1
                }
            }
        }
        return counts
    }

    // MARK: - Combined

    /// Sync both domains. Returns per-domain counts.
    func syncAll() throws -> [String: [String: Int]] {
        var result: [String: [String: Int]] = [:]
        result["blockchain"] = try syncBlocky()
        result["stocks"] = try syncStocks()
        return result
    }
}
