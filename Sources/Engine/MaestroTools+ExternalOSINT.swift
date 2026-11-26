import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - External OSINT Tools

/// Native tool wrappers around the local OSINT tools installed in
/// `~/GitHub/OSINT-Cybersecurity`.
///
/// These tools delegate the actual intelligence gathering to the original
/// Python/Go implementations and feed discovered entities back into the
/// per-agent OSINT profile store.
extension MaestroTools {

    static func registerExternalOSINTTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "blackbird_lookup",
                spec: externalOSINTToolSpecs[0],
                category: ToolCategory.osint.rawValue,
                handler: { call in await blackbirdLookup(call) }),
            ToolDefinition(
                name: "subfinder_lookup",
                spec: externalOSINTToolSpecs[1],
                category: ToolCategory.osint.rawValue,
                handler: { call in await subfinderLookup(call) }),
            ToolDefinition(
                name: "theharvester_lookup",
                spec: externalOSINTToolSpecs[2],
                category: ToolCategory.osint.rawValue,
                handler: { call in await theHarvesterLookup(call) }),
            ToolDefinition(
                name: "gitfive_lookup",
                spec: externalOSINTToolSpecs[3],
                category: ToolCategory.osint.rawValue,
                handler: { call in await gitfiveLookup(call) }),
            ToolDefinition(
                name: "ghunt_email",
                spec: externalOSINTToolSpecs[4],
                category: ToolCategory.osint.rawValue,
                handler: { call in await ghuntEmail(call) }),
            ToolDefinition(
                name: "social_analyzer_lookup",
                spec: externalOSINTToolSpecs[5],
                category: ToolCategory.osint.rawValue,
                handler: { call in await socialAnalyzerLookup(call) }),
            ToolDefinition(
                name: "dnsrecon_lookup",
                spec: externalOSINTToolSpecs[6],
                category: ToolCategory.osint.rawValue,
                handler: { call in await dnsreconLookup(call) }),
            ToolDefinition(
                name: "spiderfoot_lookup",
                spec: externalOSINTToolSpecs[7],
                category: ToolCategory.osint.rawValue,
                handler: { call in await spiderfootLookup(call) }),
            ToolDefinition(
                name: "nexfil_lookup",
                spec: externalOSINTToolSpecs[8],
                category: ToolCategory.osint.rawValue,
                handler: { call in await nexfilLookup(call) }),
            ToolDefinition(
                name: "marple_lookup",
                spec: externalOSINTToolSpecs[9],
                category: ToolCategory.osint.rawValue,
                handler: { call in await marpleLookup(call) }),
            ToolDefinition(
                name: "prot1ntelligence_lookup",
                spec: externalOSINTToolSpecs[10],
                category: ToolCategory.osint.rawValue,
                handler: { call in await prot1ntelligenceLookup(call) }),
            ToolDefinition(
                name: "slash_lookup",
                spec: externalOSINTToolSpecs[11],
                category: ToolCategory.osint.rawValue,
                handler: { call in await slashLookup(call) }),
            ToolDefinition(
                name: "torbot_lookup",
                spec: externalOSINTToolSpecs[12],
                category: ToolCategory.osint.rawValue,
                handler: { call in await torbotLookup(call) }),
            ToolDefinition(
                name: "crosslinked_lookup",
                spec: externalOSINTToolSpecs[13],
                category: ToolCategory.osint.rawValue,
                handler: { call in await crosslinkedLookup(call) }),
            ToolDefinition(
                name: "sublist3r_lookup",
                spec: externalOSINTToolSpecs[14],
                category: ToolCategory.osint.rawValue,
                handler: { call in await sublist3rLookup(call) }),
            ToolDefinition(
                name: "sherlock_lookup",
                spec: externalOSINTToolSpecs[15],
                category: ToolCategory.osint.rawValue,
                handler: { call in await sherlockLookup(call) }),
            ToolDefinition(
                name: "holehe_lookup",
                spec: externalOSINTToolSpecs[16],
                category: ToolCategory.osint.rawValue,
                handler: { call in await holeheLookup(call) }),
            ToolDefinition(
                name: "pymeta_lookup",
                spec: externalOSINTToolSpecs[17],
                category: ToolCategory.osint.rawValue,
                handler: { call in await pymetaLookup(call) }),
        ])
    }

    // MARK: - Tool specs

    private static var externalOSINTToolSpecs: [ToolSpec] {
        [
            rawSpec("blackbird_lookup",
                "Search a username or email address across 600+ platforms using Blackbird "
                + "(which consumes the WhatsMyName dataset). Returns discovered accounts with "
                + "platform name, category, and profile URL. Findings are auto-recorded to the "
                + "OSINT profile unless auto-record is disabled.",
                properties: [
                    "username": ["type": "string", "description": "Username to search. Provide either username or email, not both."],
                    "email": ["type": "string", "description": "Email address to search. Provide either username or email, not both."],
                    "timeout": ["type": "integer", "description": "Maximum runtime in seconds (default 120)."],
                ], required: []),
            rawSpec("subfinder_lookup",
                "Passive subdomain enumeration for a domain using subfinder. Returns "
                + "discovered subdomains and their data sources. Useful for mapping an "
                + "organisation's external footprint.",
                properties: [
                    "domain": ["type": "string", "description": "Domain to enumerate, e.g. 'example.com'."],
                    "timeout": ["type": "integer", "description": "Maximum runtime in seconds (default 120)."],
                ], required: ["domain"]),
            rawSpec("theharvester_lookup",
                "Domain reconnaissance using theHarvester. Discovers emails, hosts, IPs, "
                + "interesting URLs, and people associated with a domain or company name. "
                + "Outputs a structured JSON report.",
                properties: [
                    "domain": ["type": "string", "description": "Company name or domain to search, e.g. 'example.com'."],
                    "sources": ["type": "string", "description": "Comma-separated source modules, or 'all' (default)."],
                    "timeout": ["type": "integer", "description": "Maximum runtime in seconds (default 180)."],
                ], required: ["domain"]),
            rawSpec("gitfive_lookup",
                "Investigate a GitHub profile with GitFive. Requires a one-time 'gitfive login'. "
                + "Returns profile metadata, emails, names/usernames history, SSH keys, and "
                + "potential secondary accounts. Use for GitHub-centric person or organisation "
                + "investigations.",
                properties: [
                    "username": ["type": "string", "description": "GitHub username to investigate. Provide either username or email, not both."],
                    "email": ["type": "string", "description": "Email address to map to a GitHub account. Provide either username or email, not both."],
                    "timeout": ["type": "integer", "description": "Maximum runtime in seconds (default 180)."],
                ], required: []),
            rawSpec("ghunt_email",
                "Investigate a Google account from its email address with GHunt. Requires a "
                + "one-time 'ghunt login'. Returns Google profile containers (name, profile "
                + "photo, reviews, maps contributions, etc.) when available.",
                properties: [
                    "email": ["type": "string", "description": "Gmail/Google email address to investigate."],
                    "timeout": ["type": "integer", "description": "Maximum runtime in seconds (default 120)."],
                ], required: ["email"]),
            rawSpec("social_analyzer_lookup",
                "Analyze a username across 1000+ social media/websites using Social Analyzer. "
                + "Returns detected profiles with confidence rating, link, title, and metadata. "
                + "SLOW: often times out on broad scans and emits decoding warnings. Prefer "
                + "blackbird_lookup for fast checks; only use this if Blackbird/Sherlock were "
                + "insufficient.",
                properties: [
                    "username": ["type": "string", "description": "Username to analyze."],
                    "mode": ["type": "string", "description": "Analysis mode: fast (default), slow, or special."],
                    "timeout": ["type": "integer", "description": "Maximum runtime in seconds (default 45)."],
                ], required: ["username"]),
            rawSpec("dnsrecon_lookup",
                "DNS enumeration for a domain using DNSRecon. Discovers A/AAAA/MX/NS/TXT/SRV "
                + "records, zone transfer info, and subdomain hints. Outputs a structured CSV report.",
                properties: [
                    "domain": ["type": "string", "description": "Domain to enumerate, e.g. 'example.com'."],
                    "type": ["type": "string", "description": "Enumeration type: std (default), brt, srv, axfr, goo, etc."],
                    "timeout": ["type": "integer", "description": "Maximum runtime in seconds (default 120)."],
                ], required: ["domain"]),
            rawSpec("spiderfoot_lookup",
                "Run a SpiderFoot OSINT scan against a domain, IP, email, or username. "
                + "Works best with domains and IPs; person names are slow and often yield "
                + "little. Uses command-line mode (no persistent server). Returns discovered "
                + "entities as a JSON array and records interesting findings to the profile.",
                properties: [
                    "target": ["type": "string", "description": "Scan target: domain, IP, email, or username. Avoid plain person names."],
                    "use_case": ["type": "string", "description": "Module set: passive (default), investigate, footprint, or all."],
                    "timeout": ["type": "integer", "description": "Maximum runtime in seconds (default 180)."],
                ], required: ["target"]),
            rawSpec("nexfil_lookup",
                "Username discovery across 350+ sites using NExfil. Returns discovered "
                + "profile URLs. Can be slow across all sites; prefer blackbird_lookup for a "
                + "fast first pass, then use NExfil for deeper coverage if needed.",
                properties: [
                    "username": ["type": "string", "description": "Username to search."],
                    "timeout": ["type": "integer", "description": "Per-site request timeout in seconds (default 10)."],
                ], required: ["username"]),
            rawSpec("marple_lookup",
                "Collect profile links for a username/name through multiple search engines "
                + "using Marple. Returns a list of likely profile URLs and optionally raw "
                + "search results. SLOW across many engines; start with a small results_count "
                + "and increase only if needed.",
                properties: [
                    "name": ["type": "string", "description": "Username or first/last name to search."],
                    "engines": ["type": "string", "description": "Optional comma-separated search engines to use."],
                    "results_count": ["type": "integer", "description": "Results per engine (default 100)."],
                    "threshold": ["type": "integer", "description": "Junk-score threshold (default 300)."],
                    "timeout": ["type": "integer", "description": "Maximum runtime in seconds (default 90)."],
                ], required: ["name"]),
            rawSpec("prot1ntelligence_lookup",
                "Check whether an email address is a ProtonMail account using "
                + "Prot1ntelligence. Returns ProtonMail type, PGP key creation date, "
                + "encryption standard, and any catch-all real email discovered.",
                properties: [
                    "email": ["type": "string", "description": "Email address to investigate."],
                    "timeout": ["type": "integer", "description": "Maximum runtime in seconds (default 60)."],
                ], required: ["email"]),
            rawSpec("slash_lookup",
                "Automated username/email OSINT using slash. Triggers social-media, forum, "
                + "paste, GitHub, and leak checks. Returns discovered URLs and identifiers.",
                properties: [
                    "query": ["type": "string", "description": "Username or email address to investigate."],
                    "timeout": ["type": "integer", "description": "Maximum runtime in seconds (default 180)."],
                ], required: ["query"]),
            rawSpec("torbot_lookup",
                "Crawl a dark-web or clearnet URL with TorBot. By default uses clearnet mode "
                + "(--disable-socks5); enable use_tor for .onion sites when Tor is running. "
                + "Returns discovered URLs, emails, and phone numbers.",
                properties: [
                    "url": ["type": "string", "description": "URL to crawl."],
                    "depth": ["type": "integer", "description": "Crawl depth (default 1)."],
                    "use_tor": ["type": "boolean", "description": "Use SOCKS5 Tor proxy on 127.0.0.1:9050 (default false)."],
                    "timeout": ["type": "integer", "description": "Maximum runtime in seconds (default 120)."],
                ], required: ["url"]),
            rawSpec("crosslinked_lookup",
                "LinkedIn employee enumeration using CrossLinked. Scrapes Google/Bing for "
                + "LinkedIn profiles associated with a company name and converts them into "
                + "formatted usernames/emails. No LinkedIn login required.",
                properties: [
                    "company_name": ["type": "string", "description": "Target company name as it appears on LinkedIn, e.g. 'Acme Corp'."],
                    "naming_format": ["type": "string", "description": "Output format, e.g. '{first}.{last}@company.com' or 'domain\\{f}{last}'. Defaults to '{first}.{last}'."],
                    "search_engines": ["type": "string", "description": "Comma-separated engines: google, bing (default 'google,bing')."],
                    "timeout": ["type": "integer", "description": "Max timeout per search in seconds (default 30)."],
                    "jitter": ["type": "integer", "description": "Jitter between requests in seconds (default 1)."],
                ], required: ["company_name"]),
            rawSpec("sublist3r_lookup",
                "Passive subdomain enumeration using Sublist3r. Searches search engines and "
                + "DNS records for subdomains of a target domain. Useful for mapping external "
                + "footprint alongside subfinder.",
                properties: [
                    "domain": ["type": "string", "description": "Domain to enumerate, e.g. 'example.com'."],
                    "engines": ["type": "string", "description": "Optional comma-separated search engines (default uses all)."],
                    "timeout": ["type": "integer", "description": "Maximum runtime in seconds (default 120)."],
                ], required: ["domain"]),
            rawSpec("sherlock_lookup",
                "Hunt down social media accounts by username across 400+ sites using Sherlock. "
                + "Returns found account URLs and platform names. SLOW across all sites and "
                + "often times out; use the 'site' parameter for a fast targeted check. Prefer "
                + "blackbird_lookup for a fast first pass.",
                properties: [
                    "username": ["type": "string", "description": "Username to search."],
                    "site": ["type": "string", "description": "Optional specific site to check (much faster than checking all 400+)."],
                    "timeout": ["type": "integer", "description": "Per-site request timeout in seconds (default 10)."],
                ], required: ["username"]),
            rawSpec("holehe_lookup",
                "Check whether an email address is registered on 100+ websites using Holehe. "
                + "Uses password-recovery flows; returns sites where the email is known. "
                + "No login required, but can be rate-limited.",
                properties: [
                    "email": ["type": "string", "description": "Email address to check."],
                    "timeout": ["type": "integer", "description": "Max timeout per check in seconds (default 10)."],
                ], required: ["email"]),
            rawSpec("pymeta_lookup",
                "Extract metadata from documents using PyMeta. Can either search a domain for "
                + "file types (pdf, docx, xlsx, etc.) and extract metadata, or process a local "
                + "directory of files already on disk.",
                properties: [
                    "target": ["type": "string", "description": "Target domain (e.g. 'example.com') or local directory path."],
                    "mode": ["type": "string", "description": "Mode: 'search' (default) or 'local'."],
                    "file_types": ["type": "string", "description": "Comma-separated file types for search mode (default pdf,xls,xlsx,csv,doc,docx,ppt,pptx)."],
                    "max_results": ["type": "integer", "description": "Max files to download per type in search mode (default 10)."],
                    "timeout": ["type": "integer", "description": "Search timeout in seconds (default 12)."],
                ], required: ["target"]),
        ]
    }

    // MARK: - Args

    private struct BlackbirdLookupArgs: Decodable {
        let username: String?
        let email: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct SubfinderLookupArgs: Decodable {
        let domain: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct TheHarvesterLookupArgs: Decodable {
        let domain: String?
        let sources: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct GitfiveLookupArgs: Decodable {
        let username: String?
        let email: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct GhuntEmailArgs: Decodable {
        let email: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct SocialAnalyzerLookupArgs: Decodable {
        let username: String?
        let mode: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct DNSReconLookupArgs: Decodable {
        let domain: String?
        let type: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct SpiderfootLookupArgs: Decodable {
        let target: String?
        let use_case: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct NexfilLookupArgs: Decodable {
        let username: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct MarpleLookupArgs: Decodable {
        let name: String?
        let engines: String?
        let results_count: LenientInt?
        let threshold: LenientInt?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct Prot1ntelligenceLookupArgs: Decodable {
        let email: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct SlashLookupArgs: Decodable {
        let query: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct TorbotLookupArgs: Decodable {
        let url: String?
        let depth: LenientInt?
        let use_tor: LenientBool?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct CrosslinkedLookupArgs: Decodable {
        let company_name: String?
        let naming_format: String?
        let search_engines: String?
        let timeout: LenientInt?
        let jitter: LenientInt?
        let agent_id: String?
    }

    private struct Sublist3rLookupArgs: Decodable {
        let domain: String?
        let engines: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct SherlockLookupArgs: Decodable {
        let username: String?
        let site: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct HoleheLookupArgs: Decodable {
        let email: String?
        let timeout: LenientInt?
        let agent_id: String?
    }

    private struct PymetaLookupArgs: Decodable {
        let target: String?
        let mode: String?
        let file_types: String?
        let max_results: LenientInt?
        let timeout: LenientInt?
        let agent_id: String?
    }

    // MARK: - Blackbird

    private static func blackbirdLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: BlackbirdLookupArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        let username = args.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = args.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (username?.isEmpty == false) != (email?.isEmpty == false) else {
            return errorJSON("provide exactly one of 'username' or 'email'")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let toolPath = config.resolvedPath(for: .blackbird)
        let toolURL = URL(fileURLWithPath: toolPath.expandingTildeInPath)
        let repoDir = toolURL.deletingLastPathComponent().path

        var arguments: [String] = []
        if let username, !username.isEmpty {
            arguments.append(contentsOf: ["--username", username])
        } else if let email, !email.isEmpty {
            arguments.append(contentsOf: ["--email", email])
        }
        arguments.append("--json")

        let timeout = TimeInterval(args.timeout?.value ?? 120)
        let service = ExternalOSINTToolService.shared

        do {
            let result = try await service.run(
                tool: .blackbird,
                arguments: arguments,
                cwd: repoDir,
                timeout: timeout
            )
            guard result.success || result.stderr.contains("Saved results") else {
                return jsonString([
                    "success": false,
                    "exit_code": result.exitCode,
                    "command": result.command,
                    "error": result.stderr,
                    "stdout": result.stdout,
                ])
            }

            let findings = parseBlackbirdResults(repoDir: repoDir, query: username ?? email ?? "")
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseBlackbirdResults(repoDir: String, query: String) -> [OSINTProfileFinding] {
        let resultsDir = (repoDir as NSString).appendingPathComponent("results")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: resultsDir) else { return [] }

        // Materialise paths before entering async-sensitive parsing.
        let relativePaths = enumerator.allObjects.compactMap { $0 as? String }

        var latestFile: (path: String, date: Date)?
        for relativePath in relativePaths {
            guard relativePath.hasSuffix(".json") else { continue }
            let fullPath = (resultsDir as NSString).appendingPathComponent(relativePath)
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date else { continue }
            if latestFile == nil || modDate > latestFile!.date {
                latestFile = (fullPath, modDate)
            }
        }
        guard let latestFile else { return [] }

        guard let data = fm.contents(atPath: latestFile.path) else { return [] }
        guard let accounts = try? JSONDecoder().decode([BlackbirdAccount].self, from: data) else { return [] }

        return accounts.compactMap { account in
            guard account.status.uppercased() == "FOUND" else { return nil }
            let value = account.url.isEmpty ? "\(account.name): \(query)" : account.url
            return OSINTProfileFinding(
                entityType: .account,
                value: value,
                label: "\(account.name) — \(account.category)",
                source: "blackbird",
                sourceURL: account.url.isEmpty ? nil : account.url,
                confidence: .medium,
                notes: "Discovered via Blackbird username/email enumeration."
            )
        }
    }

    private struct BlackbirdAccount: Codable {
        let name: String
        let url: String
        let category: String
        let status: String
    }

    // MARK: - Subfinder

    private static func subfinderLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SubfinderLookupArgs.self),
              let domain = args.domain?.trimmingCharacters(in: .whitespacesAndNewlines), !domain.isEmpty else {
            return errorJSON("'domain' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let tempFile = temporaryOutputFile(prefix: "subfinder_\(domain)", extension: "json")
        let timeout = TimeInterval(args.timeout?.value ?? 120)
        let service = ExternalOSINTToolService.shared

        do {
            let result = try await service.run(
                tool: .subfinder,
                arguments: ["-d", domain, "-oJ", "-o", tempFile],
                timeout: timeout
            )

            let findings = parseSubfinderResults(file: tempFile, domain: domain)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }
            cleanupTempFile(tempFile)

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            cleanupTempFile(tempFile)
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseSubfinderResults(file: String, domain: String) -> [OSINTProfileFinding] {
        guard let data = FileManager.default.contents(atPath: file),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var findings: [OSINTProfileFinding] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            guard let entry = try? JSONDecoder().decode(SubfinderResult.self, from: lineData) else { continue }
            findings.append(OSINTProfileFinding(
                entityType: .website,
                value: entry.host,
                label: "Subdomain — \(domain)",
                source: "subfinder",
                sourceURL: "https://\(entry.host)",
                confidence: .high,
                notes: "Discovered via subfinder passive enumeration (source: \(entry.source))."
            ))
        }
        return findings
    }

    private struct SubfinderResult: Codable {
        let host: String
        let source: String
    }

    // MARK: - theHarvester

    private static func theHarvesterLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: TheHarvesterLookupArgs.self),
              let domain = args.domain?.trimmingCharacters(in: .whitespacesAndNewlines), !domain.isEmpty else {
            return errorJSON("'domain' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let tempPrefix = temporaryOutputFile(prefix: "theharvester_\(domain)", extension: "")
        let timeout = TimeInterval(args.timeout?.value ?? 180)
        let service = ExternalOSINTToolService.shared
        let sources = args.sources?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? args.sources!
            : "all"

        do {
            let result = try await service.run(
                tool: .theHarvester,
                arguments: ["-d", domain, "-b", sources, "-f", tempPrefix],
                timeout: timeout
            )

            let reportPath = tempPrefix + ".json"
            let findings = parseTheHarvesterResults(file: reportPath, domain: domain)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }
            cleanupTempFile(reportPath)
            cleanupTempFile(tempPrefix + ".xml")
            cleanupTempFile(tempPrefix + ".html")

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            cleanupTempFile(tempPrefix + ".json")
            cleanupTempFile(tempPrefix + ".xml")
            cleanupTempFile(tempPrefix + ".html")
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseTheHarvesterResults(file: String, domain: String) -> [OSINTProfileFinding] {
        guard let data = FileManager.default.contents(atPath: file) else { return [] }
        guard let report = try? JSONDecoder().decode(TheHarvesterReport.self, from: data) else { return [] }

        var findings: [OSINTProfileFinding] = []

        for email in report.emails ?? [] {
            findings.append(OSINTProfileFinding(
                entityType: .email,
                value: email,
                label: "Email — \(domain)",
                source: "theHarvester",
                sourceURL: nil,
                confidence: .medium,
                notes: "Discovered via theHarvester domain reconnaissance."
            ))
        }

        for host in report.hosts ?? [] {
            let value = host.contains(",") ? String(host.split(separator: ",").first ?? Substring(host)) : host
            findings.append(OSINTProfileFinding(
                entityType: .website,
                value: value,
                label: "Host — \(domain)",
                source: "theHarvester",
                sourceURL: value.contains(".") ? "https://\(value)" : nil,
                confidence: .medium,
                notes: "Discovered via theHarvester domain reconnaissance."
            ))
        }

        for ip in report.ips ?? [] {
            findings.append(OSINTProfileFinding(
                entityType: .other,
                value: ip,
                label: "IP — \(domain)",
                source: "theHarvester",
                sourceURL: nil,
                confidence: .medium,
                notes: "Discovered via theHarvester domain reconnaissance."
            ))
        }

        for url in report.interesting_urls ?? [] {
            findings.append(OSINTProfileFinding(
                entityType: .website,
                value: url,
                label: "Interesting URL — \(domain)",
                source: "theHarvester",
                sourceURL: url,
                confidence: .medium,
                notes: "Discovered via theHarvester domain reconnaissance."
            ))
        }

        return findings
    }

    private struct TheHarvesterReport: Codable {
        let emails: [String]?
        let hosts: [String]?
        let ips: [String]?
        let interesting_urls: [String]?
    }

    // MARK: - GitFive

    private static func gitfiveLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: GitfiveLookupArgs.self) else {
            return errorJSON("could not parse arguments")
        }
        let username = args.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = args.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (username?.isEmpty == false) != (email?.isEmpty == false) else {
            return errorJSON("provide exactly one of 'username' or 'email'")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let tempFile = temporaryOutputFile(prefix: "gitfive_\(username ?? email ?? "target")", extension: "json")
        let timeout = TimeInterval(args.timeout?.value ?? 180)
        let service = ExternalOSINTToolService.shared

        var arguments: [String] = []
        if let username, !username.isEmpty {
            arguments.append(contentsOf: ["user", username, "--json", tempFile])
        } else if let email, !email.isEmpty {
            arguments.append(contentsOf: ["email", email, "--json", tempFile])
        }

        do {
            let result = try await service.run(
                tool: .gitfive,
                arguments: arguments,
                timeout: timeout
            )
            guard result.success else {
                cleanupTempFile(tempFile)
                return jsonString([
                    "success": false,
                    "exit_code": result.exitCode,
                    "command": result.command,
                    "error": result.stderr,
                    "note": "GitFive requires 'gitfive login' in Terminal first.",
                ])
            }

            let findings = parseGitfiveResults(file: tempFile)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }
            cleanupTempFile(tempFile)

            return jsonString([
                "success": true,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            cleanupTempFile(tempFile)
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseGitfiveResults(file: String) -> [OSINTProfileFinding] {
        guard let data = FileManager.default.contents(atPath: file) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var findings: [OSINTProfileFinding] = []
        let source = "gitfive"

        if let username = json["username"] as? String, !username.isEmpty {
            findings.append(OSINTProfileFinding(
                entityType: .account,
                value: "github.com/\(username)",
                label: "GitHub — \(username)",
                source: source,
                sourceURL: "https://github.com/\(username)",
                confidence: .high,
                notes: "GitHub profile investigated via GitFive."
            ))
        }

        if let name = json["name"] as? String, !name.isEmpty {
            findings.append(OSINTProfileFinding(
                entityType: .name,
                value: name,
                label: "GitHub display name",
                source: source,
                sourceURL: nil,
                confidence: .high,
                notes: "Name from GitHub profile."
            ))
        }

        if let company = json["company"] as? String, !company.isEmpty {
            findings.append(OSINTProfileFinding(
                entityType: .organization,
                value: company,
                label: "GitHub company",
                source: source,
                sourceURL: nil,
                confidence: .medium,
                notes: "Company from GitHub profile."
            ))
        }

        if let location = json["location"] as? String, !location.isEmpty {
            findings.append(OSINTProfileFinding(
                entityType: .location,
                value: location,
                label: "GitHub location",
                source: source,
                sourceURL: nil,
                confidence: .medium,
                notes: "Location from GitHub profile."
            ))
        }

        if let blog = json["blog"] as? String, !blog.isEmpty {
            findings.append(OSINTProfileFinding(
                entityType: .website,
                value: blog,
                label: "GitHub blog",
                source: source,
                sourceURL: blog,
                confidence: .medium,
                notes: "Blog/website from GitHub profile."
            ))
        }

        if let twitter = json["twitter"] as? String, !twitter.isEmpty {
            findings.append(OSINTProfileFinding(
                entityType: .account,
                value: "twitter.com/\(twitter)",
                label: "Twitter/X — \(twitter)",
                source: source,
                sourceURL: "https://twitter.com/\(twitter)",
                confidence: .medium,
                notes: "Twitter username from GitHub profile."
            ))
        }

        if let emails = json["emails"] as? [String] {
            for email in emails {
                findings.append(OSINTProfileFinding(
                    entityType: .email,
                    value: email,
                    label: "GitHub email",
                    source: source,
                    sourceURL: nil,
                    confidence: .medium,
                    notes: "Email discovered via GitFive."
                ))
            }
        }

        return findings
    }

    // MARK: - GHunt

    private static func ghuntEmail(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: GhuntEmailArgs.self),
              let email = args.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            return errorJSON("'email' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let tempFile = temporaryOutputFile(prefix: "ghunt_\(email)", extension: "json")
        let timeout = TimeInterval(args.timeout?.value ?? 120)
        let service = ExternalOSINTToolService.shared

        do {
            let result = try await service.run(
                tool: .ghunt,
                arguments: ["email", email, "--json", tempFile],
                timeout: timeout
            )
            guard result.success else {
                cleanupTempFile(tempFile)
                return jsonString([
                    "success": false,
                    "exit_code": result.exitCode,
                    "command": result.command,
                    "error": result.stderr,
                    "note": "GHunt requires 'ghunt login' in Terminal first.",
                ])
            }

            let findings = parseGhuntResults(file: tempFile, email: email)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }
            cleanupTempFile(tempFile)

            return jsonString([
                "success": true,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            cleanupTempFile(tempFile)
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseGhuntResults(file: String, email: String) -> [OSINTProfileFinding] {
        guard let data = FileManager.default.contents(atPath: file) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var findings: [OSINTProfileFinding] = []
        let source = "ghunt"

        // GHunt groups data into containers. Scan each container for known fields.
        for (_, value) in json {
            guard let container = value as? [String: Any] else { continue }

            if let name = container["name"] as? String, !name.isEmpty {
                findings.append(OSINTProfileFinding(
                    entityType: .name,
                    value: name,
                    label: "Google profile name",
                    source: source,
                    sourceURL: nil,
                    confidence: .medium,
                    notes: "Name from GHunt email investigation of \(email)."
                ))
            }

            if let profilePhoto = container["profile_photo"] as? String, !profilePhoto.isEmpty {
                findings.append(OSINTProfileFinding(
                    entityType: .image,
                    value: profilePhoto,
                    label: "Google profile photo",
                    source: source,
                    sourceURL: profilePhoto,
                    confidence: .medium,
                    notes: "Profile photo from GHunt email investigation of \(email)."
                ))
            }
        }

        return findings
    }

    // MARK: - Social Analyzer

    private static func socialAnalyzerLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SocialAnalyzerLookupArgs.self),
              let username = args.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
            return errorJSON("'username' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let toolPath = config.resolvedPath(for: .socialAnalyzer)
        let repoDir = (toolPath as NSString).expandingTildeInPath
        let mode = args.mode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? args.mode!
            : "fast"
        // Social Analyzer is slow across 1000+ sites; keep a tight default so the UI
        // does not hang, but allow the caller to request more time if they accept it.
        let requestedTimeout = TimeInterval(args.timeout?.value ?? 45)
        let timeout = min(requestedTimeout, 120)
        let service = ExternalOSINTToolService.shared

        do {
            let result = try await service.run(
                tool: .socialAnalyzer,
                arguments: ["--username", username, "--output", "json", "--mode", mode, "--silent"],
                cwd: (repoDir as NSString).deletingLastPathComponent,
                timeout: timeout
            )

            let findings = parseSocialAnalyzerResults(stdout: result.stdout, username: username)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseSocialAnalyzerResults(stdout: String, username: String) -> [OSINTProfileFinding] {
        guard let data = stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var findings: [OSINTProfileFinding] = []
        let source = "social-analyzer"

        if let detected = json["detected"] as? [[String: Any]] {
            for profile in detected {
                guard let link = profile["link"] as? String, !link.isEmpty else { continue }
                let title = profile["title"] as? String ?? ""
                let site = profile["type"] as? String ?? profile["site"] as? String ?? "Social profile"
                let status = profile["status"] as? String ?? ""
                let confidence: OSINTConfidence = status.lowercased().contains("found") ? .high : .medium

                findings.append(OSINTProfileFinding(
                    entityType: .account,
                    value: link,
                    label: "\(site) — \(username)",
                    source: source,
                    sourceURL: link,
                    confidence: confidence,
                    notes: "Detected by Social Analyzer.\(title.isEmpty ? "" : " Title: \(title).")"
                ))
            }
        }

        return findings
    }

    // MARK: - DNSRecon

    private static func dnsreconLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: DNSReconLookupArgs.self),
              let domain = args.domain?.trimmingCharacters(in: .whitespacesAndNewlines), !domain.isEmpty else {
            return errorJSON("'domain' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let tempFile = temporaryOutputFile(prefix: "dnsrecon_\(domain)", extension: "csv")
        let timeout = TimeInterval(args.timeout?.value ?? 120)
        let service = ExternalOSINTToolService.shared
        let enumType = args.type?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? args.type!
            : "std"

        do {
            let result = try await service.run(
                tool: .dnsrecon,
                arguments: ["-d", domain, "-t", enumType, "--csv", tempFile],
                cwd: ((config.resolvedPath(for: .dnsrecon) as NSString).expandingTildeInPath as NSString).deletingLastPathComponent,
                timeout: timeout
            )

            let findings = parseDNSReconResults(file: tempFile, domain: domain)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }
            cleanupTempFile(tempFile)

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            cleanupTempFile(tempFile)
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseDNSReconResults(file: String, domain: String) -> [OSINTProfileFinding] {
        guard let data = FileManager.default.contents(atPath: file),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var findings: [OSINTProfileFinding] = []
        let source = "dnsrecon"
        let rows = text.components(separatedBy: .newlines).dropFirst() // skip header

        for row in rows {
            let columns = parseCSVRow(row)
            guard columns.count >= 7 else { continue }
            let recordType = columns[1].trimmingCharacters(in: .whitespaces).uppercased()
            let name = columns[2].trimmingCharacters(in: .whitespaces)
            let address = columns[3].trimmingCharacters(in: .whitespaces)
            let target = columns[4].trimmingCharacters(in: .whitespaces)
            let stringValue = columns[6].trimmingCharacters(in: .whitespaces)

            switch recordType {
            case "A", "AAAA":
                if !name.isEmpty {
                    findings.append(OSINTProfileFinding(
                        entityType: .website,
                        value: name,
                        label: "\(recordType) record — \(domain)",
                        source: source,
                        sourceURL: nil,
                        confidence: .high,
                        notes: "IP: \(address.isEmpty ? "n/a" : address)"
                    ))
                }
            case "CNAME":
                if !name.isEmpty {
                    findings.append(OSINTProfileFinding(
                        entityType: .website,
                        value: name,
                        label: "CNAME — \(domain)",
                        source: source,
                        sourceURL: nil,
                        confidence: .high,
                        notes: "Points to \(target.isEmpty ? "n/a" : target)"
                    ))
                }
            case "MX":
                if !target.isEmpty {
                    findings.append(OSINTProfileFinding(
                        entityType: .other,
                        value: target,
                        label: "MX — \(domain)",
                        source: source,
                        sourceURL: nil,
                        confidence: .high,
                        notes: "Mail exchanger for \(domain)"
                    ))
                }
            case "NS":
                if !target.isEmpty {
                    findings.append(OSINTProfileFinding(
                        entityType: .other,
                        value: target,
                        label: "NS — \(domain)",
                        source: source,
                        sourceURL: nil,
                        confidence: .high,
                        notes: "Name server for \(domain)"
                    ))
                }
            case "TXT":
                if !stringValue.isEmpty {
                    findings.append(OSINTProfileFinding(
                        entityType: .other,
                        value: stringValue,
                        label: "TXT — \(domain)",
                        source: source,
                        sourceURL: nil,
                        confidence: .medium,
                        notes: "TXT record"
                    ))
                }
            case "SRV":
                if !target.isEmpty {
                    findings.append(OSINTProfileFinding(
                        entityType: .other,
                        value: target,
                        label: "SRV — \(domain)",
                        source: source,
                        sourceURL: nil,
                        confidence: .high,
                        notes: "Service record"
                    ))
                }
            default:
                break
            }
        }

        return findings
    }

    /// Very basic CSV row splitter that respects simple quoted fields.
    private static func parseCSVRow(_ row: String) -> [String] {
        var result: [String] = []
        var current = ""
        var insideQuotes = false
        for character in row {
            if character == "\"" {
                insideQuotes.toggle()
            } else if character == "," && !insideQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }

    // MARK: - SpiderFoot

    private static func spiderfootLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SpiderfootLookupArgs.self),
              let target = args.target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else {
            return errorJSON("'target' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let useCase = args.use_case?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? args.use_case!
            : "passive"
        let timeout = TimeInterval(args.timeout?.value ?? 180)
        let service = ExternalOSINTToolService.shared
        let repoDir = ((config.resolvedPath(for: .spiderfoot) as NSString).expandingTildeInPath as NSString).deletingLastPathComponent

        do {
            let result = try await service.run(
                tool: .spiderfoot,
                arguments: ["-s", target, "-u", useCase, "-o", "json", "-n", "-q"],
                cwd: repoDir,
                timeout: timeout
            )

            let findings = parseSpiderfootResults(stdout: result.stdout, target: target)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseSpiderfootResults(stdout: String, target: String) -> [OSINTProfileFinding] {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        var findings: [OSINTProfileFinding] = []
        let source = "spiderfoot"

        for event in events {
            guard let type = event["type"] as? String else { continue }
            let dataValue = event["data"] as? String ?? ""
            let module = event["module"] as? String ?? "unknown"
            guard !dataValue.isEmpty else { continue }

            let (entityType, label, sourceURL) = spiderfootEntityMapping(type: type, value: dataValue)
            findings.append(OSINTProfileFinding(
                entityType: entityType,
                value: dataValue,
                label: "\(label) — \(target)",
                source: source,
                sourceURL: sourceURL,
                confidence: .medium,
                notes: "SpiderFoot module: \(module), event type: \(type)"
            ))
        }

        return findings
    }

    private static func spiderfootEntityMapping(type: String, value: String) -> (OSINTEntityType, String, String?) {
        let upper = type.uppercased()

        if upper.contains("EMAIL") {
            return (.email, "Email", value.contains("@") ? nil : nil)
        }
        if upper.contains("IP_ADDRESS") || upper.contains("IPV6_ADDRESS") || upper.contains("NETBLOCK") {
            return (.other, "IP/Netblock", nil)
        }
        if upper.contains("DOMAIN") || upper.contains("INTERNET_NAME") || upper.contains("WEBSERVER") || upper.contains("URL") {
            return (.website, "Domain/URL", value.hasPrefix("http") ? value : "https://\(value)")
        }
        if upper.contains("HUMAN_NAME") {
            return (.name, "Name", nil)
        }
        if upper.contains("USERNAME") || upper.contains("ACCOUNT") {
            return (.account, "Account", value.hasPrefix("http") ? value : nil)
        }
        if upper.contains("PHONE") {
            return (.phone, "Phone", nil)
        }
        if upper.contains("LOCATION") || upper.contains("GEO") || upper.contains("PHYSICAL") {
            return (.location, "Location", nil)
        }
        if upper.contains("ORG") || upper.contains("COMPANY") {
            return (.organization, "Organization", nil)
        }
        if upper.contains("IMAGE") || upper.contains("PHOTO") {
            return (.image, "Image", value.hasPrefix("http") ? value : nil)
        }

        return (.other, "Discovery", value.hasPrefix("http") ? value : nil)
    }

    // MARK: - NExfil

    private static func nexfilLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: NexfilLookupArgs.self),
              let username = args.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
            return errorJSON("'username' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        // NExfil's -t is per-site; across 350+ sites a large value is unusable. Cap total
        // runtime even if the per-site timeout would allow longer.
        let perSiteTimeout = TimeInterval(args.timeout?.value ?? 10)
        let totalTimeout = min(perSiteTimeout * 4 + 10, 45)
        let service = ExternalOSINTToolService.shared

        do {
            let result = try await service.run(
                tool: .nexfil,
                arguments: ["-u", username, "-t", String(Int(perSiteTimeout))],
                timeout: totalTimeout
            )

            let findings = parseNexfilResults(stdout: result.stdout, username: username)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseNexfilResults(stdout: String, username: String) -> [OSINTProfileFinding] {
        let cleaned = stripANSIEscapeCodes(stdout)
        let source = "nexfil"
        var seen = Set<String>()
        var findings: [OSINTProfileFinding] = []

        guard let regex = try? NSRegularExpression(pattern: "https?://\\S+", options: []) else { return [] }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        for match in regex.matches(in: cleaned, options: [], range: range) {
            let url = (cleaned as NSString).substring(with: match.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, !seen.contains(url) else { continue }
            seen.insert(url)
            findings.append(OSINTProfileFinding(
                entityType: .account,
                value: url,
                label: "Profile — \(username)",
                source: source,
                sourceURL: url,
                confidence: .medium,
                notes: "Discovered by NExfil."
            ))
        }

        return findings
    }

    // MARK: - Marple

    private static func marpleLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: MarpleLookupArgs.self),
              let name = args.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return errorJSON("'name' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let timeout = TimeInterval(args.timeout?.value ?? 90)
        let service = ExternalOSINTToolService.shared
        let repoDir = ((config.resolvedPath(for: .marple) as NSString).expandingTildeInPath as NSString).deletingLastPathComponent
        // Searching many engines with a huge results count is very slow; default small.
        let resultsCount = min(args.results_count?.value ?? 100, 1000)
        let threshold = args.threshold?.value ?? 300

        var arguments: [String] = [
            name,
            "--list",
            "--results-count", String(resultsCount),
            "--threshold", String(threshold),
        ]
        if let engines = args.engines?.trimmingCharacters(in: .whitespacesAndNewlines), !engines.isEmpty {
            arguments.append("--engines")
            arguments.append(contentsOf: engines.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }

        do {
            let result = try await service.run(
                tool: .marple,
                arguments: arguments,
                cwd: repoDir,
                timeout: timeout
            )

            let findings = parseMarpleResults(stdout: result.stdout)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseMarpleResults(stdout: String) -> [OSINTProfileFinding] {
        let cleaned = stripANSIEscapeCodes(stdout)
        let source = "marple"
        var seen = Set<String>()
        var findings: [OSINTProfileFinding] = []

        for line in cleaned.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("http"), !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            findings.append(OSINTProfileFinding(
                entityType: .account,
                value: trimmed,
                label: "Search-engine profile",
                source: source,
                sourceURL: trimmed,
                confidence: .medium,
                notes: "Discovered by Marple search-engine link collection."
            ))
        }

        return findings
    }

    // MARK: - Prot1ntelligence

    private static func prot1ntelligenceLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: Prot1ntelligenceLookupArgs.self),
              let email = args.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            return errorJSON("'email' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let timeout = TimeInterval(args.timeout?.value ?? 60)
        let service = ExternalOSINTToolService.shared
        let scriptPath = (config.resolvedPath(for: .prot1ntelligence) as NSString).expandingTildeInPath
        let repoDir = (scriptPath as NSString).deletingLastPathComponent
        let python = pythonExecutable(in: repoDir)

        let command = "printf '%s\\n' \(ExternalOSINTToolService.escapeShellArgument(email)) | \(python) \(ExternalOSINTToolService.escapeShellArgument(scriptPath))"

        do {
            let result = try await service.run(
                tool: .prot1ntelligence,
                command: command,
                cwd: repoDir,
                timeout: timeout
            )

            let findings = parseProt1ntelligenceResults(stdout: result.stdout, email: email)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseProt1ntelligenceResults(stdout: String, email: String) -> [OSINTProfileFinding] {
        let source = "prot1ntelligence"
        var findings: [OSINTProfileFinding] = []
        let text = stdout

        let isProton = text.contains("Protonmail address") || text.contains("Protonmail custom domain")
        guard isProton else { return findings }

        var notes = "Confirmed ProtonMail address."

        if let range = text.range(of: "PGP Key Date and Creation Time: ") {
            let tail = String(text[range.upperBound...])
            let date = tail.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !date.isEmpty { notes += " PGP created: \(date)." }
        }

        if let range = text.range(of: "Encryption Standard : ") {
            let tail = String(text[range.upperBound...])
            let standard = tail.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !standard.isEmpty { notes += " Encryption: \(standard)." }
        }

        findings.append(OSINTProfileFinding(
            entityType: .email,
            value: email,
            label: "ProtonMail — \(email)",
            source: source,
            sourceURL: nil,
            confidence: .high,
            notes: notes
        ))

        if let range = text.range(of: "main email --> ") {
            let tail = String(text[range.upperBound...])
            let actual = tail.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !actual.isEmpty && actual != email {
                findings.append(OSINTProfileFinding(
                    entityType: .email,
                    value: actual,
                    label: "ProtonMail catch-all — \(actual)",
                    source: source,
                    sourceURL: nil,
                    confidence: .high,
                    notes: "Catch-all real email discovered by Prot1ntelligence."
                ))
            }
        }

        return findings
    }

    // MARK: - slash

    private static func slashLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SlashLookupArgs.self),
              let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return errorJSON("'query' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let timeout = TimeInterval(args.timeout?.value ?? 180)
        let service = ExternalOSINTToolService.shared
        let repoDir = ((config.resolvedPath(for: .slash) as NSString).expandingTildeInPath as NSString).deletingLastPathComponent

        do {
            let result = try await service.run(
                tool: .slash,
                arguments: [query],
                cwd: repoDir,
                timeout: timeout
            )

            let findings = parseSlashResults(stdout: result.stdout)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseSlashResults(stdout: String) -> [OSINTProfileFinding] {
        let cleaned = stripANSIEscapeCodes(stdout)
        let source = "slash"
        var urls = Set<String>()
        var emails = Set<String>()
        var findings: [OSINTProfileFinding] = []

        // URLs
        if let urlRegex = try? NSRegularExpression(pattern: "https?://[^\\s<>\"{}|\\\\^`\\[\\]]+", options: .caseInsensitive) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            for match in urlRegex.matches(in: cleaned, options: [], range: range) {
                let value = (cleaned as NSString).substring(with: match.range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { urls.insert(value) }
            }
        }

        // Emails
        if let emailRegex = try? NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: .caseInsensitive) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            for match in emailRegex.matches(in: cleaned, options: [], range: range) {
                let value = (cleaned as NSString).substring(with: match.range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { emails.insert(value) }
            }
        }

        for url in urls.sorted() {
            findings.append(OSINTProfileFinding(
                entityType: .account,
                value: url,
                label: "Discovered URL",
                source: source,
                sourceURL: url,
                confidence: .medium,
                notes: "Discovered by slash OSINT sweep."
            ))
        }

        for email in emails.sorted() {
            findings.append(OSINTProfileFinding(
                entityType: .email,
                value: email,
                label: "Discovered email",
                source: source,
                sourceURL: nil,
                confidence: .medium,
                notes: "Discovered by slash OSINT sweep."
            ))
        }

        return findings
    }

    // MARK: - TorBot

    private static func torbotLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: TorbotLookupArgs.self),
              let url = args.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            return errorJSON("'url' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let depth = max(0, args.depth?.value ?? 1)
        let useTor = args.use_tor?.value ?? false
        let timeout = TimeInterval(args.timeout?.value ?? 120)
        let service = ExternalOSINTToolService.shared
        let scriptPath = (config.resolvedPath(for: .torBot) as NSString).expandingTildeInPath
        let repoDir = (scriptPath as NSString).deletingLastPathComponent
        let python = pythonExecutable(in: repoDir)

        var flags: [String] = [
            "-u", url,
            "--depth", String(depth),
            "--visualize", "json",
            "-q",
        ]
        if !useTor {
            flags.append("--disable-socks5")
        }

        let flagString = flags.map(ExternalOSINTToolService.escapeShellArgument).joined(separator: " ")
        let command = "PYTHONPATH='src' \(python) \(ExternalOSINTToolService.escapeShellArgument(scriptPath)) \(flagString)"

        do {
            let result = try await service.run(
                tool: .torBot,
                command: command,
                cwd: repoDir,
                timeout: timeout
            )

            let findings = parseTorbotResults(stdout: result.stdout)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseTorbotResults(stdout: String) -> [OSINTProfileFinding] {
        let source = "torbot"
        var urls = Set<String>()
        var emails = Set<String>()
        var phones = Set<String>()

        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            collectTorbotValues(from: json, urls: &urls, emails: &emails, phones: &phones)
        }

        // Fallback regex extraction if JSON parsing fails or misses values.
        if urls.isEmpty || emails.isEmpty {
            let fallback = stripANSIEscapeCodes(stdout)
            if let urlRegex = try? NSRegularExpression(pattern: "https?://[^\\s<>\"{}|\\\\^`\\[\\]]+", options: .caseInsensitive) {
                let range = NSRange(fallback.startIndex..., in: fallback)
                for match in urlRegex.matches(in: fallback, options: [], range: range) {
                    let value = (fallback as NSString).substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { urls.insert(value) }
                }
            }
            if let emailRegex = try? NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: .caseInsensitive) {
                let range = NSRange(fallback.startIndex..., in: fallback)
                for match in emailRegex.matches(in: fallback, options: [], range: range) {
                    let value = (fallback as NSString).substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { emails.insert(value) }
                }
            }
        }

        var findings: [OSINTProfileFinding] = []

        for url in urls.sorted() {
            findings.append(OSINTProfileFinding(
                entityType: .website,
                value: url,
                label: "Crawled URL",
                source: source,
                sourceURL: url,
                confidence: .medium,
                notes: "Discovered by TorBot crawl."
            ))
        }

        for email in emails.sorted() {
            findings.append(OSINTProfileFinding(
                entityType: .email,
                value: email,
                label: "Crawled email",
                source: source,
                sourceURL: nil,
                confidence: .medium,
                notes: "Discovered by TorBot crawl."
            ))
        }

        for phone in phones.sorted() {
            findings.append(OSINTProfileFinding(
                entityType: .phone,
                value: phone,
                label: "Crawled phone",
                source: source,
                sourceURL: nil,
                confidence: .low,
                notes: "Discovered by TorBot crawl."
            ))
        }

        return findings
    }

    private static func collectTorbotValues(from value: Any, urls: inout Set<String>, emails: inout Set<String>, phones: inout Set<String>) {
        switch value {
        case let dict as [String: Any]:
            for (key, val) in dict {
                if key == "emails", let list = val as? [String] {
                    emails.formUnion(list.filter { !$0.isEmpty })
                } else if key == "numbers", let list = val as? [String] {
                    phones.formUnion(list.filter { !$0.isEmpty })
                } else {
                    collectTorbotValues(from: val, urls: &urls, emails: &emails, phones: &phones)
                }
            }
        case let array as [Any]:
            array.forEach { collectTorbotValues(from: $0, urls: &urls, emails: &emails, phones: &phones) }
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if trimmed.lowercased().hasPrefix("http") {
                urls.insert(trimmed)
            } else if trimmed.contains("@"), matchesRegex(trimmed, pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}") {
                emails.insert(trimmed)
            } else if matchesRegex(trimmed, pattern: "^(\\+?\\d{1,3}[\\s\\-\\.]?)?\\(?\\d{2,4}\\)?[\\s\\-\\.]?\\d{2,4}[\\s\\-\\.]?\\d{2,9}$") {
                phones.insert(trimmed)
            }
        default:
            break
        }
    }

    // MARK: - CrossLinked

    private static func crosslinkedLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: CrosslinkedLookupArgs.self),
              let companyName = args.company_name?.trimmingCharacters(in: .whitespacesAndNewlines), !companyName.isEmpty else {
            return errorJSON("'company_name' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let namingFormat = args.naming_format?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? args.naming_format!
            : "{first}.{last}"
        let engines = args.search_engines?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? args.search_engines!
            : "google,bing"
        let timeout = TimeInterval(args.timeout?.value ?? 30)
        let jitter = TimeInterval(args.jitter?.value ?? 1)
        let service = ExternalOSINTToolService.shared

        let sanitizedCompany = companyName.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let outPrefix = temporaryOutputFile(prefix: "crosslinked_\(sanitizedCompany)", extension: "")
        let repoDir = ((config.resolvedPath(for: .crosslinked) as NSString).expandingTildeInPath as NSString).deletingLastPathComponent

        do {
            let result = try await service.run(
                tool: .crosslinked,
                arguments: [
                    "-f", namingFormat,
                    "-o", outPrefix,
                    "--search", engines,
                    "-t", String(Int(timeout)),
                    "-j", String(Int(jitter)),
                    companyName,
                ],
                cwd: repoDir,
                timeout: timeout * 4 + 10 // CrossLinked runs multiple searches; give it headroom.
            )

            let findings = parseCrosslinkedResults(outPrefix: outPrefix, companyName: companyName, namingFormat: namingFormat)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }
            cleanupTempFile(outPrefix + ".txt")
            cleanupTempFile(outPrefix + ".csv")

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            cleanupTempFile(outPrefix + ".txt")
            cleanupTempFile(outPrefix + ".csv")
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseCrosslinkedResults(outPrefix: String, companyName: String, namingFormat: String) -> [OSINTProfileFinding] {
        let source = "crosslinked"
        var findings: [OSINTProfileFinding] = []
        var seenURLs = Set<String>()
        var seenNames = Set<String>()
        var seenIdentifiers = Set<String>()

        let csvFile = outPrefix + ".csv"
        if let data = FileManager.default.contents(atPath: csvFile),
           let text = String(data: data, encoding: .utf8) {
            let rows = text.components(separatedBy: .newlines).dropFirst() // skip header
            for row in rows {
                let columns = parseCSVRow(row)
                guard columns.count >= 5 else { continue }
                let name = columns[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let title = columns[3].trimmingCharacters(in: .whitespacesAndNewlines)
                let url = columns[4].trimmingCharacters(in: .whitespacesAndNewlines)

                if !name.isEmpty && !seenNames.contains(name) {
                    seenNames.insert(name)
                    findings.append(OSINTProfileFinding(
                        entityType: .name,
                        value: name,
                        label: "CrossLinked employee — \(companyName)",
                        source: source,
                        sourceURL: url.isEmpty ? nil : url,
                        confidence: .medium,
                        notes: "Discovered via CrossLinked search-engine scrape.\(title.isEmpty || title == "N/A" ? "" : " Title: \(title).")"
                    ))
                }

                if !url.isEmpty && !seenURLs.contains(url) {
                    seenURLs.insert(url)
                    findings.append(OSINTProfileFinding(
                        entityType: .account,
                        value: url,
                        label: "LinkedIn profile — \(companyName)",
                        source: source,
                        sourceURL: url,
                        confidence: .medium,
                        notes: "Employee LinkedIn profile discovered by CrossLinked."
                    ))
                }
            }
        }

        let txtFile = outPrefix + ".txt"
        if let data = FileManager.default.contents(atPath: txtFile),
           let text = String(data: data, encoding: .utf8) {
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seenIdentifiers.contains(trimmed) else { continue }
                seenIdentifiers.insert(trimmed)

                let isEmail = trimmed.contains("@") && matchesRegex(trimmed, pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}")
                findings.append(OSINTProfileFinding(
                    entityType: isEmail ? .email : .account,
                    value: trimmed,
                    label: isEmail ? "CrossLinked generated email" : "CrossLinked generated identifier",
                    source: source,
                    sourceURL: nil,
                    confidence: .low,
                    notes: "Generated from CrossLinked naming format '\(namingFormat)' for \(companyName)."
                ))
            }
        }

        return findings
    }

    // MARK: - Sublist3r

    private static func sublist3rLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: Sublist3rLookupArgs.self),
              let domain = args.domain?.trimmingCharacters(in: .whitespacesAndNewlines), !domain.isEmpty else {
            return errorJSON("'domain' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let timeout = TimeInterval(args.timeout?.value ?? 120)
        let service = ExternalOSINTToolService.shared
        let repoDir = ((config.resolvedPath(for: .sublist3r) as NSString).expandingTildeInPath as NSString).deletingLastPathComponent

        var arguments: [String] = ["-d", domain, "-n"]
        if let engines = args.engines?.trimmingCharacters(in: .whitespacesAndNewlines), !engines.isEmpty {
            arguments.append(contentsOf: ["-e", engines])
        }

        do {
            let result = try await service.run(
                tool: .sublist3r,
                arguments: arguments,
                cwd: repoDir,
                timeout: timeout
            )

            let findings = parseSublist3rResults(stdout: result.stdout, domain: domain)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseSublist3rResults(stdout: String, domain: String) -> [OSINTProfileFinding] {
        let cleaned = stripANSIEscapeCodes(stdout)
        let source = "sublist3r"
        var seen = Set<String>()
        var findings: [OSINTProfileFinding] = []

        for line in cleaned.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasSuffix(domain), !trimmed.contains(" "), !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            findings.append(OSINTProfileFinding(
                entityType: .website,
                value: trimmed,
                label: "Subdomain — \(domain)",
                source: source,
                sourceURL: "https://\(trimmed)",
                confidence: .medium,
                notes: "Discovered by Sublist3r."
            ))
        }

        return findings
    }

    // MARK: - Sherlock

    private static func sherlockLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SherlockLookupArgs.self),
              let username = args.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty else {
            return errorJSON("'username' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        // Sherlock's --timeout is per-site; across 400+ sites a large value is unusable.
        // Cap total runtime so broad scans fail fast, and strongly prefer --site.
        let perSiteTimeout = TimeInterval(args.timeout?.value ?? 10)
        let rawSite = args.site?.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = (rawSite?.isEmpty == false) ? rawSite : nil
        let service = ExternalOSINTToolService.shared

        var arguments: [String] = ["--no-color", "--print-found", "--timeout", String(Int(perSiteTimeout)), username]
        if let site {
            arguments.insert(contentsOf: ["--site", site], at: 0)
        }

        do {
            let result = try await service.run(
                tool: .sherlock,
                arguments: arguments,
                timeout: site == nil ? min(perSiteTimeout * 4 + 10, 45) : min(perSiteTimeout + 10, 30)
            )

            let findings = parseSherlockResults(stdout: result.stdout, username: username)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseSherlockResults(stdout: String, username: String) -> [OSINTProfileFinding] {
        let cleaned = stripANSIEscapeCodes(stdout)
        let source = "sherlock"
        var seen = Set<String>()
        var findings: [OSINTProfileFinding] = []

        guard let regex = try? NSRegularExpression(pattern: "^\\[+\\]\\s+([^:]+):\\s+(https?://\\S+)", options: .anchorsMatchLines) else { return [] }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        for match in regex.matches(in: cleaned, options: [], range: range) {
            let site = (cleaned as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (cleaned as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, !seen.contains(url) else { continue }
            seen.insert(url)
            findings.append(OSINTProfileFinding(
                entityType: .account,
                value: url,
                label: "\(site) — \(username)",
                source: source,
                sourceURL: url,
                confidence: .medium,
                notes: "Discovered by Sherlock."
            ))
        }

        return findings
    }

    // MARK: - Holehe

    private static func holeheLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: HoleheLookupArgs.self),
              let email = args.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            return errorJSON("'email' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let timeout = TimeInterval(args.timeout?.value ?? 10)
        let service = ExternalOSINTToolService.shared

        do {
            let result = try await service.run(
                tool: .holehe,
                arguments: ["--no-color", "--no-clear", "--only-used", "-T", String(Int(timeout)), email],
                timeout: timeout * 15 + 20
            )

            let findings = parseHoleheResults(stdout: result.stdout, email: email)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parseHoleheResults(stdout: String, email: String) -> [OSINTProfileFinding] {
        let cleaned = stripANSIEscapeCodes(stdout)
        let source = "holehe"
        var seen = Set<String>()
        var findings: [OSINTProfileFinding] = []

        guard let regex = try? NSRegularExpression(pattern: "^\\[+\\]\\s+(https?://)?([^\\s]+)", options: .anchorsMatchLines) else { return [] }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        for match in regex.matches(in: cleaned, options: [], range: range) {
            var domain = (cleaned as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if domain.hasSuffix("/") { domain = String(domain.dropLast()) }
            guard !domain.isEmpty, !seen.contains(domain) else { continue }
            seen.insert(domain)
            findings.append(OSINTProfileFinding(
                entityType: .account,
                value: domain,
                label: "Email registered on \(domain)",
                source: source,
                sourceURL: domain.hasPrefix("http") ? domain : "https://\(domain)",
                confidence: .medium,
                notes: "Email \(email) found registered on this site via Holehe."
            ))
        }

        return findings
    }

    // MARK: - PyMeta

    private static func pymetaLookup(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PymetaLookupArgs.self),
              let target = args.target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else {
            return errorJSON("'target' is required")
        }
        guard let agentID = args.agent_id, let agentUUID = UUID(uuidString: agentID) else {
            return errorJSON("agent_id unavailable")
        }

        let config = ExternalOSINTToolConfig.load()
        let mode = args.mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "search"
        let fileTypes = args.file_types?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? args.file_types!
            : "pdf,xls,xlsx,csv,doc,docx,ppt,pptx"
        let maxResults = max(1, args.max_results?.value ?? 10)
        let timeout = TimeInterval(args.timeout?.value ?? 12)
        let service = ExternalOSINTToolService.shared

        let outDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("pymeta_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true, attributes: nil)
        let reportName = "pymeta_report.csv"

        var arguments: [String]
        if mode == "local" {
            arguments = ["-dir", target, "-o", outDir, "-f", reportName]
        } else {
            arguments = [
                "-d", target,
                "-o", outDir,
                "-f", reportName,
                "--file-type", fileTypes,
                "-m", String(maxResults),
                "-t", String(Int(timeout)),
            ]
        }

        do {
            let result = try await service.run(
                tool: .pymeta,
                arguments: arguments,
                timeout: timeout * Double(maxResults) * 2 + 30
            )

            let reportPath = (outDir as NSString).appendingPathComponent(reportName)
            let findings = parsePymetaResults(report: reportPath, target: target)
            if config.autoRecordFindings {
                await service.record(findings: findings, forAgent: agentUUID)
            }
            try? FileManager.default.removeItem(atPath: outDir)

            return jsonString([
                "success": result.success,
                "exit_code": result.exitCode,
                "command": result.command,
                "findings_recorded": findings.count,
                "findings": findings.map(findingDict),
                "stderr": result.stderr,
                "timed_out": result.timedOut,
            ])
        } catch {
            try? FileManager.default.removeItem(atPath: outDir)
            return errorJSON(error.localizedDescription)
        }
    }

    private static func parsePymetaResults(report: String, target: String) -> [OSINTProfileFinding] {
        guard let data = FileManager.default.contents(atPath: report),
              let text = String(data: data, encoding: .utf8) else { return [] }

        let rows = text.components(separatedBy: .newlines)
        guard let headerLine = rows.first else { return [] }
        let headers = parseCSVRow(headerLine)
        let sourceURLIndex = headers.firstIndex(of: "SourceURL")
        let sourceFileIndex = headers.firstIndex(of: "SourceFile")

        let nameFields = ["Author", "Creator", "LastModifiedBy", "Artist"]
        let orgFields = ["Company", "Publisher", "Organization"]
        let noteFields = ["Title", "Subject", "Keywords", "Comments", "CreateDate", "ModifyDate"]

        var findings: [OSINTProfileFinding] = []
        var seen = Set<String>()

        for row in rows.dropFirst() {
            let columns = parseCSVRow(row)
            guard columns.count == headers.count else { continue }

            let sourceURL = sourceURLIndex.map { columns[$0].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let sourceFile = sourceFileIndex.map { columns[$0].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""

            if !sourceURL.isEmpty && sourceURL != "SourceURL" && !seen.contains(sourceURL) {
                seen.insert(sourceURL)
                findings.append(OSINTProfileFinding(
                    entityType: .document,
                    value: sourceURL,
                    label: "PyMeta discovered document — \(target)",
                    source: "pymeta",
                    sourceURL: sourceURL,
                    confidence: .medium,
                    notes: "Document discovered for \(target)."
                ))
            }

            for field in nameFields {
                guard let idx = headers.firstIndex(of: field) else { continue }
                let value = columns[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !seen.contains("name:\(value)") else { continue }
                seen.insert("name:\(value)")
                findings.append(OSINTProfileFinding(
                    entityType: .name,
                    value: value,
                    label: "Document author/creator — \(target)",
                    source: "pymeta",
                    sourceURL: sourceURL.isEmpty ? nil : sourceURL,
                    confidence: .medium,
                    notes: "Extracted from \(sourceFile.isEmpty ? "document" : sourceFile) via PyMeta."
                ))
            }

            for field in orgFields {
                guard let idx = headers.firstIndex(of: field) else { continue }
                let value = columns[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !seen.contains("org:\(value)") else { continue }
                seen.insert("org:\(value)")
                findings.append(OSINTProfileFinding(
                    entityType: .organization,
                    value: value,
                    label: "Document organization — \(target)",
                    source: "pymeta",
                    sourceURL: sourceURL.isEmpty ? nil : sourceURL,
                    confidence: .medium,
                    notes: "Extracted from \(sourceFile.isEmpty ? "document" : sourceFile) via PyMeta."
                ))
            }

            var notes = ""
            for field in noteFields {
                guard let idx = headers.firstIndex(of: field) else { continue }
                let value = columns[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { notes += "\(field): \(value); " }
            }
            if !notes.isEmpty, !seen.contains("notes:\(notes)") {
                seen.insert("notes:\(notes)")
                findings.append(OSINTProfileFinding(
                    entityType: .other,
                    value: notes,
                    label: "Document metadata — \(target)",
                    source: "pymeta",
                    sourceURL: sourceURL.isEmpty ? nil : sourceURL,
                    confidence: .low,
                    notes: "Extracted via PyMeta."
                ))
            }
        }

        return findings
    }

    // MARK: - Helpers

    private static func pythonExecutable(in directory: String) -> String {
        let venvPython = (directory as NSString).appendingPathComponent(".venv/bin/python")
        if FileManager.default.fileExists(atPath: venvPython) {
            return venvPython
        }
        return "python"
    }

    private static func stripANSIEscapeCodes(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\u{001B}\\[[0-9;]*[a-zA-Z]") else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
    }

    private static func matchesRegex(_ value: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }

    private static func temporaryOutputFile(prefix: String, extension ext: String) -> String {
        let sanitized = prefix.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let uuid = UUID().uuidString
        let filename = ext.isEmpty ? "\(sanitized)_\(uuid)" : "\(sanitized)_\(uuid).\(ext)"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(filename)
    }

    private static func cleanupTempFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
