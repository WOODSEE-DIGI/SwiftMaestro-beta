import Foundation

// MARK: - Blocky service
//
// Blockchain wallet lookup and transaction tracing for BTC and ETH.
// Uses free public APIs (Blockstream for BTC, Etherscan for ETH) — no API
// key required for basic queries. Rate-limited to 1 req/sec.

/// A blockchain wallet/address with balance and metadata.
struct BlockyWallet: Equatable, Sendable {
    let address: String
    let chain: BlockyChain
    let balance: Double            // in native units (BTC or ETH)
    let balanceFiat: Double?       // USD value if available
    let txCount: Int
    let firstSeen: String?         // ISO date or block height
    let lastSeen: String?
    let label: String?             // known entity label (exchange, mixer, etc.)
}

/// A single transaction on the blockchain.
struct BlockyTransaction: Identifiable, Equatable, Sendable {
    var id: String { txHash }
    let txHash: String
    let chain: BlockyChain
    let blockHeight: Int?
    let timestamp: String?
    let from: String
    let to: String
    let value: Double              // in native units
    let valueFiat: Double?
    let fee: Double?
    let confirmations: Int?
}

/// Supported blockchains.
enum BlockyChain: String, CaseIterable, Codable, Sendable {
    case btc = "BTC"
    case eth = "ETH"

    var displayName: String {
        switch self {
        case .btc: return "Bitcoin"
        case .eth: return "Ethereum"
        }
    }

    var icon: String {
        switch self {
        case .btc: return "bitcoinsign.circle"
        case .eth: return "eth"
        }
    }

    /// Whether the string looks like an address for this chain.
    func isAddress(_ s: String) -> Bool {
        switch self {
        case .btc: return s.count >= 26 && s.count <= 35 && (s.hasPrefix("1") || s.hasPrefix("3") || s.hasPrefix("bc1"))
        case .eth: return s.count == 42 && s.hasPrefix("0x")
        }
    }
}

/// A tagged/known entity (exchange, mixer, sanctioned, etc.).
struct BlockyEntity: Identifiable, Equatable, Sendable {
    var id: String { address }
    let address: String
    let chain: BlockyChain
    let name: String
    let category: String           // "exchange", "mixer", "sanctioned", "defi", "bridge", etc.
}

@Observable
@MainActor
final class BlockyStore {
    static let shared = BlockyStore()

    // MARK: - Existing single-wallet lookup state

    private(set) var lastWallet: BlockyWallet?
    private(set) var transactions: [BlockyTransaction] = []
    private(set) var taggedEntities: [String: BlockyEntity] = [:]  // address → entity
    private(set) var isloading = false
    private(set) var isTracing = false
    var lastError: String?

    // MARK: - Investigation state

    private(set) var investigations: [BlockyInvestigation] = []
    private(set) var currentInvestigation: BlockyInvestigation?
    private(set) var watchedWallets: [BlockyWatchedWallet] = []
    private(set) var investigationNotes: [BlockyInvestigationNote] = []
    private(set) var sharedCounterparties: [String: Int] = [:]  // address → count of watched wallets it touches

    private let session = URLSession.shared
    private let db = BlockyDatabase.shared

    // MARK: - Known entity database (built-in tags)

    /// Pre-loaded known entities. In production, this would load from a
    /// bundled JSON or fetch from a public tag database.
    private static let knownEntities: [(address: String, chain: BlockyChain, name: String, category: String)] = [
        // Bitcoin
        ("34xp4vRoCGJym3xR7yCVPFHoCNxv4Twseo", .btc, "Binance (Cold)", "exchange"),
        ("bc1qm34lsc65zpw79lxes69zkqmk6ee3ewf0j77s3f", .btc, "Binance (Hot)", "exchange"),
        ("bc1qgdjqv0av3q56jvd82tkdjpy7gdbrd9x9g65a", .btc, "Kraken", "exchange"),
        ("12tkqA9xSoowkzoERHMWNKsTey55YEBqkv", .btc, "Tornado Cash Relay", "mixer"),
        // Ethereum
        ("0x28C6c06298d514Db089934071355E5743bf21d60", .eth, "Binance (Hot)", "exchange"),
        ("0x21a31Ee1afC51d94C2eFcCAa2092aD1028285549", .eth, "Binance (Cold)", "exchange"),
        ("0xA090e606e30bD747d4E6245a1517EbE430f0057e", .eth, "Kraken", "exchange"),
        ("0x722122dF12D4e14e13Ac3b6895a86e84145b6967", .eth, "Tornado Cash (6 ETH)", "mixer"),
        ("0xDD4c48C0B24039969fC16D1cdF626d82E5f83404", .eth, "Tornado Cash (100 ETH)", "mixer"),
        ("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", .eth, "Vitalik Buterin", "individual"),
        ("0x220866B1A2219f40e72f5c628Beb569924f3716C", .eth, "Tether Treasury", "stablecoin"),
    ]

