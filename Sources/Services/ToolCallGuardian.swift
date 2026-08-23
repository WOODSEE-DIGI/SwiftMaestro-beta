import Foundation
import UserNotifications

// MARK: - Tool Call Guardian
//
// The self-healing layer for tool execution. Intercepted at AgentExecutor's
// executeTool choke point, so every model (built-in MLX, LM Studio, Ollama,
// online) and every tool (native + MCP) goes through it:
//
//   1. **Pre-execution normalization** — applies the model's learned quirk
//      profile (argument coercions that have healed failures for THIS model
//      before) on top of the existing ToolArgumentRepair pass.
//   2. **Classify failures** — parse / arg-validation / transient-env /
//      blocking-env / tool-bug, from the tool's error text.
//   3. **Self-heal** — transparent retry with backoff for transient
//      environment failures (locked DB, network hiccup, busy resource).
//   4. **Self-describing errors** — unhealed errors go back to the model with
//      a prescriptive recovery hint so even small models can route around
//      the failure (e.g. popup blocked → use the no-JS fetch tool).
//   5. **Learn** — failures + successful heal strategies append to a JSONL
//      log; a strategy that heals the same (model, class) failure twice
//      promotes into the model's quirk profile and applies pre-emptively
//      forever after. New external models teach themselves within a few calls.
//   6. **Escalate** — unhealed-after-retries failures can post a notification
//      (same plumbing as the crash watchdog) instead of failing silently.

