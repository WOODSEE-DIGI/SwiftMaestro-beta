import SwiftUI

// MARK: - Stock Investigation Detail View
//
// Slide-in detail pane shown when a watchlist stock is tapped.
// Four tabs: Holdings (institutional), Insider (Form 4), Proxy (DEF 14A voting), Notes.

struct StockInvestigationView: View {
    let symbol: String
    @Bindable var store: StocksStore
    let onClose: () -> Void

    enum DetailTab: String, CaseIterable {
        case holdings = "Holdings"
        case insider = "Insider"
        case proxy = "Proxy"
        case notes = "Notes"
    }

    @State private var detailTab: DetailTab = .holdings
    @State private var newNote = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            detailTabPicker
            Divider()
            ScrollView {
                switch detailTab {
                case .holdings: holdingsTab
                case .insider: insiderTab
                case .proxy: proxyTab
                case .notes: notesTab
                }
            }
        }
        .task {
            store.loadHolders(symbol: symbol)
            store.loadInsiderTransactions(symbol: symbol)
            store.loadProxyFilings(symbol: symbol)
            store.loadNotes(symbol: symbol)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(symbol)
                    .font(.title3.weight(.bold))
                if let quote = store.quotes[symbol] {
                    Text(String(format: "%.2f  %@%.2f%%",
                                quote.price,
                                (quote.changePercent ?? 0) >= 0 ? "+" : "",
                                quote.changePercent ?? 0))
                        .font(.caption)
                        .foregroundStyle((quote.changePercent ?? 0) >= 0 ? .green : .red)
                        .monospacedDigit()
                }
            }
            Spacer()
            Button {
                Task {
                    async let h: () = store.fetchHolders(symbol: symbol)
                    async let i: () = store.fetchInsiderTransactions(symbol: symbol)
                    async let p: () = store.fetchProxyFilings(symbol: symbol)
                    _ = await (h, i, p)
                }
            } label: {
                if store.isLoadingHolders || store.isLoadingInsider || store.isLoadingProxy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Fetch latest holdings, insider & proxy data")
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close investigation")
        }
        .padding(12)
    }

    // MARK: - Detail tab picker

    private var detailTabPicker: some View {
        HStack(spacing: 0) {
            ForEach(DetailTab.allCases, id: \.self) { tab in
                Button {
                    detailTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.caption.weight(detailTab == tab ? .semibold : .regular))
                        .foregroundStyle(detailTab == tab ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Holdings tab (institutional holders)

    @ViewBuilder
    private var holdingsTab: some View {
        let holders = store.holdersCache[symbol] ?? []
        if holders.isEmpty {
            emptyState("No institutional holder data", icon: "building.columns",
                       hint: "Tap refresh to fetch from Yahoo Finance")
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(holders) { holder in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(holder.holderName)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            if let pct = holder.percentHeld {
                                Text(String(format: "%.2f%%", pct * 100))
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                            }
                        }
                        HStack(spacing: 12) {
                            if let shares = holder.sharesHeld {
                                Label(formatShares(shares), systemImage: "chart.pie")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let chg = holder.changeShares, chg != 0 {
                                Label(String(format: "%@%.0f", chg > 0 ? "+" : "", chg),
                                      systemImage: chg > 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.caption2)
                                    .foregroundStyle(chg > 0 ? .green : .red)
                            }
                            if let date = holder.dateReported {
                                Text(date)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    // MARK: - Insider tab (SEC Form 4)

    @ViewBuilder
    private var insiderTab: some View {
        let txs = store.insiderCache[symbol] ?? []
        if txs.isEmpty {
            emptyState("No insider transactions", icon: "person.badge.shield.checkmark",
                       hint: "Tap refresh to fetch SEC Form 4 filings from EDGAR")
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(txs) { tx in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(tx.insiderName)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            txBadge(tx.transactionType)
                        }
                        HStack(spacing: 10) {
                            if let title = tx.title, !title.isEmpty {
                                Text(title).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let shares = tx.shares {
                                Text(formatShares(shares) + " shares")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if let price = tx.pricePerShare {
                                Text(String(format: "@ $%.2f", price))
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        HStack(spacing: 10) {
                            if let td = tx.transactionDate {
                                Text(td).font(.caption2).foregroundStyle(.tertiary)
                            }
                            if let total = tx.totalValue, total > 0 {
                                Text(formatCurrency(total))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private func txBadge(_ type: String) -> some View {
        let (color, icon): (Color, String) = {
            switch type {
            case "Purchase", "Acquisition": return (.green, "arrow.down.circle.fill")
            case "Sale", "Disposition": return (.red, "arrow.up.circle.fill")
            case "Option Exercise": return (.blue, "gearshape")
            case "Gift": return (.purple, "gift")
            default: return (.gray, "circle")
            }
        }()
        return Label(type, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    // MARK: - Proxy tab (DEF 14A voting)

    @ViewBuilder
    private var proxyTab: some View {
        let filings = store.proxyCache[symbol] ?? []
        if filings.isEmpty {
            emptyState("No proxy/voting filings", icon: "checkmark.bubble",
                       hint: "Tap refresh to fetch DEF 14A proxy statements from SEC EDGAR")
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(filings) { filing in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(filing.companyName ?? symbol)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text(filing.filingDate)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let meeting = filing.meetingDate {
                            Label("Meeting: \(meeting)", systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let proposalsJSON = filing.proposals,
                           let data = proposalsJSON.data(using: .utf8),
                           let proposals = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Proposals (\(proposals.count))")
                                    .font(.caption.weight(.semibold))
                                ForEach(0..<proposals.count, id: \.self) { i in
                                    if let num = proposals[i]["number"] as? Int,
                                       let title = proposals[i]["title"] as? String {
                                        HStack(alignment: .top, spacing: 6) {
                                            Text("\(num).")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 20, alignment: .trailing)
                                            Text(title)
                                                .font(.caption)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                        }
                        if let boardJSON = filing.boardMembers,
                           let data = boardJSON.data(using: .utf8),
                           let board = try? JSONSerialization.jsonObject(with: data) as? [String],
                           !board.isEmpty {
                            DisclosureGroup("Board of Directors (\(board.count))") {
                                ForEach(board, id: \.self) { member in
                                    Text(member)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption.weight(.medium))
                        }
                        if let urlStr = filing.url, let url = URL(string: urlStr) {
                            Link("View filing on SEC EDGAR", destination: url)
                                .font(.caption)
                        }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 8))
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Notes tab

    @ViewBuilder
    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("Add a note about \(symbol)…", text: $newNote)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitNote() }
                Button(action: submitNote) {
                    Image(systemName: "plus.bubble")
                }
                .disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)

            let notes = store.notesCache[symbol] ?? []
            if notes.isEmpty {
                emptyState("No notes yet", icon: "note.text",
                           hint: "Record observations, thesis, or findings")
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(notes) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.content)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text(note.author)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text(note.createdAt.prefix(10))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }

    private func submitNote() {
        let text = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        _ = store.addNote(symbol: symbol, content: text)
        newNote = ""
    }

    // MARK: - Helpers

    private func emptyState(_ title: String, icon: String, hint: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func formatShares(_ shares: Double) -> String {
        if shares >= 1_000_000 { return String(format: "%.1fM", shares / 1_000_000) }
        if shares >= 1_000 { return String(format: "%.1fK", shares / 1_000) }
        return String(format: "%.0f", shares)
    }

    private func formatCurrency(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "$%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "$%.1fK", value / 1_000) }
        return String(format: "$%.2f", value)
    }
}
