import Foundation

// MARK: - LLM request/response debug logger

/// Writes a JSON log entry for every remote LLM request so we can measure
/// exactly where time is spent (request → first token → tool call → permission
/// prompt → execution). Logs live in `~/Library/Application Support/SwiftMaestro/logs/llm-requests/`.
enum LLMRequestLogger {
    private static let logDir = SwiftMaestroPaths.logsDir.appendingPathComponent("llm-requests", isDirectory: true)

    /// Record the request body and return a request ID used for follow-up timing logs.
    static func logRequest(modelID: String, body: [String: Any]) -> UUID {
        let id = UUID()
        ensureDirectory()
        let entry: [String: Any] = [
            "id": id.uuidString,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "model_id": modelID,
            "event": "request_sent",
            "body": redactSecrets(body),
        ]
        write(entry, id: id, suffix: "request")
        return id
    }

    static func logFirstToken(id: UUID, modelID: String) {
        logEvent(id: id, modelID: modelID, event: "first_token")
    }

    static func logToolCallReceived(id: UUID, modelID: String, name: String) {
        logEvent(id: id, modelID: modelID, event: "tool_call_received", extra: ["tool_name": name])
    }

    static func logRoundComplete(id: UUID, modelID: String, contentChars: Int, toolCount: Int, elapsedMs: Int) {
        logEvent(id: id, modelID: modelID, event: "round_complete", extra: [
            "content_chars": contentChars,
            "tool_count": toolCount,
            "elapsed_ms": elapsedMs,
        ])
    }

    private static func logEvent(id: UUID, modelID: String, event: String, extra: [String: Any] = [:]) {
        ensureDirectory()
        var entry: [String: Any] = [
            "id": id.uuidString,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "model_id": modelID,
            "event": event,
        ]
        for (k, v) in extra { entry[k] = v }
        write(entry, id: id, suffix: event)
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    private static func write(_ entry: [String: Any], id: UUID, suffix: String) {
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = logDir.appendingPathComponent("\(ts)-\(id.uuidString.prefix(8))-\(suffix).json")
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url)
    }

    /// Strip any resolved API keys that may have been serialized into the body.
    private static func redactSecrets(_ body: [String: Any]) -> [String: Any] {
        var copy = body
        if var messages = copy["messages"] as? [[String: Any]] {
            copy["messages"] = messages
        }
        return copy
    }
}
