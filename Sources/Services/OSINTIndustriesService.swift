import Foundation

// MARK: - OSINT Industries Service

/// Thin client for the OSINT Industries API. Used for opt-in background checks
/// on CRM contacts. The API key is stored in the macOS Keychain and referenced
/// as `secret://osint-industries-api`.
///
/// Documentation: https://www.osint.industries/offerings/api-access
@MainActor
final class OSINTIndustriesService {
    static let shared = OSINTIndustriesService()
    static let secretName = "osint-industries-api"

    private let baseURL = URL(string: "https://api.osint.industries/v1")!
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    /// Whether a non-empty API key is configured.
    var isConfigured: Bool {
        guard let token = SecretsStore.resolve(reference: "secret://\(Self.secretName)", currentProject: nil) else { return false }
        return !token.isEmpty
    }

    /// Performs a background check using whatever identifiers are available.
    /// OSINT Industries searches one identifier at a time; this method picks the
    /// best identifier (email → phone → username → name) and returns the result.
    /// - Parameters:
    ///   - email: Email address.
    ///   - phone: Phone number (E.164 preferred).
    ///   - username: Social-media username/handle.
    ///   - name: Person or business name.
    /// - Returns: A structured summary of findings (no raw PII is cached).
    func backgroundCheck(
        email: String? = nil,
        phone: String? = nil,
        username: String? = nil,
        name: String? = nil
    ) async -> OSINTBackgroundCheckResult {
        guard isConfigured else {
            return OSINTBackgroundCheckResult(
                status: .notConfigured,
                message: "OSINT Industries API key not configured. Add it in Settings → Secrets as \(Self.secretName).",
                profiles: [],
                breachCount: nil,
                checkedAt: Date())
        }

        let search: (type: String, query: String)?
        if let email, !email.isEmpty {
            search = ("email", email)
        } else if let phone, !phone.isEmpty {
            search = ("phone", phone)
        } else if let username, !username.isEmpty {
            search = ("username", username)
        } else if let name, !name.isEmpty {
            search = ("name", name)
        } else {
            search = nil
        }

        guard let search else {
            return OSINTBackgroundCheckResult(
                status: .skipped,
                message: "No searchable identifier provided.",
                profiles: [],
                breachCount: nil,
                checkedAt: Date())
        }

        let url = baseURL.appendingPathComponent("v2/request")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(SecretsStore.resolve(reference: "secret://\(Self.secretName)", currentProject: nil) ?? "", forHTTPHeaderField: "api-key")

        let body = OSINTSearchRequest(type: search.type, query: search.query, timeout: 60, exact_match: true, premium: false, premium_modules_only: false)
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            return OSINTBackgroundCheckResult(status: .error, message: "Could not encode request.", profiles: [], breachCount: nil, checkedAt: Date())
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return OSINTBackgroundCheckResult(status: .error, message: "Non-HTTP response", profiles: [], breachCount: nil, checkedAt: Date())
            }

            switch http.statusCode {
            case 200:
                let modules = try JSONDecoder().decode([OSINTModuleResult].self, from: data)
                let profiles = modules.compactMap { $0.toSummary() }
                return OSINTBackgroundCheckResult(
                    status: profiles.isEmpty ? .notFound : .found,
                    message: profiles.isEmpty ? "No public profiles found." : "Found \(profiles.count) result(s) for \(search.type).",
                    profiles: profiles,
                    breachCount: nil,
                    checkedAt: Date())
            case 400:
                let body = String(data: data, encoding: .utf8) ?? ""
                return OSINTBackgroundCheckResult(status: .error, message: "Bad request: \(body)", profiles: [], breachCount: nil, checkedAt: Date())
            case 401, 403:
                return OSINTBackgroundCheckResult(status: .error, message: "API key invalid or expired.", profiles: [], breachCount: nil, checkedAt: Date())
            case 402:
                return OSINTBackgroundCheckResult(status: .error, message: "Insufficient OSINT Industries credits.", profiles: [], breachCount: nil, checkedAt: Date())
            case 429:
                return OSINTBackgroundCheckResult(status: .rateLimited, message: "Rate limited. Retry later.", profiles: [], breachCount: nil, checkedAt: Date())
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                return OSINTBackgroundCheckResult(status: .error, message: "HTTP \(http.statusCode): \(body)", profiles: [], breachCount: nil, checkedAt: Date())
            }
        } catch is DecodingError {
            return OSINTBackgroundCheckResult(status: .error, message: "Could not decode OSINT Industries response.", profiles: [], breachCount: nil, checkedAt: Date())
        } catch {
            return OSINTBackgroundCheckResult(status: .error, message: "Network error: \(error.localizedDescription)", profiles: [], breachCount: nil, checkedAt: Date())
        }
    }
}

private struct OSINTSearchRequest: Encodable {
    let type: String
    let query: String
    let timeout: Int
    let exact_match: Bool
    let premium: Bool
    let premium_modules_only: Bool
}

// MARK: - Result model

struct OSINTBackgroundCheckResult: Sendable {
    enum Status: String, Sendable {
        case notConfigured
        case skipped
        case found
        case notFound
        case rateLimited
        case error
    }

    let status: Status
    let message: String
    let profiles: [OSINTProfileSummary]
    let breachCount: Int?
    let checkedAt: Date
}

struct OSINTProfileSummary: Sendable, Identifiable {
    let id: String
    let platform: String
    let url: String?
    let description: String?
}

// MARK: - API response decoding

private struct OSINTModuleResult: Decodable {
    let module: String?
    let data: [String: JSONValue]?
    let query: String?
    let status: String?
    let from: String?
    let reliable_source: Bool?

    func toSummary() -> OSINTProfileSummary? {
        guard let module, !module.isEmpty else { return nil }
        // Extract a human-readable description from the module payload.
        var description: String?
        if let data {
            let snippetKeys = ["username", "name", "title", "location", "address", "company", "bio"]
            for key in snippetKeys {
                if let value = data[key], case let .string(str) = value, !str.isEmpty {
                    description = str
                    break
                }
            }
        }
        return OSINTProfileSummary(
            id: "\(module)-\(query ?? UUID().uuidString)",
            platform: module,
            url: nil,
            description: description ?? query)
    }
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .null
        }
    }
}