    private init() {
        for e in Self.knownEntities {
            taggedEntities[e.address] = BlockyEntity(
                address: e.address, chain: e.chain, name: e.name, category: e.category)
        }
        // Load investigations from DB
        loadInvestigations()
    }

    // MARK: - Investigation Management

    func loadInvestigations() {
        do {
            investigations = try db.listInvestigations()
        } catch {
            NSLog("[Blocky] Failed to load investigations: %@", String(describing: error))
        }
    }

    func createInvestigation(name: String, description: String? = nil) -> BlockyInvestigation? {
        do {
            let inv = try db.createInvestigation(name: name, description: description)
            investigations.insert(inv, at: 0)
            selectInvestigation(inv)
            return inv
        } catch {
            lastError = "Failed to create investigation: \(error.localizedDescription)"
            return nil
        }
    }

    func selectInvestigation(_ investigation: BlockyInvestigation) {
        currentInvestigation = investigation
        loadWatchedWallets()
        loadNotes()
        recalculateSharedCounterparties()
    }

    func deleteInvestigation(_ investigation: BlockyInvestigation) {
        do {
            try db.deleteInvestigation(id: investigation.id)
            investigations.removeAll { $0.id == investigation.id }
            if currentInvestigation?.id == investigation.id {
                currentInvestigation = nil
                watchedWallets = []
                investigationNotes = []
            }
        } catch {
            lastError = "Failed to delete investigation: \(error.localizedDescription)"
        }
    }

    // MARK: - Wallet Watchlist

    func addWalletToInvestigation(
        address: String, chain: String,
        userLabel: String? = nil, entityLabel: String? = nil
    ) {
        guard let investigation = currentInvestigation else {
            lastError = "No investigation selected — create one first"
            return
        }
        do {
            let wallet = try db.addWallet(
                address: address, chain: chain,
                investigationId: investigation.id,
                userLabel: userLabel, entityLabel: entityLabel)
            watchedWallets.insert(wallet, at: 0)
            recalculateSharedCounterparties()
        } catch {
            lastError = "Failed to add wallet: \(error.localizedDescription)"
        }
    }

    func removeWalletFromInvestigation(_ wallet: BlockyWatchedWallet) {
        do {
            try db.removeWallet(id: wallet.id)
            watchedWallets.removeAll { $0.id == wallet.id }
            recalculateSharedCounterparties()
        } catch {
            lastError = "Failed to remove wallet: \(error.localizedDescription)"
        }
    }

    func flagWallet(_ wallet: BlockyWatchedWallet, reason: String) {
        do {
            try db.flagWallet(id: wallet.id, reason: reason)
            if let idx = watchedWallets.firstIndex(where: { $0.id == wallet.id }) {
                watchedWallets[idx] = BlockyWatchedWallet(
                    id: wallet.id, investigationId: wallet.investigationId,
                    address: wallet.address, chain: wallet.chain,
                    userLabel: wallet.userLabel, entityLabel: wallet.entityLabel,
                    notes: wallet.notes, balance: wallet.balance, txCount: wallet.txCount,
                    addedAt: wallet.addedAt, lastChecked: wallet.lastChecked,
                    isFlagged: true, flagReason: reason)
            }
        } catch {
            lastError = "Failed to flag wallet: \(error.localizedDescription)"
        }
    }

