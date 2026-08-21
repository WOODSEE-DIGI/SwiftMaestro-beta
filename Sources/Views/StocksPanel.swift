import SwiftUI

// MARK: - Stocks panel
//
// Two-tab stock panel: Watchlist (saved stocks) and Discover (market movers).
// Data from Yahoo Finance's chart and screener APIs — no API key needed.

struct StocksPanel: View {
    enum Tab: String, CaseIterable {
        case watchlist = "Watchlist"
        case discover = "Discover"
    }

    @State private var store = StocksStore.shared
    @State private var newSymbol = ""
    @State private var refreshTimer: Timer?
    @State private var selectedTab: Tab = .watchlist
    @State private var selectedSymbol: String?

    var body: some View {
        HStack(spacing: 0) {
            // Left: list / discover
            VStack(spacing: 0) {
                addBar
                Divider()
                tabPicker
                Divider()
                if selectedTab == .watchlist {
                    watchlistView
                } else {
                    StocksDiscoverView(store: store)
                }
            }
            .frame(minWidth: 320)

            // Right: investigation detail (when a stock is selected)
            if let symbol = selectedSymbol {
                Divider()
                StockInvestigationView(symbol: symbol, store: store, onClose: {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedSymbol = nil }
                })
                .frame(minWidth: 420, idealWidth: 520)
            }
        }
        .onAppear {
            Task {
                await store.refreshQuotes()
                await store.refreshHistory()
            }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task { @MainActor in await StocksStore.shared.refreshQuotes() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
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

    // MARK: - Add bar

    private func addSymbol() {
        let symbol = newSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbol.isEmpty else { return }
        if store.add(symbol: symbol) != nil {
            newSymbol = ""
        }
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(.secondary)
            TextField("Add symbol (AAPL, BHP.AX, 600519.SS, ^GSPC)…", text: $newSymbol)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addSymbol() }
            Button(action: addSymbol) {
                Image(systemName: "plus")
            }
            .disabled(newSymbol.trimmingCharacters(in: .whitespaces).isEmpty)
            Button {
                Task {
                    await store.refreshQuotes()
                    await store.refreshHistory()
                }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Refresh quotes")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Watchlist tab

    private var watchlistView: some View {
        Group {
            if store.watchlist.isEmpty {
                featuredLanding
            } else {
                quoteList
            }
        }
    }

    // MARK: - Featured landing (empty watchlist)

    /// Curated landing-page symbols grouped by market.
    private static let featured: [(name: String, symbols: [(symbol: String, label: String)])] = [
        ("US Tech", [
            ("AAPL", "Apple"), ("MSFT", "Microsoft"), ("NVDA", "NVIDIA"),
            ("GOOGL", "Alphabet"), ("AMZN", "Amazon"), ("META", "Meta"),
        ]),
        ("US Indices", [
            ("^GSPC", "S&P 500"), ("^DJI", "Dow Jones"), ("^IXIC", "Nasdaq"),
        ]),
        ("Australia", [
            ("BHP.AX", "BHP"), ("CBA.AX", "Commonwealth Bank"),
            ("CSL.AX", "CSL"), ("NAB.AX", "National Australia"),
        ]),
    ]

    @State private var featuredQuotes: [String: StockQuote] = [:]
    @State private var featuredHistory: [String: [Double]] = [:]
    @State private var featuredLoading = true

    private func loadFeatured() async {
        featuredLoading = true
        let allSymbols = Self.featured.flatMap { $0.symbols.map(\.symbol) }
        await withTaskGroup(of: (String, StockQuote?).self) { group in
            for sym in allSymbols {
                group.addTask { (sym, try? await StocksStore.shared.quote(for: sym)) }
            }
            for await (sym, quote) in group {
                if let quote { featuredQuotes[sym] = quote }
            }
        }
        await withTaskGroup(of: (String, [Double]?).self) { group in
            for sym in allSymbols {
                group.addTask { (sym, await StocksStore.shared.historyCloses(for: sym)) }
            }
            for await (sym, closes) in group {
                if let closes, !closes.isEmpty { featuredHistory[sym] = closes }
            }
        }
        featuredLoading = false
    }

    private var featuredLanding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Your Watchlist")
                        .font(.title3.weight(.semibold))
                    Text("Tap a stock to add it, or type a symbol above.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
                .padding(.bottom, 4)

                if featuredLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    ForEach(Self.featured, id: \.name) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 12)

                            ForEach(section.symbols, id: \.symbol) { item in
                                featuredRow(item.symbol, label: item.label)
                            }
                        }
                    }
                }
                Spacer(minLength: 20)
            }
        }
        .task { await loadFeatured() }
    }

    private func featuredRow(_ symbol: String, label: String) -> some View {
        let quote = featuredQuotes[symbol]
        let history = featuredHistory[symbol] ?? []
        let changePct = quote?.changePercent
        let changeColor: Color = (changePct ?? 0) >= 0 ? .green : .red
        let isInWatchlist = store.watchlist.contains { $0.symbol == symbol }

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body.weight(.medium))
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .leading)

            SparklineView(values: history, color: changeColor)
                .frame(width: 56, height: 20)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(quote.map { String(format: "%.2f", $0.price) } ?? "—")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Text(changePct.map { String(format: "%@%.2f%%", $0 >= 0 ? "+" : "", $0) } ?? "—")
                    .font(.caption2)
                    .foregroundStyle(changeColor)
                    .monospacedDigit()
            }

            if isInWatchlist {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isInWatchlist {
                withAnimation(.easeOut(duration: 0.2)) {
                    store.add(symbol: symbol)
                }
            }
        }
    }

    // MARK: - Quote list (watchlist non-empty)

    private var quoteList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.watchlist) { item in
                    quoteRow(item)
                    Divider().padding(.leading, 12)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = store.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(6)
                    .background(.regularMaterial, in: .rect(cornerRadius: 6))
                    .padding(8)
            }
        }
    }

    private func quoteRow(_ item: StockWatchItem) -> some View {
        let quote = store.quotes[item.symbol]
        let history = store.histories[item.symbol] ?? []
        let changePct = quote?.changePercent
        let changeColor: Color = (changePct ?? 0) >= 0 ? .green : .red
        let tracked = store.trackedStocks.first { $0.symbol == item.symbol }

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.displaySymbol)
                        .font(.body.weight(.semibold))
                    if tracked?.isFlagged == true {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let quote, let low = quote.dayLow, let high = quote.dayHigh {
                    Text(String(format: "%.2f – %.2f", low, high))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 90, alignment: .leading)

            SparklineView(values: history, color: changeColor)
                .frame(width: 64, height: 24)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(quote.map { String(format: "%.2f", $0.price) } ?? "—")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Text(changePct.map { String(format: "%@%.2f%%", $0 >= 0 ? "+" : "", $0) } ?? "—")
                    .font(.caption)
                    .foregroundStyle(changeColor)
                    .monospacedDigit()
            }

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedSymbol = item.symbol
            }
        }
        .contextMenu {
            Button("Investigate \(item.displaySymbol)") {
                selectedSymbol = item.symbol
            }
            if let tracked {
                if tracked.isFlagged {
                    Button("Unflag") { store.unflagStock(id: tracked.id) }
                } else {
                    Button("Flag as Suspicious") { store.flagStock(id: tracked.id, reason: "Manual flag") }
                }
            }
            Divider()
            Button("Remove \(item.displaySymbol)", role: .destructive) {
                store.remove(symbol: item.symbol)
            }
        }
    }
}

// MARK: - Sparkline

/// Tiny line-chart of trailing closes, drawn in a Canvas — no chart
/// dependency. Colored by the day's direction.
struct SparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2,
                  let minV = values.min(), let maxV = values.max(), maxV > minV else { return }
            let stepX = size.width / CGFloat(values.count - 1)
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * stepX
                let normalized = (value - minV) / (maxV - minV)
                let y = size.height - (CGFloat(normalized) * (size.height - 2) + 1)
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
    }
}
