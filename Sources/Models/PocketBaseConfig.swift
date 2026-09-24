import Foundation

/// Configuration for a self-hosted PocketBase CMS backend.
///
/// A single PocketBase instance can serve multiple websites, so this config
/// stores the admin URL and a display label. Per-site details (repo path,
/// deploy script, S3 prefix) live inside PocketBase's `websites` collection.
struct PocketBaseConfig: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var label: String
    /// Base URL of the PocketBase server, e.g. http://127.0.0.1:8090
    var baseURL: String
    /// Admin email for authentication. Password is stored in Keychain.
    var adminEmail: String
    /// Keychain account name that holds the admin password.
    var passwordKeychainAccount: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        label: String,
        baseURL: String,
        adminEmail: String,
        passwordKeychainAccount: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.adminEmail = adminEmail.trimmingCharacters(in: .whitespaces)
        self.passwordKeychainAccount = (passwordKeychainAccount ?? "pocketbase.admin.password.\(id.uuidString)")
            .trimmingCharacters(in: .whitespaces)
        self.createdAt = createdAt
    }

    /// The admin dashboard URL, e.g. http://127.0.0.1:8090/_/
    var adminURL: URL? {
        var components = URLComponents(string: baseURL)
        components?.path = "/_/"
        return components?.url
    }

    /// The REST API base URL, e.g. http://127.0.0.1:8090/api/
    var apiURL: URL? {
        var components = URLComponents(string: baseURL)
        components?.path = "/api/"
        return components?.url
    }
}