    func unflagWallet(_ wallet: BlockyWatchedWallet) {
        do {
            try db.unflagWallet(id: wallet.id)
            if let idx = watchedWallets.firstIndex(where: { $0.id == wallet.id }) {
                watchedWallets[idx] = BlockyWatchedWallet(
                    id: wallet.id, investigationId: wallet.investigationId,
                    address: wallet.address, chain: wallet.chain,
                    userLabel: wallet.userLabel, entityLabel: wallet.entityLabel,
                    notes: wallet.notes, balance: wallet.balance, txCount: wallet.txCount,
                    addedAt: wallet.addedAt, lastChecked: wallet.lastChecked,
                    isFlagged: false, flagReason: nil)
            }
        } catch {
            lastError = "Failed to unflag wallet: \(error.localizedDescription)"
        }
    }

    func refreshWatchedWallets() async {
        guard let investigation = currentInvestigation else { return }
        do {
            watchedWallets = try db.listWallets(investigationId: investigation.id)
        } catch {
            lastError = "Failed to refresh wallets: \(error.localizedDescription)"
        }
    }

    private func loadWatchedWallets() {
        guard let investigation = currentInvestigation else { return }
        do {
            watchedWallets = try db.listWallets(investigationId: investigation.id)
        } catch {
            watchedWallets = []
        }
    }

    // MARK: - Investigation Notes

    func addNote(_ content: String, author: String = "user") {
        guard let investigation = currentInvestigation else { return }
        do {
            let note = try db.addNote(investigationId: investigation.id, content: content, author: author)
            investigationNotes.insert(note, at: 0)
        } catch {
            lastError = "Failed to add note: \(error.localizedDescription)"
        }
    }

    private func loadNotes() {
        guard let investigation = currentInvestigation else { return }
        do {
            investigationNotes = try db.notesForInvestigation(investigationId: investigation.id)
        } catch {
            investigationNotes = []
        }
    }

    // MARK: - Shared Counterparties

    func recalculateSharedCounterparties() {
        let addresses = watchedWallets.map { $0.address }
        do {
            sharedCounterparties = try db.sharedCounterparties(addresses: addresses)
        } catch {
            sharedCounterparties = [:]
        }
    }

    // MARK: - Persist fetched data

    private func persistTransactions(_ txs: [BlockyTransaction]) {
        let now = ISO8601DateFormatter().string(from: Date())
        let records = txs.map { tx in
            BlockyTransactionRecord(
                txHash: tx.txHash, chain: tx.chain.rawValue,
                blockHeight: tx.blockHeight, timestamp: tx.timestamp,
                fromAddress: tx.from, toAddress: tx.to,
                value: tx.value, fee: tx.fee, fetchedAt: now)
        }
        do {
            try db.upsertTransactions(records)
            // Auto-discover links between watched wallets
            discoverLinks(from: records)
        } catch {
            NSLog("[Blocky] Failed to persist transactions: %@", String(describing: error))
        }
    }

    private func discoverLinks(from txs: [BlockyTransactionRecord]) {
        let watchedAddrs = Set(watchedWallets.map { $0.address.lowercased() })
        for tx in txs {
            let fromLower = tx.fromAddress.lowercased()
            let toLower = tx.toAddress.lowercased()
            // Link if both from and to are watched wallets
            if watchedAddrs.contains(fromLower) && watchedAddrs.contains(toLower) {
                do {
                    _ = try db.addLink(
                        fromAddress: tx.fromAddress, toAddress: tx.toAddress,
                        chain: tx.chain, txHash: tx.txHash,
                        linkType: "direct_transfer",
                        totalValue: tx.value, txCount: 1,
                        firstSeen: tx.timestamp, lastSeen: tx.timestamp)
                } catch {
                    NSLog("[Blocky] Failed to add link: %@", String(describing: error))
                }
            }
            // Also discover shared counterparties
            if watchedAddrs.contains(fromLower) || watchedAddrs.contains(toLower) {
                let counterparty = watchedAddrs.contains(fromLower) ? tx.toAddress : tx.fromAddress
                let wallet = watchedAddrs.contains(fromLower) ? tx.fromAddress : tx.toAddress
                do {
                    _ = try db.addLink(
                        fromAddress: wallet, toAddress: counterparty,
                        chain: tx.chain, txHash: tx.txHash,
                        linkType: "shared_counterparty",
                        totalValue: tx.value, txCount: 1,
                        firstSeen: tx.timestamp, lastSeen: tx.timestamp)
                } catch {
                    // Ignore duplicate link errors
                }
            }
        }
        recalculateSharedCounterparties()
    }

