import Foundation

/// Persistent store for user-defined and built-in agent macros. Built-ins are
/// re-seeded on init so core workflows always exist; user macros are saved to
/// App Support and editable.
@Observable
@MainActor
final class MacroStore {
    private(set) var macros: [AgentMacro] = []

    private let fileURL: URL

    init() {
        self.fileURL = MacroStore.macroFileURL()
        load()
        ensureBuiltIns()
    }

    // MARK: - Queries

    func macros(for agentKind: AgentKind) -> [AgentMacro] {
        macros.filter { $0.agentKinds.isEmpty || $0.agentKinds.contains(agentKind) }
    }

    func macro(id: UUID) -> AgentMacro? {
        macros.first { $0.id == id }
    }

    // MARK: - Mutations

    @discardableResult
    func add(
        title: String,
        icon: String,
        prompt: String,
        agentKinds: [AgentKind] = []
    ) -> AgentMacro {
        let macro = AgentMacro(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            agentKinds: agentKinds
        )
        macros.append(macro)
        save()
        return macro
    }

    func update(
        id: UUID,
        title: String? = nil,
        icon: String? = nil,
        prompt: String? = nil,
        agentKinds: [AgentKind]? = nil,
        colorName: String? = nil
    ) {
        guard let idx = macros.firstIndex(where: { $0.id == id }) else { return }
        var macro = macros[idx]
        if let title { macro.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let icon { macro.icon = icon }
        if let prompt { macro.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let agentKinds { macro.agentKinds = agentKinds }
        if let colorName { macro.colorName = colorName }
        macros[idx] = macro
        save()
    }

    func delete(id: UUID) {
        guard let macro = macros.first(where: { $0.id == id }), !macro.isBuiltIn else { return }
        macros.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private func ensureBuiltIns() {
        var changed = false
        for builtIn in AgentMacro.builtInMacros {
            if !macros.contains(where: { $0.id == builtIn.id }) {
                macros.append(builtIn)
                changed = true
            }
        }
        if changed { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode([AgentMacro].self, from: data) else {
            macros = []
            return
        }
        macros = loaded
    }

    private func save() {
        let data: Data
        do {
            data = try JSONEncoder().encode(macros)
        } catch {
            NSLog("[PERSIST] macros ENCODE failed (%d macros): %@", macros.count, error.localizedDescription)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[PERSIST] macros WRITE failed to %@: %@", fileURL.path, error.localizedDescription)
        }
    }

    // MARK: - Paths

    nonisolated static func macroFileURL() -> URL {
        WorkspaceStore.dataDir().appendingPathComponent("macros.json")
    }
}