actor ToolCallGuardian {

    static let shared = ToolCallGuardian()

    // MARK: - Types

    enum FailureClass: String, Codable, Sendable {
        case parse, argValidation, transientEnv, blockingEnv, toolBug, unknown
    }

    struct FailureRecord: Codable, Sendable {
        var timestamp: Date
        var tool: String
        var modelID: String
        var failureClass: FailureClass
        var errorDigest: String
        var healed: Bool
        var strategy: String
    }

    /// Per-model learned normalizers. Promoted from observed heals — never
    /// hand-authored. Applied to the argument JSON before execution.
    struct QuirkProfile: Codable, Sendable {
        var boolAsString = false       // "true"/"false" strings for bool params
        var numbersAsStrings = false   // "5" strings for int/double params
        var promotedAt: Date?
        var notes: [String] = []
    }

    // MARK: - State

    /// Whether a user notification fires when a failure can't be healed.
    /// Default ON — silence is how broken tool calls used to hide.
    /// (Actor-isolated; read/set via `notificationsEnabled`.)
    private var notifyOnUnhealed: Bool

    var notificationsEnabled: Bool { notifyOnUnhealed }

    /// Log path for the Settings view.
    nonisolated var failureLogPath: String { failuresLogURL.path }
    func setNotificationsEnabled(_ enabled: Bool) {
        notifyOnUnhealed = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.notify)
    }

    private enum Keys {
        static let notify = "toolGuardian.notifyOnUnhealed"
    }

    private var quirks: [String: QuirkProfile]  // modelID → profile (loaded at init)
    private var healCounts: [String: Int] = [:]       // "model|class|strategy" → heals
    private var lastEscalated: [String: Date] = [:]   // tool → last notification time
    private(set) var recentFailures: [FailureRecord] = []  // memory window for the stats tool

    private nonisolated var statsDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("SwiftMaestro", isDirectory: true)
    }
    private nonisolated var failuresLogURL: URL { statsDir.appendingPathComponent("tool-failures.jsonl") }
    private nonisolated var quirksURL: URL { statsDir.appendingPathComponent("model-quirks.json") }

    private init() {
        notifyOnUnhealed = UserDefaults.standard.object(forKey: Keys.notify) as? Bool ?? true
        // First-write initialization (actor rules: no assignment-after-default
        // in a nonisolated init, so quirks is declared without a default).
        var loaded: [String: QuirkProfile] = [:]
        let quirksFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftMaestro", isDirectory: true)
            .appendingPathComponent("model-quirks.json")
        if let data = try? Data(contentsOf: quirksFile),
           let decoded = try? JSONDecoder().decode([String: QuirkProfile].self, from: data) {
            loaded = decoded
        }
        quirks = loaded
    }

    // MARK: - Pre-execution: learned quirk application

    /// Apply the model's learned quirk profile to its tool-call arguments.
    /// Coerces string booleans/numbers to real JSON types when this model has
    /// previously needed it. No-op for models with no profile.
    func applyQuirks(_ argsJSON: String, tool: String, modelID: String) -> String {
        guard let profile = quirks[modelID],
              profile.boolAsString || profile.numbersAsStrings,
              let data = argsJSON.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return argsJSON }

        var changed = false
        for (key, value) in obj {
            guard let string = value as? String else { continue }
            if profile.boolAsString,
               let bool = ["true": true, "false": false][string.lowercased()] {
                obj[key] = bool
                changed = true
            } else if profile.numbersAsStrings,
                      let number = Double(string), string.range(of: #"^-?\d+(\.\d+)?$"#,
                      options: .regularExpression) != nil {
                obj[key] = number
                changed = true
            }
        }
        guard changed,
              let out = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: out, encoding: .utf8) else { return argsJSON }
        NSLog("[ToolGuardian] applied quirk profile for %@ on %@", modelID, tool)
        return json
    }

    // MARK: - Execution wrapper

    /// Run a tool call with classification, transient retry, recording, and
    /// recovery-hint enrichment. `execute` performs the actual dispatch.
    func run(
        name: String, argsJSON: String, modelID: String,
        execute: () async -> String
    ) async -> String {
        var result = await execute()
        guard let failureClass = classify(name: name, result: result) else {
            return result  // clean result — nothing to do
        }

        NSLog("[ToolGuardian] %@ failed (%@): %@", name, failureClass.rawValue,
              String(result.prefix(160)))

        // Transient environment failures: transparent retry with backoff.
        if failureClass == .transientEnv {
            for (attempt, delayMs) in [300, 900].enumerated() {
                try? await Task.sleep(for: .milliseconds(delayMs))
                result = await execute()
                guard let again = classify(name: name, result: result) else {
                    record(FailureRecord(
                        timestamp: Date(), tool: name, modelID: modelID,
                        failureClass: .transientEnv,
                        errorDigest: Self.digest(result), healed: true,
                        strategy: "backoff-retry-\(attempt + 1)"))
                    learn(modelID: modelID, failureClass: .transientEnv,
                          strategy: "backoff-retry")
                    return result
                }
                if again != .transientEnv { break }  // error changed class — stop retrying
            }
            // Retries exhausted: enrich so the model can route around it.
            result = enrich(result, tool: name, failureClass: .transientEnv)
            record(FailureRecord(
                timestamp: Date(), tool: name, modelID: modelID,
                failureClass: .transientEnv, errorDigest: Self.digest(result),
                healed: false, strategy: "backoff-retry"))
            escalate(tool: name, modelID: modelID, failureClass: .transientEnv, result: result)
            return result
        }

        // Everything else: no blind retry — enrich with a prescriptive hint.
        let enriched = enrich(result, tool: name, failureClass: failureClass)
        record(FailureRecord(
            timestamp: Date(), tool: name, modelID: modelID,
            failureClass: failureClass, errorDigest: Self.digest(result),
            healed: false, strategy: "hint"))
        escalate(tool: name, modelID: modelID, failureClass: failureClass, result: enriched)
        return enriched
    }
}

// MARK: - Classification, hints, learning, persistence

extension ToolCallGuardian {

    /// Does this tool result look like an error? Tool handlers report errors
    /// as "Error: ..." strings or JSON blobs with an "error" key.
    static func looksLikeError(_ result: String) -> Bool {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Error:") || trimmed.hasPrefix("error") { return true }
        // JSON error payloads: {"error": "..."} or {"status":"error"}
        guard trimmed.hasPrefix("{"), trimmed.count < 4_000 else { return false }
        return trimmed.contains("\"error\":") || trimmed.contains("\"status\":\"error\"")
            || trimmed.contains("\"status\": \"error\"")
    }

