import SwiftUI

// MARK: - Stocks panel
//
// Watchlist with live quotes and 90-day sparklines. Data from stooq's free
// CSV endpoints (no API key). Symbols: US tickers plain ("AAPL"), other
// markets with suffix ("bhp.au"), indices with caret ("^spx").

struct StocksPanel: View {
    @State private var store = StocksStore.shared
    @State private var newSymbol = ""
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()
            if store.watchlist.isEmpty {
                emptyState
            } else {
                quoteList
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
            TextField("Add symbol (AAPL, bhp.au, ^spx)…", text: $newSymbol)
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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No symbols yet")
                .font(.headline)
            Text("Add a ticker above to start a watchlist.\nUS stocks plain (AAPL), other markets with a suffix (bhp.au).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Quote list

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

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displaySymbol)
                    .font(.body.weight(.semibold))
                if let quote {
                    Text(dayRangeText(quote))
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
                Text(quote?.close.map { String(format: "%.2f", $0) } ?? "—")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Text(changePct.map { String(format: "%@%.2f%%", $0 >= 0 ? "+" : "", $0) } ?? "—")
                    .font(.caption)
                    .foregroundStyle(changeColor)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Remove \(item.displaySymbol)", role: .destructive) {
                store.remove(symbol: item.symbol)
            }
        }
    }

    private func dayRangeText(_ quote: StockQuote) -> String {
        guard let low = quote.low, let high = quote.high else { return quote.date }
        return String(format: "%.2f – %.2f", low, high)
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
