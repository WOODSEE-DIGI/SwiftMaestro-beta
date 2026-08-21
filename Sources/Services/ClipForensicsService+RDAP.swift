import Foundation

// MARK: - RDAP domain lookup
//
// RDAP is the HTTPS/JSON successor to port-43 WHOIS. IANA publishes a
// bootstrap file mapping each TLD to its RDAP server; we query that once,
// then the TLD's server for the domain record. Both are free, keyless, and
// parseable — registrar, registration/expiry dates, nameservers, status.
// Registrant identity is usually privacy-redacted post-GDPR (expected).

extension ClipForensicsService {

    /// Look up the domain record for a page URL. Returns nil on any failure.
    func rdap(for urlString: String) async -> ClipCaptureMetadata.RDAPSummary? {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return nil }

        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        // Registrable domain: last 2 labels normally; last 3 for multi-part
        // public suffixes (com.au, co.uk, etc.). Not exhaustive — documented.
        let tld = labels.last ?? ""
        let multiPartSuffixes: Set<String> = ["au", "uk", "nz", "jp", "br", "za", "in", "mx", "kr"]
        let domain: String
        if multiPartSuffixes.contains(tld), labels.count >= 3 {
            domain = labels.suffix(3).joined(separator: ".")
        } else {
            domain = labels.suffix(2).joined(separator: ".")
        }

        // 1. IANA bootstrap: TLD -> RDAP base URL
        guard let bootstrapURL = URL(string: "https://data.iana.org/rdap/dns.json"),
              let (bootData, _) = try? await session.data(from: bootstrapURL),
              let boot = try? JSONSerialization.jsonObject(with: bootData) as? [String: Any],
              let services = boot["services"] as? [[[Any]]] else { return nil }

        var baseURL: String?
        for service in services {
            guard service.count == 2,
                  let tlds = service[0] as? [String],
                  let urls = service[1] as? [String] else { continue }
            if tlds.contains(tld), let first = urls.first {
                baseURL = first
                break
            }
        }
        guard let base = baseURL else { return nil }

        // 2. Domain query
        guard let queryURL = URL(string: "\(base)domain/\(domain.uppercased())"),
              let (data, _) = try? await session.data(from: queryURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // events: registration / expiration / last changed
        var created: String?, expires: String?, updated: String?
        for event in json["events"] as? [[String: Any]] ?? [] {
            guard let action = event["eventAction"] as? String,
                  let date = event["eventDate"] as? String else { continue }
            switch action {
            case "registration": created = date
            case "expiration": expires = date
            case "last changed": updated = date
            default: break
            }
        }

        // entities: registrar + registrant (via vCard fn)
        var registrar: String?, registrant: String?
        for entity in json["entities"] as? [[String: Any]] ?? [] {
            let roles = entity["roles"] as? [String] ?? []
            let name = Self.vcardFN(entity) ?? entity["handle"] as? String
            if roles.contains("registrar") { registrar = registrar ?? name }
            if roles.contains("registrant") { registrant = registrant ?? name }
        }

        let nameservers = (json["nameservers"] as? [[String: Any]] ?? [])
            .compactMap { $0["ldhName"] as? String }
        let status = json["status"] as? [String] ?? []

        let sourceServer = URL(string: base)?.host

        return ClipCaptureMetadata.RDAPSummary(
            domain: domain, registrar: registrar,
            created: created, expires: expires, updated: updated,
            status: status, nameservers: nameservers,
            registrant: registrant, sourceServer: sourceServer)
    }

    /// Extract the "fn" (formatted name) from an RDAP entity's vcardArray.
    private static func vcardFN(_ entity: [String: Any]) -> String? {
        guard let vcard = entity["vcardArray"] as? [Any], vcard.count > 1,
              let properties = vcard[1] as? [[Any]] else { return nil }
        for prop in properties where prop.count >= 4 {
            if (prop[0] as? String) == "fn" {
                return prop[3] as? String
            }
        }
        return nil
    }
}