    // MARK: - Public API (single-wallet lookup)

    /// Auto-detect chain from address format and fetch wallet info.
    func lookup(address raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isloading = true
        lastError = nil
        defer { isloading = false }

        // Auto-detect chain
        let chain: BlockyChain?
        if BlockyChain.btc.isAddress(trimmed) { chain = .btc }
        else if BlockyChain.eth.isAddress(trimmed) { chain = .eth }
        else { chain = nil }

        guard let chain else {
            lastError = "Unrecognized address format. Enter a Bitcoin (1.../3.../bc1...) or Ethereum (0x...) address."
            return
        }

        do {
            let wallet = try await fetchWallet(address: trimmed, chain: chain)
            lastWallet = wallet
            transactions = try await fetchTransactions(address: trimmed, chain: chain, limit: 20)
            // Persist to DB if in an investigation
            persistTransactions(transactions)
            // Update watched wallet balance if this address is in the watchlist
            try? db.updateWalletBalance(address: trimmed, chain: chain.rawValue,
                                        balance: wallet.balance, txCount: wallet.txCount)
            await refreshWatchedWallets()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Trace transactions for an address (fetch more history).
    func trace(address: String, chain: BlockyChain, depth: Int = 20) async {
        isTracing = true
        defer { isTracing = false }
        do {
            transactions = try await fetchTransactions(address: address, chain: chain, limit: depth)
            // Persist to DB
            persistTransactions(transactions)
            await refreshWatchedWallets()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Blockstream API (BTC)

    private func fetchWallet(address: String, chain: BlockyChain) async throws -> BlockyWallet {
        switch chain {
        case .btc:
            guard let url = URL(string: "https://blockstream.info/api/address/\(address)") else {
                throw BlockyError.invalidURL
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Blocky/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BlockyError.invalidResponse
            }
            let stats = json["chain_stats"] as? [String: Any] ?? [:]
            let funded = stats["funded_txo_sum"] as? Int64 ?? 0
            let spent = stats["spent_txo_sum"] as? Int64 ?? 0
            let txCount = stats["tx_count"] as? Int ?? 0
            let balance = Double(funded - spent) / 100_000_000.0  // satoshis → BTC
            let label = taggedEntities[address]?.name
            return BlockyWallet(
                address: address, chain: .btc, balance: balance, balanceFiat: nil,
                txCount: txCount, firstSeen: nil, lastSeen: nil, label: label)

        case .eth:
            // Etherscan free API — no key needed for basic balance
            guard let url = URL(string: "https://api.etherscan.io/api?module=account&action=balance&address=\(address)&tag=latest") else {
                throw BlockyError.invalidURL
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Blocky/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? String else {
                throw BlockyError.invalidResponse
            }
            let wei = Double(result) ?? 0
            let balance = wei / 1_000_000_000_000_000_000.0  // wei → ETH
            let label = taggedEntities[address]?.name
            return BlockyWallet(
                address: address, chain: .eth, balance: balance, balanceFiat: nil,
                txCount: 0, firstSeen: nil, lastSeen: nil, label: label)
        }
    }

    private func fetchTransactions(address: String, chain: BlockyChain, limit: Int) async throws -> [BlockyTransaction] {
        switch chain {
        case .btc:
            guard let url = URL(string: "https://blockstream.info/api/address/\(address)/txs") else {
                throw BlockyError.invalidURL
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Blocky/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: request)
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw BlockyError.invalidResponse
            }
            return array.prefix(limit).compactMap { tx -> BlockyTransaction? in
                guard let txid = tx["txid"] as? String else { return nil }
                let status = tx["status"] as? [String: Any]
                let blockHeight = status?["block_height"] as? Int
                let confirmed = status?["confirmed"] as? Bool ?? false
                let blockTime = status?["block_time"] as? Int

                // Parse inputs/outputs to find from/to relative to our address
                let vout = tx["vout"] as? [[String: Any]] ?? []
                let vin = tx["vin"] as? [[String: Any]] ?? []
                let totalOutput = vout.reduce(Int64(0)) { sum, out in
                    let value = out["value"] as? Int64 ?? 0
                    return sum + value
                }
                let totalInput = vin.reduce(Int64(0)) { sum, inp in
                    let prevout = inp["prevout"] as? [String: Any] ?? [:]
                    let value = prevout["value"] as? Int64 ?? 0
                    return sum + value
                }
                let fee = max(0, totalInput - totalOutput)

                // Determine direction
                let sendsToAddress = vout.contains { ($0["scriptpubkey_address"] as? String) == address }
                let comesFromAddress = vin.contains { ($0["prevout"] as? [String: Any])?["scriptpubkey_address"] as? String == address }

                let from: String
                let to: String
                let value: Double
                if comesFromAddress {
                    from = address
                    let externalOutputs = vout.filter { ($0["scriptpubkey_address"] as? String) != address }
                    to = externalOutputs.first?["scriptpubkey_address"] as? String ?? "unknown"
                    value = Double(externalOutputs.reduce(0) { $0 + (($1["value"] as? Int64) ?? 0) }) / 100_000_000.0
                } else {
                    let firstInput = vin.first?["prevout"] as? [String: Any]
                    from = firstInput?["scriptpubkey_address"] as? String ?? "unknown"
                    to = address
                    value = Double(vout.filter { ($0["scriptpubkey_address"] as? String) == address }
                        .reduce(0) { $0 + (($1["value"] as? Int64) ?? 0) }) / 100_000_000.0
                }

                let timestamp: String? = blockTime.map { ts in
                    let date = Date(timeIntervalSince1970: TimeInterval(ts))
                    let fmt = ISO8601DateFormatter()
                    return fmt.string(from: date)
                }

                return BlockyTransaction(
                    txHash: txid, chain: .btc, blockHeight: blockHeight,
                    timestamp: timestamp, from: from, to: to,
                    value: value, valueFiat: nil, fee: Double(fee) / 100_000_000.0,
                    confirmations: blockHeight.map { max(0, 800000 - $0) })  // approx
            }

        case .eth:
            guard let url = URL(string: "https://api.etherscan.io/api?module=account&action=txlist&address=\(address)&startblock=0&endblock=99999999&sort=desc&page=1&offset=\(limit)") else {
                throw BlockyError.invalidURL
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Blocky/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [[String: Any]] else {
                throw BlockyError.invalidResponse
            }
            return result.prefix(limit).compactMap { tx -> BlockyTransaction? in
                guard let hash = tx["hash"] as? String,
                      let from = tx["from"] as? String,
                      let to = tx["to"] as? String else { return nil }
                let valueStr = tx["value"] as? String ?? "0"
                let wei = Double(valueStr) ?? 0
                let value = wei / 1_000_000_000_000_000_000.0
                let blockNum = tx["blockNumber"] as? String
                let timeStamp = tx["timeStamp"] as? String
                let gasUsed = tx["gasUsed"] as? String
                let gasPrice = tx["gasPrice"] as? String
                let fee: Double? = {
                    guard let gu = Double(gasUsed ?? ""), let gp = Double(gasPrice ?? "") else { return nil }
                    return (gu * gp) / 1_000_000_000_000_000_000.0
                }()
                let ts: String? = timeStamp.flatMap { Int($0) }.map { t in
                    let date = Date(timeIntervalSince1970: TimeInterval(t))
                    return ISO8601DateFormatter().string(from: date)
                }
                return BlockyTransaction(
                    txHash: hash, chain: .eth, blockHeight: blockNum.flatMap { Int($0) },
                    timestamp: ts, from: from, to: to,
                    value: value, valueFiat: nil, fee: fee, confirmations: nil)
            }
        }
    }
}

// MARK: - Errors

enum BlockyError: LocalizedError {
    case invalidURL
    case invalidResponse
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response from blockchain API"
        case .rateLimited: return "Rate limited — try again in a moment"
        }
    }
}
