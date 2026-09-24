import Foundation

/// Lightweight async PocketBase REST client for the SwiftMaestro Publish workflow.
///
/// Authenticates as a superuser and provides typed access to the collections
/// used by the woodsee.com CMS: websites, myStory_episodes, blog_posts,
/// media_assets.
actor PocketBaseClient {

    enum Error: Swift.Error {
        case invalidURL
        case authenticationFailed(String)
        case requestFailed(Int, String)
        case decodeFailed(Swift.Error)
    }

    private let config: PocketBaseConfig
    private let urlSession: URLSession
    private var token: String?

    init(config: PocketBaseConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    // MARK: - Authentication

    /// Authenticates using the admin password stored in Keychain.
    func authenticate() async throws {
        guard let apiURL = config.apiURL else {
            throw Error.invalidURL
        }

        guard let password = try? KeychainService.read(
            account: config.passwordKeychainAccount,
            allowUI: false
        ), !password.isEmpty else {
            throw Error.authenticationFailed("PocketBase admin password not found in Keychain.")
        }

        let url = apiURL.appendingPathComponent("collections/_superusers/auth-with-password")
        let body = AuthRequest(identity: config.adminEmail, password: password)
        let request = try makeRequest(url: url, body: body)

        let (data, response) = try await urlSession.data(for: request)
        try checkResponse(response, data: data)

        let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
        guard let token = auth.token else {
            throw Error.authenticationFailed("No token in response.")
        }
        self.token = token
    }

    // MARK: - Websites

    func listWebsites() async throws -> [PBWebsite] {
        try await ensureAuthenticated()
        let url = try collectionURL("websites")
        let (data, _) = try await authenticatedRequest(url: url)
        let page = try JSONDecoder().decode(ListResponse<PBWebsite>.self, from: data)
        return page.items
    }

    // MARK: - MyStory episodes

    func listEpisodes(forWebsiteID websiteID: String? = nil) async throws -> [PBMyStoryEpisode] {
        try await ensureAuthenticated()
        var url = try collectionURL("myStory_episodes")
        if let websiteID {
            url.append(queryItems: [URLQueryItem(name: "filter", value: "website = '\(websiteID)'")])
        }
        let (data, _) = try await authenticatedRequest(url: url)
        let page = try JSONDecoder().decode(ListResponse<PBMyStoryEpisode>.self, from: data)
        return page.items
    }

    func createEpisode(_ episode: PBMyStoryEpisode) async throws -> PBMyStoryEpisode {
        try await ensureAuthenticated()
        let url = try collectionURL("myStory_episodes")
        let body = try JSONEncoder().encode(episode)
        let request = try makeRequest(url: url, body: body, token: token)
        let (data, _) = try await urlSession.data(for: request)
        return try JSONDecoder().decode(PBMyStoryEpisode.self, from: data)
    }

    func updateEpisode(_ episode: PBMyStoryEpisode) async throws -> PBMyStoryEpisode {
        guard let id = episode.id else {
            throw Error.requestFailed(0, "Episode has no id")
        }
        try await ensureAuthenticated()
        let url = try collectionURL("myStory_episodes").appendingPathComponent(id)
        let body = try JSONEncoder().encode(episode)
        let request = try makeRequest(url: url, method: "PATCH", body: body, token: token)
        let (data, _) = try await urlSession.data(for: request)
        return try JSONDecoder().decode(PBMyStoryEpisode.self, from: data)
    }

    // MARK: - Blog posts

    func listBlogPosts(forWebsiteID websiteID: String? = nil) async throws -> [PBBlogPost] {
        try await ensureAuthenticated()
        var url = try collectionURL("blog_posts")
        if let websiteID {
            url.append(queryItems: [URLQueryItem(name: "filter", value: "website = '\(websiteID)'")])
        }
        let (data, _) = try await authenticatedRequest(url: url)
        let page = try JSONDecoder().decode(ListResponse<PBBlogPost>.self, from: data)
        return page.items
    }

    // MARK: - Helpers

    private func ensureAuthenticated() async throws {
        if token == nil {
            try await authenticate()
        }
    }

    private func collectionURL(_ name: String) throws -> URL {
        guard let apiURL = config.apiURL else {
            throw Error.invalidURL
        }
        return apiURL
            .appendingPathComponent("collections")
            .appendingPathComponent(name)
            .appendingPathComponent("records")
    }

    private func authenticatedRequest(url: URL) async throws -> (Data, URLResponse) {
        let request = try makeRequest(url: url, token: token)
        return try await urlSession.data(for: request)
    }

    private func makeRequest(url: URL, method: String = "GET", body: Encodable? = nil, token: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func makeRequest(url: URL, method: String = "GET", body: Data? = nil, token: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Error.requestFailed(http.statusCode, body)
        }
    }
}

// MARK: - Request/response models

private struct AuthRequest: Encodable {
    let identity: String
    let password: String
}

private struct AuthResponse: Decodable {
    let token: String?
}

private struct ListResponse<T: Decodable>: Decodable {
    let page: Int
    let perPage: Int
    let totalPages: Int
    let totalItems: Int
    let items: [T]
}

// MARK: - PocketBase record models

struct PBWebsite: Identifiable, Codable, Sendable, Equatable {
    var id: String?
    var name: String
    var slug: String
    var domain: String?
    var localRepoPath: String?
    var deployScriptPath: String?
    var s3Prefix: String?
    var contentSubfolder: String?
    var status: String
}

struct PBMyStoryEpisode: Identifiable, Codable, Sendable, Equatable {
    var id: String?
    var title: String
    var slug: String
    var description: String?
    var body: String?
    var status: String
    var publishDate: String?
    var videoUrl: String?
    var posterUrl: String?
    var transcriptUrl: String?
    var vttUrl: String?
    var srtUrl: String?
    var tags: [String]?
    var sourceAssetPath: String?
    var durationSeconds: Double?
    var website: String?
}

struct PBBlogPost: Identifiable, Codable, Sendable, Equatable {
    var id: String?
    var title: String
    var slug: String
    var description: String?
    var body: String?
    var status: String
    var publishDate: String?
    var heroImageUrl: String?
    var tags: [String]?
    var sourceDraftPath: String?
    var website: String?
}
