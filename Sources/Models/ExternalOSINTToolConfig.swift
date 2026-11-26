import Foundation

// MARK: - External OSINT Tool Configuration

/// Paths and settings for the local OSINT tools installed under
/// `~/GitHub/OSINT-Cybersecurity` (or elsewhere).
///
/// The config is stored in UserDefaults as JSON so it survives launches and
/// can be edited from Settings → OSINT Tools.
struct ExternalOSINTToolConfig: Codable, Equatable, Sendable {

    /// Per-tool paths. A `nil` value means "use the default".
    var paths: [ExternalOSINTTool: String] = [:]

    /// Tools the user has explicitly disabled. Disabled tools are not
    /// registered with the agent even when their binaries are present.
    var disabled: Set<ExternalOSINTTool> = []

    /// Default timeout in seconds for quick lookups.
    var defaultTimeoutSeconds: Int = 120

    /// Maximum timeout in seconds for heavier scans.
    var maxTimeoutSeconds: Int = 600

    /// Whether to automatically record interesting findings into the OSINT
    /// profile store after each successful tool run.
    var autoRecordFindings: Bool = true
}

// MARK: - Supported Tools

enum ExternalOSINTTool: String, Codable, CaseIterable, Identifiable, Sendable {

    case blackbird
    case subfinder
    case theHarvester
    case gitfive
    case ghunt
    case socialAnalyzer
    case spiderfoot
    case dnsrecon
    case nexfil
    case marple
    case prot1ntelligence
    case revealin
    case slash
    case torBot
    case crosslinked
    case sublist3r
    case sherlock
    case holehe
    case pymeta

    var id: String { rawValue }

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .blackbird: return "Blackbird"
        case .subfinder: return "subfinder"
        case .theHarvester: return "theHarvester"
        case .gitfive: return "GitFive"
        case .ghunt: return "GHunt"
        case .socialAnalyzer: return "Social Analyzer"
        case .spiderfoot: return "SpiderFoot"
        case .dnsrecon: return "DNSRecon"
        case .nexfil: return "NExfil"
        case .marple: return "Marple"
        case .prot1ntelligence: return "Prot1ntelligence"
        case .revealin: return "revealin"
        case .slash: return "slash"
        case .torBot: return "TorBot"
        case .crosslinked: return "CrossLinked"
        case .sublist3r: return "Sublist3r"
        case .sherlock: return "Sherlock"
        case .holehe: return "Holehe"
        case .pymeta: return "PyMeta"
        }
    }

    /// Short description shown in Settings.
    var description: String {
        switch self {
        case .blackbird:
            return "Username/email lookup across 600+ platforms."
        case .subfinder:
            return "Passive subdomain enumeration."
        case .theHarvester:
            return "Domain reconnaissance: emails, hosts, IPs, URLs."
        case .gitfive:
            return "GitHub profile investigation. Requires login."
        case .ghunt:
            return "Google account OSINT. Requires login."
        case .socialAnalyzer:
            return "Profile analysis across 1000+ sites."
        case .spiderfoot:
            return "Broad OSINT automation platform."
        case .dnsrecon:
            return "DNS enumeration and record extraction."
        case .nexfil:
            return "Fast username discovery across 350+ sites."
        case .marple:
            return "Search-engine profile link collection."
        case .prot1ntelligence:
            return "ProtonMail account intelligence."
        case .revealin:
            return "LinkedIn partial-profile de-anonymisation."
        case .slash:
            return "Automated username/email OSINT."
        case .torBot:
            return "Dark-web / Tor crawler. Requires Tor."
        case .crosslinked:
            return "LinkedIn employee enumeration via search-engine scraping."
        case .sublist3r:
            return "Subdomain enumeration via search engines and DNS."
        case .sherlock:
            return "Username search across 400+ social networks."
        case .holehe:
            return "Check if an email is registered on 100+ sites."
        case .pymeta:
            return "Document metadata extraction from files or domain searches."
        }
    }

    /// Suggested default path relative to the user's OSINT-Cybersecurity repo.
    var defaultPath: String {
        let base = "~/GitHub/OSINT-Cybersecurity"
        switch self {
        case .blackbird:
            return "\(base)/blackbird/blackbird.py"
        case .subfinder:
            return "\(base)/subfinder/subfinder"
        case .theHarvester:
            return "\(base)/theHarvester/theHarvester.py"
        case .gitfive:
            return "gitfive"
        case .ghunt:
            return "ghunt"
        case .socialAnalyzer:
            return "\(base)/social-analyzer/app.py"
        case .spiderfoot:
            return "\(base)/spiderfoot/sf.py"
        case .dnsrecon:
            return "\(base)/dnsrecon/dnsrecon.py"
        case .nexfil:
            return "\(base)/nexfil/.venv/bin/nexfil"
        case .marple:
            return "\(base)/marple/marple.py"
        case .prot1ntelligence:
            return "\(base)/Prot1ntelligence/protintel.py"
        case .revealin:
            return "\(base)/revealin/revealin.py"
        case .slash:
            return "\(base)/slash/slash.py"
        case .torBot:
            return "\(base)/TorBot/main.py"
        case .crosslinked:
            return "\(base)/crosslinked/crosslinked.py"
        case .sublist3r:
            return "\(base)/Sublist3r/sublist3r.py"
        case .sherlock:
            return "\(base)/sherlock/.venv/bin/sherlock"
        case .holehe:
            return "\(base)/holehe/.venv/bin/holehe"
        case .pymeta:
            return "\(base)/pymeta/.venv/bin/pymeta"
        }
    }

    /// Whether the tool is currently supported and should be shown/registered.
    var isSupported: Bool {
        switch self {
        case .revealin: return false
        default: return true
        }
    }

    /// Whether the tool requires a one-time authentication/session setup.
    var requiresAuth: Bool {
        switch self {
        case .gitfive, .ghunt: return true
        default: return false
        }
    }

    /// Whether the tool is best run as a persistent local server.
    var isServer: Bool {
        switch self {
        case .spiderfoot: return true
        default: return false
        }
    }
}

// MARK: - Persistence

extension ExternalOSINTToolConfig {

    private static let defaultsKey = "settings.osint.externalToolConfig"

    static func load() -> ExternalOSINTToolConfig {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let config = try? JSONDecoder().decode(ExternalOSINTToolConfig.self, from: data)
        else {
            return ExternalOSINTToolConfig()
        }
        return config
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - Path resolution

extension ExternalOSINTToolConfig {

    /// Resolved executable/script path for a tool.
    ///
    /// - Returns the user-configured path if set and non-empty, otherwise the
    ///   default path. Does not verify that the file exists.
    func resolvedPath(for tool: ExternalOSINTTool) -> String {
        if let custom = paths[tool], !custom.isEmpty {
            return custom
        }
        return tool.defaultPath
    }

    /// Whether the tool is enabled according to the config.
    func isEnabled(_ tool: ExternalOSINTTool) -> Bool {
        !disabled.contains(tool)
    }
}
