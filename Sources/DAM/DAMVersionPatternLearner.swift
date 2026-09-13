import Foundation

// MARK: - Version pattern model

/// A stored regex used to strip version suffixes from filenames.
struct DAMVersionPattern: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var regex: String
    var example: String

    init(id: UUID = UUID(), regex: String, example: String) {
        self.id = id
        self.regex = regex
        self.example = example
    }
}

// MARK: - Pattern store

/// Persists learned version-suffix patterns in UserDefaults.
@MainActor
@Observable
final class DAMVersionPatternStore {
    static let shared = DAMVersionPatternStore()

    private let key = "dam.versionPatterns"
    var patterns: [DAMVersionPattern] = []

    private init() {
        load()
        if patterns.isEmpty {
            patterns = DAMVersionPatternStore.defaultPatterns
        }
    }

    func add(_ pattern: DAMVersionPattern) {
        guard !patterns.contains(where: { $0.regex == pattern.regex }) else { return }
        patterns.append(pattern)
        save()
    }

    func remove(_ pattern: DAMVersionPattern) {
        patterns.removeAll { $0.id == pattern.id }
        save()
    }

    func resetToDefaults() {
        patterns = DAMVersionPatternStore.defaultPatterns
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(patterns) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([DAMVersionPattern].self, from: data)
        else { return }
        patterns = decoded
    }

    static let defaultPatterns: [DAMVersionPattern] = [
        DAMVersionPattern(regex: #"(?i)_v\\d+"#, example: "photo_v01.jpg → photo.jpg"),
        DAMVersionPattern(regex: #"(?i)_\\d+"#, example: "photo_01.jpg → photo.jpg"),
        DAMVersionPattern(regex: #"(?i)_final"#, example: "photo_final.jpg → photo.jpg"),
        DAMVersionPattern(regex: #"(?i)_v\\d+_\\w+"#, example: "photo_v01_edit.jpg → photo.jpg"),
    ]
}

// MARK: - Learner

/// Analyzes a folder of versioned files and discovers regexes that strip the
/// version tokens. The discovered patterns are stored and reused when scanning
/// the whole catalog for version sets.
enum DAMVersionPatternLearner {

    /// Candidate regexes to test against filenames. The learner tries each one
    /// and keeps those that produce the most version groups.
    private static let candidateRegexes: [String] = [
        #"(?i)_v\\d+"#,
        #"(?i)_\\d+"#,
        #"(?i)_final"#,
        #"(?i)_v\\d+_\\w+"#,
        #"(?i)[-_ ]v\\d+"#,
        #"(?i)[-_ ]version\\d+"#,
    ]

    /// Scans `folderPath` and returns patterns that successfully grouped files
    /// into version sets. The returned patterns are also added to the store.
    static func learn(from folderPath: String) async -> [DAMVersionPattern] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: folderPath) else { return [] }

        var filenames: [String] = []
        while let path = enumerator.nextObject() as? String {
            var isDir: ObjCBool = false
            let fullPath = (folderPath as NSString).appendingPathComponent(path)
            if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue {
                filenames.append((path as NSString).lastPathComponent)
            }
        }

        var usefulPatterns: [DAMVersionPattern] = []

        for regexString in candidateRegexes {
            guard let regex = try? NSRegularExpression(pattern: regexString, options: []) else { continue }
            var groupCounts: [String: Int] = [:]
            for filename in filenames {
                let base = baseName(for: filename, using: regex)
                groupCounts[base, default: 0] += 1
            }
            let groupsFormed = groupCounts.values.filter { $0 > 1 }.count
            guard groupsFormed > 0 else { continue }

            let example = groupCounts
                .filter { $0.value > 1 }
                .keys
                .prefix(2)
                .joined(separator: ", ")
            let pattern = DAMVersionPattern(regex: regexString, example: "\(example) (\(groupsFormed) groups)")
            await MainActor.run {
                DAMVersionPatternStore.shared.add(pattern)
            }
            usefulPatterns.append(pattern)
        }

        return usefulPatterns
    }

    /// Strips the first matching version pattern from a filename and returns
    /// a stable base key including the extension.
    static func baseName(for filename: String, using patterns: [DAMVersionPattern]) -> String {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern.regex, options: []) else { continue }
            let base = baseName(for: filename, using: regex)
            if base != filename { return base }
        }
        return filename
    }

    private static func baseName(for filename: String, using regex: NSRegularExpression) -> String {
        let ext = (filename as NSString).pathExtension
        let basename = (filename as NSString).deletingPathExtension
        let range = NSRange(basename.startIndex..., in: basename)
        let stripped = regex.stringByReplacingMatches(in: basename, options: [], range: range, withTemplate: "")
        let normalized = stripped.trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
        return ext.isEmpty ? normalized : "\(normalized).\(ext)"
    }
}