    /// Classify an error result. Nil = not an error (clean result).
    private func classify(name: String, result: String) -> FailureClass? {
        guard Self.looksLikeError(result) else { return nil }
        let text = result.lowercased()

        // Transient environment: worth a blind retry.
        let transientMarkers = [
            "timed out", "timeout", "sqlstate: 55", "database is locked",
            "sqlite_busy", "resource busy", "connection reset", "connection refused",
            "network", "temporarily unavailable", "try again", "busy",
            "could not connect", "econnreset", "econnrefused",
        ]
        if transientMarkers.contains(where: { text.contains($0) }) { return .transientEnv }

        // Blocking environment: retrying blindly won't help; needs a hint.
        let blockingMarkers = [
            "popup", "pop-up", "blocked", "permission denied", "not authorized",
            "not permitted", "access denied", "401", "403", "forbidden",
            "captcha", "rate limit", "too many requests",
        ]
        if blockingMarkers.contains(where: { text.contains($0) }) { return .blockingEnv }

        // Argument shape problems: the model emitted wrong/missing params.
        let argMarkers = [
            "is required", "requires '", "invalid arguments", "must be a json",
            "must be 0-5", "expected", "missing", "no usable", "unknown action",
            "invalid action", "not found at", "not in the maestrodam catalog",
        ]
        if argMarkers.contains(where: { text.contains($0) }) { return .argValidation }

        // Decode/parse failures of the tool call itself.
        if text.contains("decode") || text.contains("parse") || text.contains("malformed") {
            return .parse
        }
        return .unknown
    }

    /// Append a prescriptive recovery hint to an error result so the MODEL
    /// can route around the failure — the core of self-healing for small
    /// models that otherwise just give up or hallucinate success.
    private func enrich(_ result: String, tool: String, failureClass: FailureClass) -> String {
        guard let hint = Self.recoveryHint(tool: tool, failureClass: failureClass,
                                           result: result) else { return result }
        return result + "\n\nRecovery hint: " + hint
    }

    static func recoveryHint(tool: String, failureClass: FailureClass, result: String) -> String? {
        let text = result.lowercased()
        // Specific environment patterns first.
        if text.contains("popup") || text.contains("pop-up") || text.contains("blocked") {
            return "The site blocked the browser action. Fallbacks: use the no-JS fetch "
                + "(web_fetch/deep_fetch) for the same page, or the search tool instead of "
                + "clicking through. Do not retry the same browser action unchanged."
        }
        if text.contains("database is locked") || text.contains("sqlite_busy") {
            return "The database was busy and automatic retries didn't clear it. "
                + "Wait a moment and try the write once more; if it keeps failing, another "
                + "app or agent is holding the DB — report this to the user."
        }
        if text.contains("not found at") || text.contains("no such file") {
            return "The path doesn't exist. Use list_dir on the parent folder or "
                + "spotlight_search to find the real path before retrying — do not guess paths."
        }
        if text.contains("permission") || text.contains("not authorized") {
            return "Access was denied. The folder may not be in the user's authorized list — "
                + "ask the user to add it in Settings → Context, or work within the "
                + "already-authorized directories."
        }
        // Class-level fallbacks.
        switch failureClass {
        case .argValidation:
            return "Re-read the tool's parameter spec and retry with every required "
                + "parameter present and correctly typed (real JSON booleans/numbers, "
                + "not strings). If the call keeps failing, tell the user exactly which "
                + "parameter the tool rejected."
        case .transientEnv:
            return "Automatic retries didn't clear this. Check connectivity or whether "
                + "the target service is running, then try once more."
        case .blockingEnv:
            return "The environment is blocking this action (popups, permissions, rate "
                + "limit). Switch strategy: a different tool, a fetch-based path, or ask "
                + "the user to lift the block."
        case .parse:
            return "Your tool call payload was malformed. Re-emit it as strict, compact "
                + "JSON with double quotes and no trailing commas."
        case .toolBug, .unknown:
            return nil
        }
    }

    // MARK: Learning

