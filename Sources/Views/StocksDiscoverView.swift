import SwiftUI

// MARK: - Stocks Discover tab
//
// Market movers (top gainers, top losers, most active) plus a market overview
// with major indices. All data from Yahoo Finance screener + chart APIs.

struct StocksDiscoverView: View {
    let store: StocksStore

    /// Major market indices for the overview section.
    private static let indexSymbols: [(symbol: String, label: String)] = [
        ("^GSPC", "S&P 500"),
        ("^DJI", "Dow Jones"),
        ("^IXIC", "Nasdaq"),
        ("^RUT", "Russell 2000"),
        ("^VIX", "VIX"),
        ("^FTSE", "FTSE 100"),
        ("^N225", "Nikkei 225"),
        ("^AXJO", "ASX 200"),
    ]

    @State private var indexQuotes: [String: StockQuote] = [:]
    @State private var indexLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Discover")
                            .font(.title3.weight(.semibold))
                        Text("Market movers and major indices")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.isDiscoverLoading || indexLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await refreshAll() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                if store.isDiscoverLoading && indexLoading {
                    ProgressView("Loading market data…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    // Market Indices overview
                    marketIndicesSection

                    // Top Gainers
                    moverSection(title: "Top Gainers", icon: "arrow.up.right", color: .green, movers: store.topGainers)

                    // Top Losers
                    moverSection(title: "Top Losers", icon: "arrow.down.right", color: .red, movers: store.topLosers)

                    // Most Active
                    moverSection(title: "Most Active", icon: "burst", color: .orange, movers: store.mostActive)

                    // Supported Markets info
                    marketsInfoSection

                    Spacer(minLength: 20)
                }
            }
        }
        .task { await refreshAll() }
    }

    // MARK: - Refresh

    private func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await refreshIndices() }
            group.addTask { await store.refreshDiscover() }
        }
        indexLoading = false
    }

    private func refreshIndices() async {
        await withTaskGroup(of: (String, StockQuote?).self) { group in
            for item in Self.indexSymbols {
                group.addTask { (item.symbol, try? await store.quote(for: item.symbol)) }
            }
            for await (sym, quote) in group {
                if let quote { indexQuotes[sym] = quote }
            }
        }
    }

    // MARK: - Market Indices section

    private var marketIndicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Market Overview")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ], spacing: 8) {
                ForEach(Self.indexSymbols, id: \.symbol) { item in
                    indexCard(item.symbol, label: item.label)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func indexCard(_ symbol: String, label: String) -> some View {
        let quote = indexQuotes[symbol]
        let changePct = quote?.changePercent
        let changeColor: Color = (changePct ?? 0) >= 0 ? .green : .red

        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(quote.map { formatPrice($0.price) } ?? "—")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text(changePct.map { String(format: "%@%.2f%%", $0 >= 0 ? "+" : "", $0) } ?? "—")
                .font(.caption2)
                .foregroundStyle(changeColor)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    // MARK: - Mover section

    private func moverSection(title: String, icon: String, color: Color, movers: [StockMover]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 12)

            if movers.isEmpty {
                Text("No data available")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(movers) { mover in
                    moverRow(mover)
                }
            }
        }
    }

    private func moverRow(_ mover: StockMover) -> some View {
        let changeColor: Color = mover.changePercent >= 0 ? .green : .red
        let isInWatchlist = store.watchlist.contains { $0.symbol == mover.symbol }

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mover.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(mover.symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 100, idealWidth: 140, maxWidth: 200, alignment: .leading)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatPrice(mover.price))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Text(String(format: "%@%.2f%%", mover.changePercent >= 0 ? "+" : "", mover.changePercent))
                    .font(.caption)
                    .foregroundStyle(changeColor)
                    .monospacedDigit()
            }

            Button {
                if !isInWatchlist {
                    withAnimation(.easeOut(duration: 0.2)) {
                        store.add(symbol: mover.symbol)
                    }
                }
            } label: {
                if isInWatchlist {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(isInWatchlist)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: - Supported Markets info

    private var marketsInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Supported Markets")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)

            // Use adaptive grid for responsive layout
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 220, maximum: 400), spacing: 6),
            ], spacing: 6) {
                marketCard(icon: "🇺🇸", title: "United States", detail: "NYSE, NASDAQ — plain tickers\nAAPL, MSFT, TSLA")
                marketCard(icon: "🇦🇺", title: "Australia", detail: "ASX — suffix .AX\nBHP.AX, CBA.AX, CSL.AX")
                marketCard(icon: "🇨🇳", title: "China", detail: "SSE .SS / SZSE .SZ / HKEX .HK\n600519.SS, 0700.HK")
                marketCard(icon: "🇬🇧", title: "United Kingdom", detail: "LSE — suffix .L\nVOD.L, BP.L")
                marketCard(icon: "🇯🇵", title: "Japan", detail: "TSE — suffix .T\n7203.T")
                marketCard(icon: "🇩🇪", title: "Germany", detail: "XETRA — suffix .DE\nSAP.DE")
                marketCard(icon: "🇨🇦", title: "Canada", detail: "TSX — suffix .TO\nRY.TO")
                marketCard(icon: "🌍", title: "Indices", detail: "Caret prefix\n^GSPC, ^DJI, ^FTSE")
                marketCard(icon: "₿", title: "Crypto", detail: "Dash-USD suffix\nBTC-USD, ETH-USD")
                marketCard(icon: "💱", title: "Forex", detail: "=X suffix\nEURUSD=X")
            }
            .padding(.horizontal, 12)
        }
    }

    private func marketCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(icon)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    // MARK: - Formatting

    private func formatPrice(_ price: Double) -> String {
        if price >= 1000 {
            return String(format: "%.0f", price)
        } else if price >= 100 {
            return String(format: "%.1f", price)
        } else {
            return String(format: "%.2f", price)
        }
    }
}
