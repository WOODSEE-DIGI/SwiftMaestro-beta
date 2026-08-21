import SwiftUI

// MARK: - Browser Privacy Popover
//
// Cookie + site-data management for SwiftBrowser's WebKit engine, plus
// privacy defaults (private-by-default new tabs, clear-on-quit). Chromium
// tabs are session-scoped by design (throwaway temp profile per launch), so
// this manages the shared WebKit data store.

struct BrowserPrivacyPopover: View {
    let store: WebBrowserStore
    @State private var privacy = BrowserPrivacyStore.shared
    @State private var expandedDomain: String?
    @State private var confirmClearAll = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            togglesSection
            Divider()
            siteDataSection
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
        .frame(width: 440)
        .frame(maxHeight: 540)
        .task { await privacy.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text("Privacy")
                .font(.headline)
            Spacer()
            if let lastRefresh = privacy.lastRefresh {
                Text(lastRefresh.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button {
                Task { await privacy.refresh() }
            } label: {
                if privacy.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .help("Refresh site data")
        }
        .padding(12)
    }

    // MARK: - Toggles

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $privacy.privateNewTabs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Private new tabs by default")
                        .font(.callout)
                    Text("Cookies and site data vanish when the tab closes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $privacy.clearOnQuit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clear site data on quit")
                        .font(.callout)
                    Text("Wipes cookies, cache, and storage when SwiftMaestro closes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    // MARK: - Site data

    private var siteDataSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Site Data")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text("\(privacy.siteRecords.count) sites · \(privacy.cookies.count) cookies")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !privacy.siteRecords.isEmpty {
                    Button("Clear All…") { confirmClearAll = true }
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if privacy.siteRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text(privacy.isLoading ? "Loading…" : "No site data stored")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(privacy.siteRecords) { record in
                            siteRow(record)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear ALL site data?",
            isPresented: $confirmClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear All Site Data", role: .destructive) {
                Task {
                    await privacy.clearAllSiteData()
                    showStatus("All site data cleared")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes cookies, cache, local storage, and service workers for every site in the shared WebKit store. This signs you out of websites in SwiftBrowser.")
        }
    }

    private func siteRow(_ record: SiteDataRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.domain)
                        .font(.callout.weight(.medium))
                    Text(siteSummary(record))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if record.cookieCount > 0 {
                    Button {
                        expandedDomain = expandedDomain == record.domain ? nil : record.domain
                    } label: {
                        Image(systemName: expandedDomain == record.domain
                              ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Inspect cookies")
                }
                Button(role: .destructive) {
                    Task {
                        await privacy.deleteSiteData(forDomain: record.domain)
                        showStatus("Cleared \(record.domain)")
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Delete all data for \(record.domain)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            // Expanded cookie inspector
            if expandedDomain == record.domain {
                let domainCookies = privacy.cookies(forDomain: record.domain)
                if domainCookies.isEmpty {
                    Text("No cookies")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                } else {
                    ForEach(domainCookies) { cookie in
                        cookieRow(cookie)
                    }
                }
            }
        }
    }

    private func cookieRow(_ cookie: CookieRecord) -> some View {
        HStack(spacing: 6) {
            Image(systemName: cookie.isSecure ? "lock.fill" : "lock.open")
                .font(.caption2)
                .foregroundStyle(cookie.isSecure ? .green : .orange)
                .frame(width: 12)
            Text(cookie.name)
                .font(.caption.monospaced())
                .lineLimit(1)
            Spacer()
            Text(cookie.expiryDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if cookie.isHTTPOnly {
                Text("HTTP")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2), in: .rect(cornerRadius: 3))
            }
            Button(role: .destructive) {
                Task {
                    await privacy.deleteCookie(cookie)
                    showStatus("Deleted cookie \(cookie.name)")
                }
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 4)
    }

    private func siteSummary(_ record: SiteDataRecord) -> String {
        var parts: [String] = []
        if record.cookieCount > 0 { parts.append("\(record.cookieCount) cookies") }
        let types = record.dataTypeSummary
        if !types.isEmpty { parts.append(types) }
        return parts.joined(separator: " · ")
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if statusMessage == message { statusMessage = nil }
        }
    }
}
