import SwiftUI

// MARK: - Panel Type

/// Identifies each panel in the layout.
enum PanelType: String, CaseIterable, Identifiable, Codable, Sendable {
    case plans
    case chat
    case tasks
    case terminal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plans: return "Plans"
        case .chat: return "Chat"
        case .tasks: return "Tasks"
        case .terminal: return "Terminal"
        }
    }

    var icon: String {
        switch self {
        case .plans: return "list.bullet.rectangle"
        case .chat: return "bubble.left.and.bubble.right"
        case .tasks: return "checklist"
        case .terminal: return "terminal"
        }
    }

    /// Whether this panel can be popped out to a floating window.
    var supportsFloat: Bool {
        switch self {
        case .plans, .tasks, .terminal: return true
        case .chat: return false
        }
    }
}

// MARK: - Panel Slot

/// A single panel in the layout — its type and whether it's floating.
struct PanelSlot: Identifiable, Equatable, Codable, Sendable {
    let type: PanelType
    var isFloating: Bool = false
    var id: String { type.id }
}

// MARK: - Panel Layout State

/// Observable state managing panel order, visibility, and floating status.
/// Persisted to UserDefaults so layout survives relaunch.
@Observable
@MainActor
final class PanelLayoutState {

    static let shared = PanelLayoutState()

    /// Ordered list of panels in the main window.
    var mainSlots: [PanelSlot] = []

    /// Which panels are currently floating (shown in separate windows).
    var floatingPanels: Set<PanelType> = []

    /// Visibility — some panels can be hidden entirely.
    var hiddenPanels: Set<PanelType> = []

    private let defaultsKey = "SwiftMaestro.PanelLayout"

    init() {
        load()
    }

    // MARK: - Panel Management

    func toggleVisibility(_ panel: PanelType) {
        if hiddenPanels.contains(panel) {
            hiddenPanels.remove(panel)
        } else {
            hiddenPanels.insert(panel)
        }
        save()
    }

    func isFloating(_ panel: PanelType) -> Bool {
        floatingPanels.contains(panel)
    }

    func float(_ panel: PanelType) {
        guard panel.supportsFloat else { return }
        floatingPanels.insert(panel)
        save()
    }

    func dock(_ panel: PanelType) {
        floatingPanels.remove(panel)
        if !mainSlots.contains(where: { $0.type == panel }) {
            mainSlots.append(PanelSlot(type: panel))
        }
        save()
    }

    // MARK: - Drag Reordering

    func movePanel(_ panel: PanelType, to newIndex: Int) {
        guard let oldIndex = mainSlots.firstIndex(where: { $0.type == panel }) else { return }
        let slot = mainSlots.remove(at: oldIndex)
        let adjustedIndex = newIndex > oldIndex ? newIndex - 1 : newIndex
        mainSlots.insert(slot, at: min(adjustedIndex, mainSlots.count))
        save()
    }

    // MARK: - Persistence

    private func save() {
        let data = try? JSONEncoder().encode(mainSlots)
        UserDefaults.standard.set(data, forKey: defaultsKey + ".mainSlots")
        UserDefaults.standard.set(Array(floatingPanels.map(\.rawValue)), forKey: defaultsKey + ".floating")
        UserDefaults.standard.set(Array(hiddenPanels.map(\.rawValue)), forKey: defaultsKey + ".hidden")
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey + ".mainSlots"),
           let slots = try? JSONDecoder().decode([PanelSlot].self, from: data) {
            mainSlots = slots
        } else {
            mainSlots = PanelType.allCases.map { PanelSlot(type: $0) }
        }

        if let floating = UserDefaults.standard.stringArray(forKey: defaultsKey + ".floating") {
            floatingPanels = Set(floating.compactMap(PanelType.init))
        }

        if let hidden = UserDefaults.standard.stringArray(forKey: defaultsKey + ".hidden") {
            hiddenPanels = Set(hidden.compactMap(PanelType.init))
        }
    }
}
