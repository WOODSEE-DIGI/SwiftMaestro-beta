import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Blocky agent tools: wallet_lookup, trace_wallet, wallet_tags, blockchain_report
// + investigation tools: blockchain_investigation_create, blockchain_investigation_list,
//   blockchain_watch_add, blockchain_watch_list, blockchain_watch_remove,
//   blockchain_correlate, blockchain_flag, blockchain_export
//
// Exposes blockchain wallet analysis + investigation workflow to the agent.
// Uses the same BlockyStore/BlockyDatabase as the Blocky panel. All data
// comes from public APIs (Blockstream, Etherscan) — no API key required.

extension MaestroTools {

    static func registerBlockyTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(name: "wallet_lookup", spec: blockyToolSpecs[0], category: ToolCategory.blockchain.rawValue,
                handler: { call in await walletLookupTool(call) }),
            ToolDefinition(name: "trace_wallet", spec: blockyToolSpecs[1], category: ToolCategory.blockchain.rawValue,
                handler: { call in await traceWalletTool(call) }),
            ToolDefinition(name: "wallet_tags", spec: blockyToolSpecs[2], category: ToolCategory.blockchain.rawValue,
                handler: { _ in await walletTagsTool() }),
            ToolDefinition(name: "blockchain_report", spec: blockyToolSpecs[3], category: ToolCategory.blockchain.rawValue,
                handler: { call in await blockchainReportTool(call) }),
            ToolDefinition(name: "blockchain_investigation_create", spec: blockyToolSpecs[4], category: ToolCategory.blockchain.rawValue,
                handler: { call in await investigationCreateTool(call) }),
            ToolDefinition(name: "blockchain_investigation_list", spec: blockyToolSpecs[5], category: ToolCategory.blockchain.rawValue,
                handler: { _ in await investigationListTool() }),
            ToolDefinition(name: "blockchain_watch_add", spec: blockyToolSpecs[6], category: ToolCategory.blockchain.rawValue,
                handler: { call in await watchAddTool(call) }),
            ToolDefinition(name: "blockchain_watch_list", spec: blockyToolSpecs[7], category: ToolCategory.blockchain.rawValue,
                handler: { _ in await watchListTool() }),
            ToolDefinition(name: "blockchain_watch_remove", spec: blockyToolSpecs[8], category: ToolCategory.blockchain.rawValue,
                handler: { call in await watchRemoveTool(call) }),
            ToolDefinition(name: "blockchain_correlate", spec: blockyToolSpecs[9], category: ToolCategory.blockchain.rawValue,
                handler: { _ in await correlateTool() }),
            ToolDefinition(name: "blockchain_flag", spec: blockyToolSpecs[10], category: ToolCategory.blockchain.rawValue,
                handler: { call in await flagTool(call) }),
            ToolDefinition(name: "blockchain_export", spec: blockyToolSpecs[11], category: ToolCategory.blockchain.rawValue,
                handler: { call in await exportTool(call) }),
        ])
    }

    static var blockyToolSpecs: [ToolSpec] {
        [
            rawSpec("wallet_lookup",
                "Look up a blockchain wallet address. Returns balance, transaction count, and entity label if known. Supports BTC (1.../3.../bc1...) and ETH (0x...) addresses.",
                properties: [
                    "address": ["type": "string", "description": "Blockchain wallet address to look up."],
                ], required: ["address"]),
            rawSpec("trace_wallet",
                "Trace recent transactions for a wallet address. Returns the most recent transactions with direction (in/out), counterparties, amounts, and timestamps.",
                properties: [
                    "address": ["type": "string", "description": "Blockchain wallet address to trace."],
                    "depth": ["type": "integer", "description": "Number of transactions to fetch (default 20, max 50)."],
                ], required: ["address"]),
            rawSpec("wallet_tags",
                "List all known/tagged wallet entities (exchanges, mixers, sanctioned, etc.) in the built-in database.",
                properties: [:], required: []),
            rawSpec("blockchain_report",
                "Generate a blockchain forensics report for a wallet address. Saves as xlsx, csv, or markdown with balance, transaction history, entity tags, and flow analysis.",
                properties: [
                    "address": ["type": "string", "description": "Blockchain wallet address to report on."],
                    "format": ["type": "string", "description": "Output format: 'xlsx' (default), 'csv', or 'md'."],
                    "depth": ["type": "integer", "description": "Number of transactions to include (default 20)."],
                    "path": ["type": "string", "description": "Absolute path to save the report."],
                ], required: ["address"]),
            // Investigation tools
            rawSpec("blockchain_investigation_create",
                "Create a new blockchain investigation/case for tracking wallets and building evidence.",
                properties: [
                    "name": ["type": "string", "description": "Investigation/case name."],
                    "description": ["type": "string", "description": "Optional description of the investigation."],
                ], required: ["name"]),
            rawSpec("blockchain_investigation_list",
                "List all blockchain investigations/cases.",
                properties: [:], required: []),
            rawSpec("blockchain_watch_add",
                "Add a wallet address to the current investigation's watchlist for ongoing monitoring.",
                properties: [
                    "address": ["type": "string", "description": "Wallet address to add."],
                    "label": ["type": "string", "description": "Optional label/name for this wallet."],
                ], required: ["address"]),
            rawSpec("blockchain_watch_list",
                "List all wallets currently tracked in the active investigation, with balances and flags.",
                properties: [:], required: []),
            rawSpec("blockchain_watch_remove",
                "Remove a wallet address from the current investigation's watchlist.",
                properties: [
                    "address": ["type": "string", "description": "Wallet address to remove."],
                ], required: ["address"]),
            rawSpec("blockchain_correlate",
                "Find shared counterparties and links between all watched wallets in the current investigation.",
                properties: [:], required: []),
            rawSpec("blockchain_flag",
                "Flag or unflag a wallet as suspicious in the investigation.",
                properties: [
                    "address": ["type": "string", "description": "Wallet address to flag/unflag."],
                    "reason": ["type": "string", "description": "Reason for flagging (omit to unflag)."],
                ], required: ["address"]),
            rawSpec("blockchain_export",
                "Export the current investigation (wallets, transactions, links, notes) to JSON or CSV.",
                properties: [
                    "format": ["type": "string", "description": "Export format: 'json' (default) or 'csv'."],
                    "path": ["type": "string", "description": "Absolute path to save the export."],
                ], required: []),
        ]
    }

    // MARK: - wallet_lookup

    @MainActor
    static func walletLookupTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: WalletLookupArgs.self)
        guard let address = args?.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            return errorJSON("'address' is required")
        }
        await BlockyStore.shared.lookup(address: address)
        guard let wallet = BlockyStore.shared.lastWallet else {
            return errorJSON(BlockyStore.shared.lastError ?? "lookup failed")
        }
        var result: [String: Any] = [
            "address": wallet.address,
            "chain": wallet.chain.rawValue,
            "balance": wallet.balance,
            "tx_count": wallet.txCount,
        ]
        if let label = wallet.label { result["label"] = label }
        if let first = wallet.firstSeen { result["first_seen"] = first }
        if let last = wallet.lastSeen { result["last_seen"] = last }
        // Include first 5 transactions as summary
        if !BlockyStore.shared.transactions.isEmpty {
            let txs = BlockyStore.shared.transactions.prefix(5).map { tx -> [String: Any] in
                var d: [String: Any] = [
                    "hash": tx.txHash, "from": tx.from, "to": tx.to,
                    "value": tx.value, "chain": tx.chain.rawValue,
                ]
                if let ts = tx.timestamp { d["timestamp"] = ts }
                if let fee = tx.fee { d["fee"] = fee }
                return d
            }
            result["recent_transactions"] = txs
        }
        return jsonString(result)
    }

    private struct WalletLookupArgs: Codable { let address: String? }

    // MARK: - trace_wallet

    @MainActor
    static func traceWalletTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: TraceWalletArgs.self)
        guard let address = args?.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            return errorJSON("'address' is required")
        }
        let depth = min(args?.depth ?? 20, 50)

        // Detect chain
        let chain: BlockyChain
        if BlockyChain.btc.isAddress(address) { chain = .btc }
        else if BlockyChain.eth.isAddress(address) { chain = .eth }
        else { return errorJSON("unrecognized address format — use BTC (1.../3.../bc1...) or ETH (0x...)") }

        await BlockyStore.shared.trace(address: address, chain: chain, depth: depth)
        let txs = BlockyStore.shared.transactions

        let items: [[String: Any]] = txs.map { tx in
            var d: [String: Any] = [
                "hash": tx.txHash, "from": tx.from, "to": tx.to,
                "value": tx.value, "chain": tx.chain.rawValue,
            ]
            if let ts = tx.timestamp { d["timestamp"] = ts }
            if let fee = tx.fee { d["fee"] = fee }
            if let block = tx.blockHeight { d["block_height"] = block }
            return d
        }

        // Summarize flow
        let incoming = txs.filter { $0.to.lowercased() == address.lowercased() }
        let outgoing = txs.filter { $0.from.lowercased() == address.lowercased() }
        let totalIn = incoming.reduce(0) { $0 + $1.value }
        let totalOut = outgoing.reduce(0) { $0 + $1.value }

        // Unique counterparties
        let counterparties = Array(Set(txs.map {
            $0.from.lowercased() == address.lowercased() ? $0.to : $0.from
        }))

        return jsonString([
            "address": address,
            "chain": chain.rawValue,
            "transactions": items,
            "count": items.count,
            "flow": [
                "incoming_count": incoming.count,
                "outgoing_count": outgoing.count,
                "total_in": totalIn,
                "total_out": totalOut,
                "net": totalIn - totalOut,
            ],
            "counterparties": counterparties,
            "counterparty_count": counterparties.count,
        ])
    }

    private struct TraceWalletArgs: Codable { let address: String?; let depth: Int? }

    // MARK: - wallet_tags

    @MainActor
    static func walletTagsTool() async -> String {
        let entities = BlockyStore.shared.taggedEntities.values.sorted { $0.name < $1.name }
        let items: [[String: Any]] = entities.map { e in
            ["address": e.address, "chain": e.chain.rawValue, "name": e.name, "category": e.category]
        }
        return jsonString(["tags": items, "count": items.count])
    }

    // MARK: - blockchain_report

    @MainActor
    static func blockchainReportTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: BlockchainReportArgs.self)
        guard let address = args?.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            return errorJSON("'address' is required")
        }
        let fmt = (args?.format ?? "xlsx").lowercased()
        guard ["xlsx", "csv", "md"].contains(fmt) else {
            return errorJSON("format must be 'xlsx', 'csv', or 'md'")
        }
        let depth = min(args?.depth ?? 20, 50)

        // Detect chain
        let chain: BlockyChain
        if BlockyChain.btc.isAddress(address) { chain = .btc }
        else if BlockyChain.eth.isAddress(address) { chain = .eth }
        else { return errorJSON("unrecognized address format") }

        // Fetch data
        await BlockyStore.shared.lookup(address: address)
        guard let wallet = BlockyStore.shared.lastWallet else {
            return errorJSON(BlockyStore.shared.lastError ?? "lookup failed")
        }
        await BlockyStore.shared.trace(address: address, chain: chain, depth: depth)

        // Build rows
        var rows: [[String]] = [["Field", "Value"]]
        rows.append(["Address", wallet.address])
        rows.append(["Chain", wallet.chain.displayName])
        rows.append(["Balance", String(format: wallet.chain == .btc ? "%.8f BTC" : "%.6f ETH", wallet.balance)])
        rows.append(["Transactions", "\(wallet.txCount)"])
        if let label = wallet.label { rows.append(["Entity", label]) }
        rows.append([""])

        // Transaction history
        rows.append(["Transaction History"])
        rows.append(["Hash", "From", "To", "Value", "Fee", "Timestamp"])
        for tx in BlockyStore.shared.transactions {
            rows.append([
                tx.txHash,
                shortAddr(tx.from),
                shortAddr(tx.to),
                String(format: "%.8f", tx.value),
                tx.fee.map { String(format: "%.8f", $0) } ?? "—",
                tx.timestamp ?? "—",
            ])
        }

        // Flow summary
        let incoming = BlockyStore.shared.transactions.filter { $0.to.lowercased() == address.lowercased() }
        let outgoing = BlockyStore.shared.transactions.filter { $0.from.lowercased() == address.lowercased() }
        rows.append([""])
        rows.append(["Flow Summary"])
        rows.append(["Incoming Transactions", "\(incoming.count)"])
        rows.append(["Outgoing Transactions", "\(outgoing.count)"])
        rows.append(["Total Received", String(format: "%.8f", incoming.reduce(0) { $0 + $1.value })])
        rows.append(["Total Sent", String(format: "%.8f", outgoing.reduce(0) { $0 + $1.value })])

        // Write file
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: Date())
        let shortAddr = String(address.prefix(12))
        let fileName = "blockchain-report-\(shortAddr)-\(dateStr).\(fmt)"
        let outURL: URL
        if let raw = args?.path, !raw.isEmpty, raw.hasPrefix("/") {
            outURL = URL(fileURLWithPath: raw)
        } else {
            outURL = desktop.appendingPathComponent(fileName)
        }

        do {
            try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes: Int
            switch fmt {
            case "csv":
                let csv = rows.map { $0.joined(separator: ",") }.joined(separator: "\n")
                try csv.write(to: outURL, atomically: true, encoding: .utf8)
                bytes = csv.utf8.count
            case "md":
                var md = "# Blockchain Report — \(shortAddr)…\n\n"
                for (i, row) in rows.enumerated() {
                    md += "| " + row.joined(separator: " | ") + " |\n"
                    if i == 1 { md += "| " + row.map { _ in "---" }.joined(separator: " | ") + " |\n" }
                }
                try md.write(to: outURL, atomically: true, encoding: .utf8)
                bytes = md.utf8.count
            default:
                bytes = try DocEngine.createXLSX(outURL, rows: rows, sheetName: "Blockchain Report")
            }
            return jsonString([
                "status": "created", "format": fmt,
                "path": outURL.path, "bytes": "\(bytes)",
                "address": address, "chain": chain.rawValue,
            ])
        } catch {
            return errorJSON("failed to create report: \(error.localizedDescription)")
        }
    }

    private struct BlockchainReportArgs: Codable {
        let address: String?
        let format: String?
        let depth: Int?
        let path: String?
    }

    // MARK: - Investigation Tools

    @MainActor
    static func investigationCreateTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: InvestigationCreateArgs.self)
        guard let name = args?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return errorJSON("'name' is required")
        }
        let desc = args?.description
        guard let inv = BlockyStore.shared.createInvestigation(name: name, description: desc) else {
            return errorJSON(BlockyStore.shared.lastError ?? "failed to create investigation")
        }
        return jsonString([
            "status": "created", "id": inv.id, "name": inv.name,
            "created_at": inv.createdAt,
        ])
    }

    private struct InvestigationCreateArgs: Codable { let name: String?; let description: String? }

    @MainActor
    static func investigationListTool() async -> String {
        let items: [[String: Any]] = BlockyStore.shared.investigations.map { inv in
            var d: [String: Any] = ["id": inv.id, "name": inv.name, "created_at": inv.createdAt, "updated_at": inv.updatedAt]
            if let desc = inv.description { d["description"] = desc }
            return d
        }
        return jsonString(["investigations": items, "count": items.count])
    }

    @MainActor
    static func watchAddTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: WatchAddArgs.self)
        guard let address = args?.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            return errorJSON("'address' is required")
        }
        guard BlockyStore.shared.currentInvestigation != nil else {
            return errorJSON("no investigation selected — create one first with blockchain_investigation_create")
        }
        let chain: String
        if BlockyChain.btc.isAddress(address) { chain = "BTC" }
        else if BlockyChain.eth.isAddress(address) { chain = "ETH" }
        else { chain = "BTC" }

        BlockyStore.shared.addWalletToInvestigation(
            address: address, chain: chain,
            userLabel: args?.label)

        // Auto-lookup to populate balance
        await BlockyStore.shared.lookup(address: address)

        return jsonString([
            "status": "added", "address": address, "chain": chain,
            "label": args?.label ?? "",
        ])
    }

    private struct WatchAddArgs: Codable { let address: String?; let label: String? }

    @MainActor
    static func watchListTool() async -> String {
        guard BlockyStore.shared.currentInvestigation != nil else {
            return jsonString(["wallets": [], "count": 0, "message": "no investigation selected"])
        }
        let items: [[String: Any]] = BlockyStore.shared.watchedWallets.map { w in
            var d: [String: Any] = [
                "id": w.id, "address": w.address, "chain": w.chain,
                "added_at": w.addedAt, "is_flagged": w.isFlagged,
            ]
            if let l = w.userLabel { d["label"] = l }
            if let e = w.entityLabel { d["entity"] = e }
            if let b = w.balance { d["balance"] = b }
            if let tx = w.txCount { d["tx_count"] = tx }
            if let fr = w.flagReason { d["flag_reason"] = fr }
            return d
        }
        return jsonString(["wallets": items, "count": items.count])
    }

    @MainActor
    static func watchRemoveTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: WatchRemoveArgs.self)
        guard let address = args?.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            return errorJSON("'address' is required")
        }
        guard let wallet = BlockyStore.shared.watchedWallets.first(where: {
            $0.address.lowercased() == address.lowercased()
        }) else {
            return errorJSON("wallet not found in current investigation")
        }
        BlockyStore.shared.removeWalletFromInvestigation(wallet)
        return jsonString(["status": "removed", "address": address])
    }

    private struct WatchRemoveArgs: Codable { let address: String? }

    @MainActor
    static func correlateTool() async -> String {
        guard BlockyStore.shared.currentInvestigation != nil else {
            return errorJSON("no investigation selected")
        }
        BlockyStore.shared.recalculateSharedCounterparties()
        let counterparties = BlockyStore.shared.sharedCounterparties
        let items: [[String: Any]] = counterparties.map { addr, count in
            let entity = BlockyStore.shared.taggedEntities[addr]
            var d: [String: Any] = ["address": addr, "watched_by_count": count]
            if let e = entity { d["entity"] = e.name; d["category"] = e.category }
            return d
        }
        let wallets = BlockyStore.shared.watchedWallets.map { w -> [String: Any] in
            ["address": w.address, "chain": w.chain, "label": w.userLabel ?? ""]
        }
        return jsonString([
            "shared_counterparties": items,
            "shared_count": items.count,
            "tracked_wallets": wallets,
            "tracked_count": wallets.count,
        ])
    }

    @MainActor
    static func flagTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: FlagArgs.self)
        guard let address = args?.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            return errorJSON("'address' is required")
        }
        guard let wallet = BlockyStore.shared.watchedWallets.first(where: {
            $0.address.lowercased() == address.lowercased()
        }) else {
            return errorJSON("wallet not found in current investigation")
        }
        if let reason = args?.reason, !reason.isEmpty {
            BlockyStore.shared.flagWallet(wallet, reason: reason)
            return jsonString(["status": "flagged", "address": address, "reason": reason])
        } else {
            BlockyStore.shared.unflagWallet(wallet)
            return jsonString(["status": "unflagged", "address": address])
        }
    }

    private struct FlagArgs: Codable { let address: String?; let reason: String? }

    @MainActor
    static func exportTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: ExportArgs.self)
        guard let investigation = BlockyStore.shared.currentInvestigation else {
            return errorJSON("no investigation selected")
        }
        let fmt = (args?.format ?? "json").lowercased()
        guard ["json", "csv"].contains(fmt) else {
            return errorJSON("format must be 'json' or 'csv'")
        }
        let exportFormat: ExportFormat = fmt == "csv" ? .csv : .json

        do {
            let data = try BlockyDatabase.shared.exportInvestigation(id: investigation.id, format: exportFormat)
            let fm = FileManager.default
            let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first!
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd-HHmm"
            let dateStr = dateFormatter.string(from: Date())
            let safeName = investigation.name.replacingOccurrences(of: " ", with: "-").lowercased()
            let fileName = "blockchain-\(safeName)-\(dateStr).\(fmt)"
            let outURL: URL
            if let raw = args?.path, !raw.isEmpty, raw.hasPrefix("/") {
                outURL = URL(fileURLWithPath: raw)
            } else {
                outURL = desktop.appendingPathComponent(fileName)
            }
            try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: outURL, options: .atomic)
            return jsonString([
                "status": "exported", "format": fmt,
                "path": outURL.path, "bytes": "\(data.count)",
                "investigation": investigation.name,
            ])
        } catch {
            return errorJSON("export failed: \(error.localizedDescription)")
        }
    }

    private struct ExportArgs: Codable { let format: String?; let path: String? }

    private static func shortAddr(_ addr: String) -> String {
        if addr.count > 16 { return String(addr.prefix(8)) + "…" + String(addr.suffix(6)) }
        return addr
    }
}
