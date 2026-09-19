import Foundation

// MARK: - User-taught redaction patterns
//
// Persisted regex strings that supplement the built-in PII patterns in
// DAMRedactionDetectorService. Patterns are stored as plain text so power
// users can edit them directly; invalid entries are skipped at detection time.

final class DAMCustomPatternStore: @unchecked Sendable {
    static let shared = DAMCustomPatternStore()

    private let filename = "custom-redaction-patterns.json"
    private let queue = DispatchQueue(label: "com.woodseedigi.swiftmaestro.customPatterns", qos: .utility)

    private var cachedPatterns: [String]?

    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SwiftMaestro", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".swiftmaestro")
        return base.appendingPathComponent(filename)
    }

    /// Load the saved custom patterns. Safe to call from any queue.
    func load() -> [String] {
        if let cached = cachedPatterns { return cached }

        let patterns: [String]
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([String].self, from: data)
            patterns = decoded.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        } catch {
            patterns = []
        }
        cachedPatterns = patterns
        return patterns
    }

    /// Save a list of custom patterns. Invalid-looking entries are still saved
    /// (the detector will ignore regexes that fail to compile).
    func save(_ patterns: [String]) {
        let cleaned = patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        cachedPatterns = cleaned

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let dir = self.url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(cleaned)
                try data.write(to: self.url, options: .atomic)
            } catch {
                NSLog("[DAMCustomPatternStore] failed to save: %@", error.localizedDescription)
            }
        }
    }
}