    /// Count a heal; at 2 heals of the same (model, class, strategy), promote
    /// the corresponding normalizer into the model's pre-execution quirk
    /// profile so future calls never hit the failure at all.
    private func learn(modelID: String, failureClass: FailureClass, strategy: String) {
        let key = "\(modelID)|\(failureClass.rawValue)|\(strategy)"
        let count = (healCounts[key] ?? 0) + 1
        healCounts[key] = count
        guard count >= 2 else { return }

        var profile = quirks[modelID] ?? QuirkProfile()
        var promoted: String?
        // Currently the learnable coercions cover the arg-type family; parse
        // repairs (ToolArgumentRepair) already apply globally to every model.
        if failureClass == .argValidation {
            if !profile.boolAsString { profile.boolAsString = true; promoted = "boolAsString" }
            if !profile.numbersAsStrings { profile.numbersAsStrings = true; promoted = (promoted ?? "") + "+numbersAsStrings" }
        }
        guard let promoted else { return }
        profile.promotedAt = Date()
        profile.notes.append("Promoted \(promoted) after repeated healed \(failureClass.rawValue) failures")
        quirks[modelID] = profile
        saveQuirks()
        NSLog("[ToolGuardian] promoted quirk %@ for model %@", promoted, modelID)
    }

    // MARK: Recording + stats

    private func record(_ record: FailureRecord) {
        recentFailures.append(record)
        if recentFailures.count > 200 { recentFailures.removeFirst(recentFailures.count - 200) }
        guard let data = try? JSONEncoder().encode(record),
              let line = String(data: data, encoding: .utf8) else { return }
        try? FileManager.default.createDirectory(at: statsDir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: failuresLogURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try? Data((line + "\n").utf8).write(to: failuresLogURL)
        }
    }

    /// Stats snapshot for the self_healing_stats agent tool / future Settings view.
    func statsSummary() -> String {
        let total = recentFailures.count
        let healed = recentFailures.filter(\.healed).count
        var byClass: [String: Int] = [:]
        for record in recentFailures {
            byClass[record.failureClass.rawValue, default: 0] += 1
        }
        let classLine = byClass.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        let quirkLine = quirks.isEmpty
            ? "none learned yet"
            : quirks.map { "\($0.key): boolAsString=\($0.value.boolAsString) numbersAsStrings=\($0.value.numbersAsStrings)" }
                .joined(separator: "; ")
        return "Self-healing stats (session window): \(total) failures, \(healed) healed "
            + "(\(total > 0 ? healed * 100 / total : 0)% heal rate). "
            + "By class: \(classLine.isEmpty ? "none" : classLine). "
            + "Learned model quirks: \(quirkLine). "
            + "Full log: \(failuresLogURL.path)"
    }

    /// Recent failures for inspection (newest first).
    func recentFailuresText(limit: Int = 15) -> String {
        let items = recentFailures.suffix(limit).reversed()
        guard !items.isEmpty else { return "No tool failures recorded this session." }
        return items.map { record in
            "- [\(record.timestamp.formatted(date: .omitted, time: .standard))] "
                + "\(record.tool) (\(record.failureClass.rawValue)) on \(record.modelID) — "
                + "\(record.healed ? "healed via \(record.strategy)" : "NOT healed")"
        }.joined(separator: "\n")
    }

    // MARK: Escalation

    /// Watchdog-style notification for unhealed failures (throttled per tool).
    private func escalate(tool: String, modelID: String, failureClass: FailureClass, result: String) {
        guard notifyOnUnhealed else { return }
        if let last = lastEscalated[tool], Date().timeIntervalSince(last) < 15 * 60 { return }
        lastEscalated[tool] = Date()
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Maestro couldn't self-heal a tool call"
        content.body = "\(tool) failed (\(failureClass.rawValue)) on \(modelID). "
            + "The agent has the details — check the chat."
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "guardian-\(UUID().uuidString)", content: content, trigger: nil))
    }

    // MARK: Persistence (quirks)

    private func saveQuirks() {
        guard let data = try? JSONEncoder().encode(quirks) else { return }
        try? FileManager.default.createDirectory(at: statsDir, withIntermediateDirectories: true)
        try? data.write(to: quirksURL, options: .atomic)
    }

    /// Short digest of an error for log dedup (first 120 chars, normalized).
    static func digest(_ text: String) -> String {
        String(text.prefix(120))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }
}
