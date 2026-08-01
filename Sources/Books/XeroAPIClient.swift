import CryptoKit
import Foundation

// MARK: - Xero OAuth2 (PKCE) token model + API client
//
// Desktop "Auth Code with PKCE" app (developer.xero.com/myapps): no client
// secret ships in the binary. Tokens persist in the macOS Keychain via
// KeychainService — never in UserDefaults, files, or the memory store.

/// One stored Xero connection (tokens + tenant) — the whole value is the
/// Keychain payload (single item keeps refresh atomic).
struct XeroOAuthTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var tenantID: String
    var tenantName: String

    /// Decodes Xero's token-endpoint JSON. Pure — unit-testable.
    static func fromTokenResponse(
        _ data: Data, tenantID: String = "", tenantName: String = "", now: Date = Date()
    ) throws -> XeroOAuthTokens {
        struct Response: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: TimeInterval
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let refresh = response.refreshToken else {
            throw XeroAPIError.server("token response missing refresh_token")
        }
        return XeroOAuthTokens(
            accessToken: response.accessToken, refreshToken: refresh,
            expiresAt: now.addingTimeInterval(response.expiresIn),
            tenantID: tenantID, tenantName: tenantName)
    }
}

enum XeroAPIError: LocalizedError {
    case notConnected
    case server(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to Xero. Connect first from the Xero page."
        case .server(let message): return message
        case .http(let code, let body):
            return "Xero HTTP \(code): \(body.prefix(300))"
        }
    }
}

/// OAuth2 PKCE client for the Xero API. One shared instance per app run.
actor XeroAPIClient {

    static let shared = XeroAPIClient()

    static let redirectURI = "http://localhost:53682/callback"
    static let scopes = "openid profile email offline_access "
        + "accounting.contacts accounting.invoices accounting.settings"

    private static let keychainAccount = "xero.tokens"
    private static let authorizeEndpoint = "https://login.xero.com/identity/connect/authorize"
    private static let tokenEndpoint = "https://identity.xero.com/connect/token"
    private static let apiBase = "https://api.xero.com/api.xro/2.0"
    private static let connectionsURL = "https://api.xero.com/connections"

    private(set) var tokens: XeroOAuthTokens?
    private let session = URLSession.shared

    private init() {
        tokens = try? KeychainService.read(account: Self.keychainAccount, allowUI: false)
            .flatMap { try? JSONDecoder().decode(XeroOAuthTokens.self, from: Data($0.utf8)) }
    }

    var isConnected: Bool { tokens != nil }
    var tenantName: String? { tokens?.tenantName }

    // MARK: - PKCE (pure — unit-testable)

    /// code_verifier: 64 chars from the RFC 7636 unreserved set.
    /// code_challenge: base64url-no-padding SHA256(verifier).
    static func makePKCE() -> (verifier: String, challenge: String) {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let verifier = String((0..<64).map { _ in alphabet.randomElement()! })
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return (verifier, challenge)
    }

    static func authorizeURL(
        clientID: String, state: String, challenge: String
    ) -> URL {
        var components = URLComponents(string: authorizeEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    // MARK: - Connect / disconnect

    /// Exchanges the authorization code for tokens and resolves the tenant
    /// (first ORGANISATION connection) via /connections.
    func connect(code: String, verifier: String, clientID: String) async throws {
        let body = formEncoded([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ])
        let data = try await rawRequest(Self.tokenEndpoint, method: "POST", body: body)
        var fresh = try XeroOAuthTokens.fromTokenResponse(data)
        let (tenantID, tenantName) = try await fetchTenant(accessToken: fresh.accessToken)
        fresh.tenantID = tenantID
        fresh.tenantName = tenantName
        try persist(fresh)
        tokens = fresh
    }

    func disconnect() throws {
        try KeychainService.delete(account: Self.keychainAccount)
        tokens = nil
    }

    private struct XeroConnection: Decodable {
        let tenantId: String
        let tenantName: String?
        let tenantType: String?
    }

    private func fetchTenant(accessToken: String) async throws -> (String, String) {
        var request = URLRequest(url: URL(string: Self.connectionsURL)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let connections = try JSONDecoder().decode([XeroConnection].self, from: data)
        guard let tenant = connections.first(where: { $0.tenantType == "ORGANISATION" })
                ?? connections.first else {
            throw XeroAPIError.server("no Xero organisation connected")
        }
        return (tenant.tenantId, tenant.tenantName ?? "Xero organisation")
    }

    // MARK: - Authenticated requests

    /// GET with auth + tenant headers, auto-refreshing the access token.
    func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(string: Self.apiBase + path)!
        if !query.isEmpty { components.queryItems = query }
        return try await authorizedRequest(url: components.url!, method: "GET")
    }

    /// POST a JSON body (array or dictionary), returns raw response data.
    func post(_ path: String, json: Any) async throws -> Data {
        try await authorizedRequest(
            url: URL(string: Self.apiBase + path)!, method: "POST",
            jsonBody: JSONSerialization.data(withJSONObject: json))
    }

    private func authorizedRequest(
        url: URL, method: String, jsonBody: Data? = nil
    ) async throws -> Data {
        guard var current = tokens else { throw XeroAPIError.notConnected }
        if current.expiresAt.timeIntervalSinceNow < 60 {
            current = try await refresh(current)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(current.tenantID, forHTTPHeaderField: "xero-tenant-id")
        if let jsonBody {
            request.httpBody = jsonBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return data
    }

    private func refresh(_ stale: XeroOAuthTokens) async throws -> XeroOAuthTokens {
        let body = formEncoded([
            "grant_type": "refresh_token",
            "client_id": UserDefaults.standard.string(forKey: "maestrobooks.xero.clientID") ?? "",
            "refresh_token": stale.refreshToken,
        ])
        let data = try await rawRequest(Self.tokenEndpoint, method: "POST", body: body)
        var fresh = try XeroOAuthTokens.fromTokenResponse(
            data, tenantID: stale.tenantID, tenantName: stale.tenantName)
        fresh.tenantID = stale.tenantID
        fresh.tenantName = stale.tenantName
        try persist(fresh)
        tokens = fresh
        return fresh
    }

    // MARK: - Plumbing

    private func persist(_ value: XeroOAuthTokens) throws {
        let encoded = try JSONEncoder().encode(value)
        try KeychainService.store(
            account: Self.keychainAccount,
            value: String(decoding: encoded, as: UTF8.self),
            synchronizable: true)
    }

    private func formEncoded(_ fields: [String: String]) -> Data {
        fields
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
            }
            .sorted().joined(separator: "&")
            .data(using: .utf8)!
    }

    private func rawRequest(
        _ urlString: String, method: String, body: Data? = nil
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue(
                "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return data
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            // Xero validation errors surface as JSON — quote the useful part.
            let text = String(decoding: data, as: UTF8.self)
            throw XeroAPIError.http(http.statusCode, text)
        }
    }
}
