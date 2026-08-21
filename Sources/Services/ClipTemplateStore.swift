import Foundation

// MARK: - Clip Template Store
//
// Loads/saves user clip templates as JSON in Application Support. Ships with
// built-in defaults (Default, Research, YouTube) on first launch. Handles
// URL-pattern auto-matching so a clip on youtube.com picks the YouTube
// template automatically.

@MainActor
@Observable
final class ClipTemplateStore {
    static let shared = ClipTemplateStore()

    private(set) var templates: [ClipTemplate] = []
    /// Template ID the user last clipped with — pre-selected next time.
    var lastUsedTemplateID: UUID?

    private init() {
        load()
    }

    private var storeURL: URL {
        SwiftMaestroPaths.appSupportDir.appendingPathComponent("clip-templates.json")
    }

    private var lastUsedURL: URL {
        SwiftMaestroPaths.appSupportDir.appendingPathComponent("clip-templates-last-used")
    }

    func load() {
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([ClipTemplate].self, from: data),
           !decoded.isEmpty {
            templates = decoded
            // Merge in any built-ins added since the file was saved (e.g.
            // Forensics) — matched by name; user edits to a same-named
            // template win and nothing duplicates.
            let existingNames = Set(templates.map(\.name))
            let missing = ClipTemplate.builtIns.filter { !existingNames.contains($0.name) }
            if !missing.isEmpty {
                templates.append(contentsOf: missing)
                save()
            }
        } else {
            templates = ClipTemplate.builtIns
            save()
        }
        if let data = try? Data(contentsOf: lastUsedURL),
           let idString = String(data: data, encoding: .utf8),
           let id = UUID(uuidString: idString) {
            lastUsedTemplateID = id
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    func markUsed(_ template: ClipTemplate) {
        lastUsedTemplateID = template.id
        try? template.id.uuidString.write(to: lastUsedURL, atomically: true, encoding: .utf8)
    }

    // MARK: - CRUD

    func add(_ template: ClipTemplate) {
        templates.append(template)
        save()
    }

    func update(_ template: ClipTemplate) {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[index] = template
        save()
    }

    func delete(_ template: ClipTemplate) {
        templates.removeAll { $0.id == template.id }
        if templates.isEmpty { templates = [ClipTemplate.defaultTemplate] }
        save()
    }

    // MARK: - Matching

    /// Auto-match a template by URL. Priority: last-used template if it
    /// matches, otherwise first URL-pattern match, otherwise Default.
    func template(for url: String) -> ClipTemplate {
        if let lastID = lastUsedTemplateID,
           let last = templates.first(where: { $0.id == lastID }),
           last.matches(url: url) {
            return last
        }
        if let matched = templates.first(where: { $0.matches(url: url) }) {
            return matched
        }
        return templates.first(where: { $0.name == "Default" })
            ?? templates.first
            ?? ClipTemplate.defaultTemplate
    }
}
