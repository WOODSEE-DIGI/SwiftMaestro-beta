import Foundation

// MARK: - OwnTrack embedded relay manager

/// Runs the OwnTrack tracking relay (vendored `RelayHTTPServer`) in-process,
/// so SwiftMaestro users get email open/click tracking from the DMG with no
/// external server to install or run.
///
/// The signing secret is generated once and stored in the local (non-iCloud)
/// Keychain. Events persist to the app's Application Support directory, and
/// the store path is compatible with the standalone TrackingRelayServer's
/// JSON format, so existing relay-store.json files can be dropped in.
@Observable
@MainActor
final class OwnTrackRelayManager {
    static let shared = OwnTrackRelayManager()

    /// Whether the embedded listener is currently bound and serving.
    private(set) var isRunning = false

    /// Whether the embedded relay starts itself at app launch. Persisted;
    /// defaults to true so tracking "just works" with no setup.
    var autoStartRelay: Bool {
        didSet { UserDefaults.standard.set(autoStartRelay, forKey: Self.autoStartKey) }
    }

    /// Last startup/bind failure, shown in the Mail panel when startup fails
    /// (e.g. another relay instance already holds port 8087).
    private(set) var lastError: String?

    /// Listen port. Fixed at 8087 to match the standalone relay's default and
    /// the `AppleMailService` default base URL — a port setting can be added
    /// later if anyone actually collides with it.
    let port: UInt16 = 8087

    /// Public base URL recipients' clients will hit when they open a tracked
    /// email. For local-only tracking this stays at `http://localhost:8087`.
    /// For real-world tracking, set this to a publicly reachable URL (e.g.
    /// `https://swiftmaestro.com/tracking`) that proxies to the relay.
    var publicBaseURL: URL {
        get {
            if let stored = UserDefaults.standard.string(forKey: Self.publicBaseURLKey),
               let url = URL(string: stored), url.scheme != nil {
                return url
            }
            return URL(string: "http://localhost:\(port)")!
        }
        set {
            UserDefaults.standard.set(newValue.absoluteString, forKey: Self.publicBaseURLKey)
        }
    }

    /// API key for the external (PHP) tracking relay. Serves as both the
    /// signing secret for tracking tokens and the user identity for event
    /// isolation — each user can only see their own events.
    ///
    /// Generated once on first access and stored in the local Keychain.
    /// Falls back to UserDefaults when the Keychain is unavailable.
    var relayAPIKey: String {
        if let cached = _relayAPIKey { return cached }
        let key = loadOrCreateRelayAPIKey()
        _relayAPIKey = key
        return key
    }
    private var _relayAPIKey: String?

    /// Where events + message records are persisted (JSON, standalone-relay
    /// compatible format).
    let storeURL: URL

    private var server: RelayHTTPServer?

    private static let signingSecretAccount = "owntrack-signing-secret"
    private static let relayAPIKeyAccount = "owntrack-relay-api-key"
    private static let autoStartKey = "owntrack.autoStartRelay"
    private static let publicBaseURLKey = "owntrack.publicBaseURL"

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storeURL = appSupport
            .appendingPathComponent("SwiftMaestro/mailtracker", isDirectory: true)
            .appendingPathComponent("relay-store.json")
        autoStartRelay = UserDefaults.standard.object(forKey: Self.autoStartKey) as? Bool ?? false

        // Seed from the AppleMailService base URL if the user set one there,
        // so pixel injection and service queries stay in sync.
        if let stored = UserDefaults.standard.string(forKey: "appleMail.relayBaseURL"),
           let url = URL(string: stored), url.scheme != nil {
            UserDefaults.standard.set(url.absoluteString, forKey: Self.publicBaseURLKey)
        }
    }

    // MARK: - Lifecycle

    /// Starts the embedded relay if it isn't already running. Safe to call
    /// repeatedly. Returns true when the relay is running after the call.
    @discardableResult
    func startRelay() -> Bool {
        guard server == nil else {
            isRunning = true
            return true
        }
        lastError = nil

        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let configuration = RelayConfiguration(
                host: "localhost",
                port: port,
                signingSecret: try loadOrCreateSigningSecret(),
                baseURL: publicBaseURL,
                storeURL: storeURL
            )
            let server = try RelayHTTPServer(configuration: configuration)
            server.start()
            self.server = server
            isRunning = true
            return true
        } catch {
            lastError = error.localizedDescription
            isRunning = false
            return false
        }
    }

    func stopRelay() {
        server?.stop()
        server = nil
        isRunning = false
    }

    // MARK: - Signing secret

    /// Reads the HMAC signing secret from the local Keychain, generating and
    /// storing a fresh random one on first use. Local-only (not iCloud
    /// synchronizable): tokens signed on this machine are verified by this
    /// machine's relay.
    ///
    /// Falls back to a UserDefaults-persisted secret when the Keychain is
    /// unavailable (locked keychain in xctest hosts, ad-hoc-signature churn
    /// across rebuilds). The secret only signs localhost tracking tokens, so
    /// degraded storage is acceptable — a hard failure would kill tracking
    /// entirely in those environments.
    private func loadOrCreateSigningSecret() throws -> String {
        do {
            if let existing = try KeychainService.read(account: Self.signingSecretAccount, allowUI: false),
               !existing.isEmpty {
                return existing
            }
            let generated = UUID().uuidString + UUID().uuidString
            try KeychainService.store(account: Self.signingSecretAccount, value: generated, synchronizable: false)
            return generated
        } catch {
            if let fallback = UserDefaults.standard.string(forKey: Self.signingSecretFallbackKey),
               !fallback.isEmpty {
                return fallback
            }
            let generated = UUID().uuidString + UUID().uuidString
            UserDefaults.standard.set(generated, forKey: Self.signingSecretFallbackKey)
            return generated
        }
    }

    private static let signingSecretFallbackKey = "owntrack.signingSecret.fallback"

    /// Reads the relay API key from the local Keychain, generating and storing
    /// a fresh random one on first use. The key is a 64-char hex string
    /// (UUID+UUID) used as both the HMAC signing secret for tracking tokens
    /// and the user identity for event isolation on the external PHP relay.
    private func loadOrCreateRelayAPIKey() -> String {
        do {
            if let existing = try KeychainService.read(account: Self.relayAPIKeyAccount, allowUI: false),
               !existing.isEmpty {
                return existing
            }
            let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            try KeychainService.store(account: Self.relayAPIKeyAccount, value: generated, synchronizable: false)
            return generated
        } catch {
            if let fallback = UserDefaults.standard.string(forKey: Self.relayAPIKeyFallbackKey),
               !fallback.isEmpty {
                return fallback
            }
            let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            UserDefaults.standard.set(generated, forKey: Self.relayAPIKeyFallbackKey)
            return generated
        }
    }

    private static let relayAPIKeyFallbackKey = "owntrack.relayAPIKey.fallback"
}
