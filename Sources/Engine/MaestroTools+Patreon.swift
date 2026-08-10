import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native Patreon API v2 tools
//
// Campaign/member/post/membership queries against https://www.patreon.com.
// These reuse the session the user created in the Patreon plugin panel —
// tokens live in the Keychain under plugin.patreon.*, so connecting once in
// the panel enables these agent tools too. Creator mode (Creator's Access
// Token) unlocks campaign/members/posts; patron mode (OAuth) unlocks
// memberships. Note: Patreon's API has no post-creation endpoint and does
// not expose other creators' posts to ordinary OAuth clients.

extension MaestroTools {

    static func registerPatreonTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "get_patreon_campaign", spec: patreonToolSpecs[0],
                category: ToolCategory.patreon.rawValue,
                handler: { call in await getPatreonCampaign(call) }),
            ToolDefinition(
                name: "list_patreon_members", spec: patreonToolSpecs[1],
                category: ToolCategory.patreon.rawValue,
                handler: { call in await listPatreonMembers(call) }),
            ToolDefinition(
                name: "list_patreon_posts", spec: patreonToolSpecs[2],
                category: ToolCategory.patreon.rawValue,
                handler: { call in await listPatreonPosts(call) }),
            ToolDefinition(
                name: "get_patreon_memberships", spec: patreonToolSpecs[3],
                category: ToolCategory.patreon.rawValue,
                handler: { call in await getPatreonMemberships(call) }),
        ])
    }

    static var patreonToolSpecs: [ToolSpec] {
        [
            rawSpec("get_patreon_campaign",
                "Get the signed-in creator's Patreon campaign: name, summary, patron count, tiers. Requires creator mode in the Patreon plugin panel.",
                properties: [:], required: []),
            rawSpec("list_patreon_members",
                "List members of the signed-in creator's Patreon campaign with tier, status, and pledge amounts. Requires creator mode in the Patreon plugin panel.",
                properties: [
                    "limit": ["type": "integer", "description": "Max members to return (default 25, max 100)."],
                ], required: []),
            rawSpec("list_patreon_posts",
                "List posts on the signed-in creator's Patreon campaign. Requires creator mode in the Patreon plugin panel.",
                properties: [
                    "limit": ["type": "integer", "description": "Max posts to return (default 10, max 50)."],
                ], required: []),
            rawSpec("get_patreon_memberships",
                "Get the signed-in patron's own Patreon memberships (creators they support). Requires patron mode in the Patreon plugin panel.",
                properties: [:], required: []),
        ]
    }

    // MARK: - Session (shared with the Patreon plugin panel)

    private struct PatreonAuth {
        let accessToken: String
        let refreshToken: String
        let clientId: String
        let clientSecret: String
        let mode: String // "creator" | "patron"
    }

    private enum PatreonAuthError: LocalizedError {
        case notConnected
        case refreshFailed
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Patreon isn't connected. Connect via the Patreon plugin panel first."
            case .refreshFailed:
                return "Patreon token refresh failed — reconnect via the Patreon plugin panel."
            case .requestFailed(let detail):
                return detail
            }
        }
    }

    private static let patreonAPIBase = "https://www.patreon.com/api/oauth2/v2"
    private static let patreonTokenURL = "https://www.patreon.com/api/oauth2/token"
    private static let patreonUserAgent = "SwiftMaestro - Patreon Plugin"
    private static let patreonTimeout: TimeInterval = 20

    private static func loadPatreonAuth() -> PatreonAuth? {
        guard
            let access = try? KeychainService.read(account: "plugin.patreon.accessToken"),
            !access.isEmpty
        else { return nil }
        return PatreonAuth(
            accessToken: access,
            refreshToken: (try? KeychainService.read(account: "plugin.patreon.refreshToken")) ?? "",
            clientId: (try? KeychainService.read(account: "plugin.patreon.clientId")) ?? "",
            clientSecret: (try? KeychainService.read(account: "plugin.patreon.clientSecret")) ?? "",
            mode: (try? KeychainService.read(account: "plugin.patreon.mode")) ?? "creator"
        )
    }

    // MARK: - HTTP

    /// JSON:API GET with a mandatory User-Agent. On 401, refreshes the token
    /// once (if refresh credentials are stored) and retries once.
    private static func patreonGET(
        path: String, params: [String: String], retried: Bool = false
    ) async throws -> [String: Any] {
        guard let auth = loadPatreonAuth() else { throw PatreonAuthError.notConnected }

        var components = URLComponents(string: patreonAPIBase + path)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw PatreonAuthError.requestFailed("Invalid Patreon request URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = patreonTimeout
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        // Patreon drops requests without an identifying User-Agent with 403.
        request.setValue(patreonUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PatreonAuthError.requestFailed("Non-HTTP response from Patreon")
        }

        if http.statusCode == 401, !retried {
            try await refreshPatreonToken(auth)
            return try await patreonGET(path: path, params: params, retried: true)
        }

        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            let errors = object["errors"] as? [[String: Any]]
            let detail = errors?.first?["detail"] as? String
                ?? errors?.first?["title"] as? String
                ?? "Patreon API returned \(http.statusCode)"
            throw PatreonAuthError.requestFailed(detail)
        }
        return object
    }

    private static func refreshPatreonToken(_ auth: PatreonAuth) async throws {
        guard !auth.refreshToken.isEmpty, !auth.clientId.isEmpty, !auth.clientSecret.isEmpty else {
            throw PatreonAuthError.refreshFailed
        }
        guard let url = URL(string: patreonTokenURL) else {
            throw PatreonAuthError.requestFailed("Invalid token URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = patreonTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(patreonUserAgent, forHTTPHeaderField: "User-Agent")
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": auth.refreshToken,
            "client_id": auth.clientId,
            "client_secret": auth.clientSecret,
        ]
        request.httpBody = form
            .map { "\($0.key)=\(patreonFormEscape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty
        else { throw PatreonAuthError.refreshFailed }

        try KeychainService.store(
            account: "plugin.patreon.accessToken", value: access, synchronizable: false)
        if let refresh = object["refresh_token"] as? String, !refresh.isEmpty {
            try KeychainService.store(
                account: "plugin.patreon.refreshToken", value: refresh, synchronizable: false)
        }
    }

    private static func patreonFormEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    // MARK: - JSON:API helpers

    private static func patreonAttributes(_ resource: [String: Any]) -> [String: Any] {
        resource["attributes"] as? [String: Any] ?? [:]
    }

    private static func patreonDataList(_ object: [String: Any]) -> [[String: Any]] {
        if let list = object["data"] as? [[String: Any]] { return list }
        if let single = object["data"] as? [String: Any] { return [single] }
        return []
    }

    /// Resolves the creator-mode campaign id via the identity endpoint.
    private static func patreonCampaignId() async throws -> String {
        let identity = try await patreonGET(path: "/identity", params: [
            "include": "campaign",
            "fields[user]": "full_name",
        ])
        let data = identity["data"] as? [String: Any] ?? [:]
        let relationships = data["relationships"] as? [String: Any] ?? [:]
        let campaign = relationships["campaign"] as? [String: Any] ?? [:]
        let ref = campaign["data"] as? [String: Any]
        guard let id = ref?["id"] as? String ?? (ref?["id"] as? Int).map(String.init) else {
            throw PatreonAuthError.requestFailed(
                "No campaign on this account — creator mode is required for this tool.")
        }
        return String(describing: id)
    }

    private static func patreonMoney(_ cents: Int?, currency: String) -> String {
        guard let cents else { return "Free" }
        let amount = Double(cents) / 100.0
        let formatted = amount.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(amount))
            : String(format: "%.2f", amount)
        return "\(currency) \(formatted)"
    }

    // MARK: - Implementations

    private struct PatreonLimitArgs: Decodable {
        let limit: LenientInt?
    }

    private static func getPatreonCampaign(_ call: ToolCall) async -> String {
        do {
            guard loadPatreonAuth()?.mode == "creator" else {
                return errorJSON("get_patreon_campaign needs creator mode — connect as a creator in the Patreon plugin panel.")
            }
            let object = try await patreonGET(path: "/campaigns", params: [
                "include": "tiers",
                "fields[campaign]": "name,summary,patron_count,creation_name,pay_per_name,url,currency,is_monthly",
                "fields[tier]": "title,amount_cents,patron_count",
            ])
            guard let campaign = patreonDataList(object).first else {
                return errorJSON("No campaigns on this account.")
            }
            let attrs = patreonAttributes(campaign)
            let currency = attrs["currency"] as? String ?? "USD"
            let included = object["included"] as? [[String: Any]] ?? []
            let tiers: [[String: Any]] = included
                .filter { $0["type"] as? String == "tier" }
                .map { tier in
                    let t = patreonAttributes(tier)
                    return [
                        "title": t["title"] as? String ?? "Tier",
                        "amount": patreonMoney(t["amount_cents"] as? Int, currency: currency),
                        "patron_count": t["patron_count"] as? Int ?? 0,
                    ]
                }
            return jsonString([
                "name": attrs["name"] as? String ?? "",
                "summary": attrs["summary"] as? String ?? "",
                "patron_count": attrs["patron_count"] as? Int ?? 0,
                "creation_name": attrs["creation_name"] as? String ?? "",
                "pay_per_name": attrs["pay_per_name"] as? String ?? "",
                "is_monthly": attrs["is_monthly"] as? Bool ?? false,
                "url": attrs["url"] as? String ?? "",
                "currency": currency,
                "tiers": tiers,
            ])
        } catch {
            return errorJSON("Patreon campaign failed: \(error.localizedDescription)")
        }
    }

    private static func listPatreonMembers(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: PatreonLimitArgs.self)
        let limit = max(min(args?.limit?.value ?? 25, 100), 1)
        do {
            guard loadPatreonAuth()?.mode == "creator" else {
                return errorJSON("list_patreon_members needs creator mode — connect as a creator in the Patreon plugin panel.")
            }
            let campaignId = try await patreonCampaignId()
            let object = try await patreonGET(path: "/campaigns/\(campaignId)/members", params: [
                "include": "currently_entitled_tiers",
                "fields[member]": "full_name,patron_status,currently_entitled_amount_cents,campaign_lifetime_support_cents,last_charge_date,last_charge_status",
                "fields[tier]": "title",
                "page[count]": String(limit),
            ])
            var tierTitles: [String: String] = [:]
            var currency = "USD"
            for inc in object["included"] as? [[String: Any]] ?? [] {
                if inc["type"] as? String == "tier",
                   let id = inc["id"] as? String {
                    tierTitles[id] = patreonAttributes(inc)["title"] as? String ?? ""
                }
                if inc["type"] as? String == "campaign" {
                    currency = patreonAttributes(inc)["currency"] as? String ?? currency
                }
            }
            let members: [[String: Any]] = patreonDataList(object).map { member in
                let attrs = patreonAttributes(member)
                let relationships = member["relationships"] as? [String: Any] ?? [:]
                let entitled = relationships["currently_entitled_tiers"] as? [String: Any] ?? [:]
                let tierNames = (entitled["data"] as? [[String: Any]] ?? [])
                    .compactMap { $0["id"] as? String }
                    .compactMap { tierTitles[$0] }
                return [
                    // Patreon's identity masking: hidden members arrive null.
                    "name": attrs["full_name"] as? String ?? "Hidden member",
                    "status": attrs["patron_status"] as? String ?? "unknown",
                    "tiers": tierNames,
                    "amount": patreonMoney(
                        attrs["currently_entitled_amount_cents"] as? Int, currency: currency),
                    "lifetime_support": patreonMoney(
                        attrs["campaign_lifetime_support_cents"] as? Int, currency: currency),
                    "last_charge_status": attrs["last_charge_status"] as? String ?? "",
                    "last_charge_date": attrs["last_charge_date"] as? String ?? "",
                ]
            }
            return jsonString(["count": members.count, "members": members])
        } catch {
            return errorJSON("Patreon members failed: \(error.localizedDescription)")
        }
    }

    private static func listPatreonPosts(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: PatreonLimitArgs.self)
        let limit = max(min(args?.limit?.value ?? 10, 50), 1)
        do {
            guard loadPatreonAuth()?.mode == "creator" else {
                return errorJSON("list_patreon_posts needs creator mode — connect as a creator in the Patreon plugin panel.")
            }
            let campaignId = try await patreonCampaignId()
            let object = try await patreonGET(path: "/campaigns/\(campaignId)/posts", params: [
                "fields[post]": "title,published_at,url,is_paid",
                "page[count]": String(limit),
            ])
            let posts: [[String: Any]] = patreonDataList(object).map { post in
                let attrs = patreonAttributes(post)
                return [
                    "title": attrs["title"] as? String ?? "Untitled",
                    "published_at": attrs["published_at"] as? String ?? "",
                    "is_paid": attrs["is_paid"] as? Bool ?? false,
                    "url": attrs["url"] as? String ?? "",
                ]
            }
            return jsonString(["count": posts.count, "posts": posts])
        } catch {
            return errorJSON("Patreon posts failed: \(error.localizedDescription)")
        }
    }

    private static func getPatreonMemberships(_ call: ToolCall) async -> String {
        do {
            guard loadPatreonAuth()?.mode == "patron" else {
                return errorJSON("get_patreon_memberships needs patron mode — log in with Patreon in the Patreon plugin panel.")
            }
            let object = try await patreonGET(path: "/identity", params: [
                "include": "memberships.currently_entitled_tiers,memberships.campaign",
                "fields[user]": "full_name",
                "fields[member]": "patron_status,currently_entitled_amount_cents,last_charge_date",
                "fields[campaign]": "name,url",
                "fields[tier]": "title",
            ])
            var campaigns: [String: String] = [:]
            var tiers: [String: String] = [:]
            let included = object["included"] as? [[String: Any]] ?? []
            for inc in included {
                guard let id = inc["id"] as? String else { continue }
                if inc["type"] as? String == "campaign" {
                    campaigns[id] = patreonAttributes(inc)["name"] as? String ?? "Campaign"
                } else if inc["type"] as? String == "tier" {
                    tiers[id] = patreonAttributes(inc)["title"] as? String ?? ""
                }
            }
            let memberships: [[String: Any]] = included
                .filter { $0["type"] as? String == "member" }
                .map { member in
                    let attrs = patreonAttributes(member)
                    let relationships = member["relationships"] as? [String: Any] ?? [:]
                    let campaignRef = (relationships["campaign"] as? [String: Any])?["data"] as? [String: Any]
                    let campaignName = (campaignRef?["id"] as? String).flatMap { campaigns[$0] } ?? "Campaign"
                    let entitled = relationships["currently_entitled_tiers"] as? [String: Any] ?? [:]
                    let tierNames = (entitled["data"] as? [[String: Any]] ?? [])
                        .compactMap { $0["id"] as? String }
                        .compactMap { tiers[$0] }
                    return [
                        "campaign": campaignName,
                        "status": attrs["patron_status"] as? String ?? "unknown",
                        "tiers": tierNames,
                        "amount": patreonMoney(
                            attrs["currently_entitled_amount_cents"] as? Int, currency: "USD"),
                        "last_charge_date": attrs["last_charge_date"] as? String ?? "",
                    ]
                }
            return jsonString(["count": memberships.count, "memberships": memberships])
        } catch {
            return errorJSON("Patreon memberships failed: \(error.localizedDescription)")
        }
    }
}
