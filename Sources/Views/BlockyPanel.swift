import SwiftUI

// MARK: - Blocky panel
//
// Blockchain wallet lookup and transaction tracing for BTC/ETH.
// Data from Blockstream (BTC) and Etherscan (ETH) free APIs.

struct BlockyPanel: View {
    enum Tab: String, CaseIterable {
        case investigations = "Cases"
        case watchlist = "Watch"
        case wallet = "Wallet"
        case trace = "Trace"
    }

    @State private var store = BlockyStore.shared
    @State private var addressInput = ""
    @State private var selectedChain: BlockyChain = .btc
    @State private var selectedTab: Tab = .investigations
    @State private var traceDepth = 20
    @State private var newInvestigationName = ""
    @State private var showNewInvestigation = false
    @State private var showAddWallet = false
    @State private var addWalletAddress = ""
    @State private var addWalletLabel = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search bar only for Wallet/Trace tabs
            if selectedTab == .wallet || selectedTab == .trace {
                searchBar
                Divider()
                chainPicker
                Divider()
            }
            tabPicker
            Divider()
            Group {
                switch selectedTab {
                case .investigations: investigationsView
                case .watchlist: watchlistView
                case .wallet: walletView
                case .trace: traceView
                }
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "link.circle")
                .foregroundStyle(.secondary)
            TextField("Enter wallet address (0x... or bc1...)", text: $addressInput)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { lookup() }
            Button {
                lookup()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .disabled(addressInput.trimmingCharacters(in: .whitespaces).isEmpty || store.isloading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func lookup() {
        let addr = addressInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else { return }
        Task { await store.lookup(address: addr) }
    }

    // MARK: - Chain picker

    private var chainPicker: some View {
        HStack(spacing: 12) {
            ForEach(BlockyChain.allCases, id: \.self) { chain in
                Button {
                    selectedChain = chain
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: chain == .btc ? "bitcoinsign.circle.fill" : "aqi.medium")
                            .font(.caption)
                        Text(chain.displayName)
                            .font(.caption.weight(selectedChain == chain ? .semibold : .regular))
                    }
                    .foregroundStyle(selectedChain == chain ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(selectedChain == chain ? Color.accentColor.opacity(0.15) : Color.clear, in: .capsule)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text(tab.rawValue)
                            .font(.caption.weight(selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        Rectangle()
                            .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Investigations view

    private var investigationsView: some View {
        VStack(spacing: 0) {
            // Header with create button
            HStack {
                Text("Investigations")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    showNewInvestigation = true
                } label: {
                    Label("New Case", systemImage: "plus.circle.fill")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Error banner — DB failures must never be silent
            if let error = store.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                    Spacer()
                    Button("Dismiss") { store.lastError = nil }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
                .padding(8)
                .background(Color.orange.opacity(0.15), in: .rect(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if store.investigations.isEmpty {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "No Investigations",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Create an investigation to start tracking wallets and building cases.")
                    )
                    Button {
                        showNewInvestigation = true
                    } label: {
                        Label("Create Your First Case", systemImage: "plus.circle.fill")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.investigations) { inv in
                            investigationRow(inv)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .alert("New Investigation", isPresented: $showNewInvestigation) {
            TextField("Case name", text: $newInvestigationName)
            Button("Create") {
                guard !newInvestigationName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                _ = store.createInvestigation(name: newInvestigationName)
                newInvestigationName = ""
                selectedTab = .watchlist
            }
            Button("Cancel", role: .cancel) { newInvestigationName = "" }
        } message: {
            Text("Give this investigation a name to track wallets and build cases.")
        }
    }

    private func investigationRow(_ inv: BlockyInvestigation) -> some View {
        let isSelected = store.currentInvestigation?.id == inv.id
        return Button {
            store.selectInvestigation(inv)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "folder.fill" : "folder")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(inv.name)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    if let desc = inv.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text(formatDate(inv.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete") {
                store.deleteInvestigation(inv)
            }
        }
    }

    // MARK: - Watchlist view

    private var watchlistView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let inv = store.currentInvestigation {
                        Text(inv.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                    } else {
                        Text("No Investigation Selected")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(store.watchedWallets.count) wallets tracked")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if store.currentInvestigation != nil {
                    Button {
                        showAddWallet = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if store.currentInvestigation == nil {
                ContentUnavailableView(
                    "Select an Investigation",
                    systemImage: "folder",
                    description: Text("Go to Cases tab and select or create an investigation first.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if store.watchedWallets.isEmpty {
                ContentUnavailableView(
                    "No Wallets Tracked",
                    systemImage: "plus.magnifyingglass",
                    description: Text("Add a wallet address to start tracking it in this investigation.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        // Shared counterparties alert
                        if !store.sharedCounterparties.isEmpty {
                            sharedCounterpartiesBanner
                        }

                        ForEach(store.watchedWallets) { wallet in
                            watchedWalletRow(wallet)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .alert("Add Wallet to Investigation", isPresented: $showAddWallet) {
            TextField("Wallet address", text: $addWalletAddress)
                .autocorrectionDisabled()
            TextField("Label (optional)", text: $addWalletLabel)
            Button("Add") {
                let addr = addWalletAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !addr.isEmpty else { return }
                // Auto-detect chain
                let chain: String
                if BlockyChain.btc.isAddress(addr) { chain = "BTC" }
                else if BlockyChain.eth.isAddress(addr) { chain = "ETH" }
                else { chain = "BTC" } // default
                store.addWalletToInvestigation(
                    address: addr, chain: chain,
                    userLabel: addWalletLabel.isEmpty ? nil : addWalletLabel)
                addWalletAddress = ""
                addWalletLabel = ""
                // Auto-lookup
                Task { await store.lookup(address: addr) }
            }
            Button("Cancel", role: .cancel) {
                addWalletAddress = ""
                addWalletLabel = ""
            }
        } message: {
            Text("Paste a Bitcoin or Ethereum address to track.")
        }
    }

    private var sharedCounterpartiesBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .foregroundStyle(.orange)
            Text("\(store.sharedCounterparties.count) shared counterparties found between tracked wallets")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
    }

    private func watchedWalletRow(_ wallet: BlockyWatchedWallet) -> some View {
        let chain = BlockyChain(rawValue: wallet.chain) ?? .btc
        return HStack(spacing: 10) {
            // Flag indicator
            if wallet.isFlagged {
                Image(systemName: "flag.fill")
                    .foregroundStyle(.red)
                    .font(.caption2)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let label = wallet.userLabel {
                        Text(label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                    } else {
                        Text(shortAddress(wallet.address))
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    if let entity = wallet.entityLabel {
                        Text(entity)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 3))
                    }
                }
                Text(wallet.address)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let balance = wallet.balance {
                    Text(formatBalance(balance, chain: chain))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Text(wallet.chain)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            // Jump to Wallet tab with this address
            addressInput = wallet.address
            selectedTab = .wallet
            Task { await store.lookup(address: wallet.address) }
        }
        .contextMenu {
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(wallet.address, forType: .string)
            }
            Button(wallet.isFlagged ? "Unflag" : "Flag as Suspicious") {
                if wallet.isFlagged {
                    store.unflagWallet(wallet)
                } else {
                    store.flagWallet(wallet, reason: "Manual flag")
                }
            }
            Divider()
            Button("Remove from Investigation", role: .destructive) {
                store.removeWalletFromInvestigation(wallet)
            }
        }
    }

    // MARK: - Wallet view

    private var walletView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.isloading {
                    ProgressView("Looking up wallet…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if let wallet = store.lastWallet {
                    walletCard(wallet)
                    if !store.transactions.isEmpty {
                        transactionsSection
                    }
                } else if let error = store.lastError {
                    errorView(error)
                } else {
                    emptyState
                }
            }
        }
    }

    private func walletCard(_ wallet: BlockyWallet) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let label = wallet.label {
                        Text(label)
                            .font(.headline)
                             .foregroundStyle(Color.accentColor)
                    }
                    Text(wallet.chain.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isloading {
                    ProgressView().controlSize(.small)
                }
            }

            // Balance
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatBalance(wallet.balance, chain: wallet.chain))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                Text(wallet.chain.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Address (truncated)
            Text(wallet.address)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .textSelection(.enabled)

            // Stats
            HStack(spacing: 16) {
                statItem("Transactions", value: "\(wallet.txCount)")
                if let first = wallet.firstSeen {
                    statItem("First Seen", value: first)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func statItem(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
        }
    }

    // MARK: - Transactions section

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent Transactions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(store.transactions.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)

            ForEach(store.transactions) { tx in
                transactionRow(tx)
                if tx.id != store.transactions.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private func transactionRow(_ tx: BlockyTransaction) -> some View {
        let isOutgoing = tx.from.lowercased() == store.lastWallet?.address.lowercased()
        let directionIcon = isOutgoing ? "arrow.up.right" : "arrow.down.left"
        let directionColor: Color = isOutgoing ? .red : .green
        let directionLabel = isOutgoing ? "Sent" : "Received"

        return HStack(spacing: 10) {
            Image(systemName: directionIcon)
                .font(.caption)
                .foregroundStyle(directionColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(directionLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(directionColor)
                Text(counterparty(isOutgoing ? tx.to : tx.from))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(isOutgoing ? "-" : "+")\(formatBalance(tx.value, chain: tx.chain))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isOutgoing ? .red : .green)
                if let ts = tx.timestamp {
                    Text(formatTimestamp(ts))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy TX Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tx.txHash, forType: .string)
            }
            Button("Copy From Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tx.from, forType: .string)
            }
            Button("Copy To Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tx.to, forType: .string)
            }
        }
    }

    // MARK: - Trace view

    private var traceView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let wallet = store.lastWallet {
                    // Depth control
                    HStack {
                        Text("Trace depth:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $traceDepth) {
                            Text("10").tag(10)
                            Text("20").tag(20)
                            Text("50").tag(50)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)

                        Button("Refresh") {
                            Task {
                                await store.trace(
                                    address: wallet.address,
                                    chain: wallet.chain,
                                    depth: traceDepth)
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .disabled(store.isTracing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

                    if store.isTracing {
                        ProgressView("Tracing transactions…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if store.transactions.isEmpty {
                        ContentUnavailableView(
                            "No Transactions Found",
                            systemImage: "arrow.triangle.branch",
                            description: Text("This wallet has no visible transaction history.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        // Transaction flow visualization
                        traceFlow
                    }
                } else {
                    ContentUnavailableView(
                        "Search a Wallet First",
                        systemImage: "magnifyingglass",
                        description: Text("Enter a wallet address above to trace its transaction flow.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }
            }
        }
    }

    private var traceFlow: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Flow summary
            if let wallet = store.lastWallet {
                let incoming = store.transactions.filter { $0.to.lowercased() == wallet.address.lowercased() }
                let outgoing = store.transactions.filter { $0.from.lowercased() == wallet.address.lowercased() }
                let totalIn = incoming.reduce(0) { $0 + $1.value }
                let totalOut = outgoing.reduce(0) { $0 + $1.value }

                HStack(spacing: 20) {
                    flowStat("Incoming", count: incoming.count, total: totalIn, color: .green, icon: "arrow.down.left")
                    flowStat("Outgoing", count: outgoing.count, total: totalOut, color: .red, icon: "arrow.up.right")
                    flowStat("Net Flow", count: nil, total: totalIn - totalOut, color: totalIn - totalOut >= 0 ? .green : .red, icon: "arrow.left.arrow.right")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            // Unique counterparties
            let counterparties = Set(store.transactions.map { store.lastWallet?.address.lowercased() == $0.from.lowercased() ? $0.to : $0.from })
            if !counterparties.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Counterparties (\(counterparties.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 12)

                    ForEach(Array(counterparties.prefix(10)), id: \.self) { addr in
                        let entity = store.taggedEntities[addr]
                        HStack(spacing: 8) {
                            Circle()
                                .fill(entity != nil ? Color.accentColor : Color.secondary)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                if let entity {
                                    Text(entity.name)
                                        .font(.caption.weight(.medium))
                                    Text(entity.category)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(shortAddress(addr))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
            }

            // Full transaction list
            transactionsSection
        }
    }

    private func flowStat(_ label: String, count: Int?, total: Double, color: Color, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            if let count {
                Text("\(count) tx")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(formatBalance(total, chain: store.lastWallet?.chain ?? .btc))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty / Error states

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "link.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Enter a Wallet Address")
                .font(.headline)
            Text("Paste a Bitcoin or Ethereum address above to look up\nbalance, transactions, and entity labels.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Lookup Failed")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Formatting helpers

    private func formatBalance(_ value: Double, chain: BlockyChain) -> String {
        switch chain {
        case .btc:
            return String(format: "%.8f", value)
        case .eth:
            if value >= 1 { return String(format: "%.4f", value) }
            return String(format: "%.6f", value)
        }
    }

    private func shortAddress(_ addr: String) -> String {
        if addr.count > 16 {
            return String(addr.prefix(8)) + "…" + String(addr.suffix(6))
        }
        return addr
    }

    private func counterparty(_ addr: String) -> String {
        if let entity = store.taggedEntities[addr] {
            return "\(entity.name) (\(entity.category))"
        }
        return shortAddress(addr)
    }

    private func formatTimestamp(_ iso: String) -> String {
        let fmt = ISO8601DateFormatter()
        guard let date = fmt.date(from: iso) else { return iso }
        let display = DateFormatter()
        display.dateFormat = "MMM d, HH:mm"
        return display.string(from: date)
    }

    private func formatDate(_ iso: String) -> String {
        let fmt = ISO8601DateFormatter()
        guard let date = fmt.date(from: iso) else { return iso }
        let display = DateFormatter()
        display.dateFormat = "MMM d, yyyy"
        return display.string(from: date)
    }
}
