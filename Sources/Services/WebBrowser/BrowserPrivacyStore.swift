import Foundation
import WebKit

// MARK: - Browser Privacy Store
//
// Cookie and site-data management for SwiftBrowser's WebKit engine.
// WKWebView tabs share the app's default WKWebsiteDataStore — cookies, cache,
// localStorage, IndexedDB accumulate silently with no user visibility. This
// store exposes what's stored and provides deletion, plus privacy settings:
// private-by-default new tabs and clear-site-data-on-quit.
//
// Note: Chromium tabs already use a throwaway temp profile per session
// (ChromiumCDPClient), so they persist nothing between launches by design.

/// One site's stored data, grouped by domain.
struct SiteDataRecord: Identifiable, Equatable, Sendable {
    var id: String { domain }
    let domain: String
    /// WK data types present (cookies, cache, localStorage, …)
    var dataTypes: [String]
    var cookieCount: Int = 0

    var dataTypeSummary: String {
        dataTypes.map { t in
            switch t {
            case WKWebsiteDataTypeCookies: return "Cookies"
            case WKWebsiteDataTypeLocalStorage: return "Local storage"
            case WKWebsiteDataTypeIndexedDBDatabases: return "IndexedDB"
            case WKWebsiteDataTypeDiskCache: return "Cache"
            case WKWebsiteDataTypeMemoryCache: return "Memory cache"
            case WKWebsiteDataTypeOfflineWebApplicationCache: return "Offline cache"
            case WKWebsiteDataTypeSessionStorage: return "Session storage"
            case WKWebsiteDataTypeServiceWorkerRegistrations: return "Service worker"
            default: return t.replacingOccurrences(of: "WKWebsiteDataType", with: "")
            }
        }.sorted().joined(separator: ", ")
    }
}

/// A cookie with the fields worth showing a user.
struct CookieRecord: Identifiable, Equatable, Sendable {
    var id: String { "\(domain)|\(name)|\(path)" }
    let name: String
    let domain: String
    let path: String
    let expires: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool
    let isSessionOnly: Bool

    var expiryDescription: String {
        if isSessionOnly { return "Session" }
        guard let expires else { return "—" }
        if expires < Date() { return "Expired" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expires).day ?? 0
        if days > 365 { return "\(days / 365)y" }
        if days > 30 { return "\(days / 30)mo" }
        if days >= 1 { return "\(days)d" }
        return "Today"
    }
}

@MainActor
@Observable
final class BrowserPrivacyStore {
    static let shared = BrowserPrivacyStore()

    private(set) var siteRecords: [SiteDataRecord] = []
    private(set) var cookies: [CookieRecord] = []
    private(set) var isLoading = false
    private(set) var lastRefresh: Date?

    // MARK: - Settings (persisted)

    /// New tabs start private (non-persistent data store) by default.
    var privateNewTabs: Bool {
        didSet { UserDefaults.standard.set(privateNewTabs, forKey: Self.privateNewTabsKey) }
    }

    /// Wipe all WebKit site data (cookies, cache, storage) when the app quits.
    var clearOnQuit: Bool {
        didSet { UserDefaults.standard.set(clearOnQuit, forKey: Self.clearOnQuitKey) }
    }

    private static let privateNewTabsKey = "browser.privateNewTabs"
    private static let clearOnQuitKey = "browser.clearOnQuit"

    private init() {
        privateNewTabs = UserDefaults.standard.bool(forKey: Self.privateNewTabsKey)
        clearOnQuit = UserDefaults.standard.bool(forKey: Self.clearOnQuitKey)
    }

    // MARK: - Query

    /// All website data types we surface in the manager.
    static let managedDataTypes: Set<String> = [
        WKWebsiteDataTypeCookies,
        WKWebsiteDataTypeLocalStorage,
        WKWebsiteDataTypeIndexedDBDatabases,
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeSessionStorage,
        WKWebsiteDataTypeServiceWorkerRegistrations,
        WKWebsiteDataTypeOfflineWebApplicationCache,
    ]

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let store = WKWebsiteDataStore.default()

        // Site data records (per-domain)
        let records = await store.dataRecords(ofTypes: Self.managedDataTypes)
        var byDomain: [String: SiteDataRecord] = [:]
        for record in records {
            var entry = byDomain[record.displayName] ?? SiteDataRecord(
                domain: record.displayName, dataTypes: [])
            entry.dataTypes.append(contentsOf: record.dataTypes.filter { !entry.dataTypes.contains($0) })
            byDomain[record.displayName] = entry
        }

        // Cookies
        let allCookies = await store.httpCookieStore.allCookies()
        let cookieRecords = allCookies.map { cookie in
            CookieRecord(
                name: cookie.name,
                domain: cookie.domain,
                path: cookie.path,
                expires: cookie.expiresDate,
                isSecure: cookie.isSecure,
                isHTTPOnly: cookie.isHTTPOnly,
                isSessionOnly: cookie.isSessionOnly)
        }
        cookies = cookieRecords.sorted { $0.domain.localizedCompare($1.domain) == .orderedAscending }

        // Merge cookie counts into site records (cookie domains have a leading dot)
        for (domain, entry) in byDomain {
            let needle = domain.hasPrefix(".") ? domain : ".\(domain)"
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            let count = cookieRecords.filter {
                $0.domain == domain || $0.domain == needle || $0.domain == bare
                    || $0.domain.hasSuffix(needle)
            }.count
            var updated = entry
            updated.cookieCount = count
            byDomain[domain] = updated
        }
        siteRecords = byDomain.values.sorted { $0.domain.localizedCompare($1.domain) == .orderedAscending }
        lastRefresh = Date()
    }

    func cookies(forDomain domain: String) -> [CookieRecord] {
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return cookies.filter {
            $0.domain == domain || $0.domain == ".\(bare)" || $0.domain == bare
                || $0.domain.hasSuffix(".\(bare)")
        }
    }

    // MARK: - Delete

    /// Delete ALL data (cookies, cache, storage) for one domain.
    func deleteSiteData(forDomain domain: String) async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: Self.managedDataTypes)
            .filter { $0.displayName == domain }
        await store.removeData(ofTypes: Self.managedDataTypes, for: records)
        await refresh()
    }

    /// Delete a single cookie.
    func deleteCookie(_ cookie: CookieRecord) async {
        let store = WKWebsiteDataStore.default()
        let all = await store.httpCookieStore.allCookies()
        for c in all where c.name == cookie.name && c.domain == cookie.domain && c.path == cookie.path {
            await store.httpCookieStore.delete(c)
        }
        await refresh()
    }

    /// Delete ALL cookies.
    func deleteAllCookies() async {
        let store = WKWebsiteDataStore.default()
        let all = await store.httpCookieStore.allCookies()
        for cookie in all {
            await store.httpCookieStore.delete(cookie)
        }
        await refresh()
    }

    /// Wipe everything: cookies, caches, storage, service workers.
    func clearAllSiteData() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: Self.managedDataTypes,
                               modifiedSince: .distantPast)
        await refresh()
    }

    /// Called from applicationWillTerminate when clearOnQuit is enabled.
    static func clearAllSiteDataSync() {
        let semaphore = DispatchSemaphore(value: 0)
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: managedDataTypes, modifiedSince: .distantPast) {
            semaphore.signal()
        }
        // Quit path: wait briefly, but never block termination longer than 3 s.
        _ = semaphore.wait(timeout: .now() + 3)
    }
}
