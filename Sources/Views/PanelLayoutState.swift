import SwiftUI

// MARK: - Panel Type

/// Identifies each panel in the layout.
enum PanelType: String, CaseIterable, Identifiable, Codable, Sendable {
    case plans
    case chat
    case tasks
    // Terminal moved out of this per-agent chat panel system entirely — it's
    // now a top-level `WorkspacePanelKind.terminal` under "Swift Apps",
    // openable/dockable/floatable independent of any specific agent's chat.

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plans: return "Plans"
        case .chat: return "Chat"
        case .tasks: return "Tasks"
        }
    }

    var icon: String {
        switch self {
        case .plans: return "list.bullet.rectangle"
        case .chat: return "bubble.left.and.bubble.right"
        case .tasks: return "checklist"
        }
    }

    /// Whether this panel can be popped out to a floating window.
    var supportsFloat: Bool {
        switch self {
        case .plans, .tasks: return true
        case .chat: return false
        }
    }

    /// Default docked width before the user drags a divider. `chat` is always
    /// flexible and ignores width entirely.
    var defaultWidth: CGFloat { 280 }
    /// Minimum docked width a divider drag can shrink this panel to.
    var minWidth: CGFloat { 200 }
    /// Maximum docked width a divider drag can grow this panel to.
    var maxWidth: CGFloat { 520 }
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

    /// User-adjusted docked widths for fixed-width panels (drag-resized via
    /// `ResizablePanelHost`'s dividers). Panels not present here use their
    /// `PanelType.defaultWidth`. The flexible `chat` panel never appears here.
    var paneWidths: [PanelType: CGFloat] = [:]

    private let defaultsKey = "SwiftMaestro.PanelLayout"

    init() {
        load()
    }

    // MARK: - Pane Widths

    /// A two-way binding to a panel's docked width, backed by `paneWidths` and
    /// persisted on every change. Falls back to the panel's default width.
    func widthBinding(for panel: PanelType) -> Binding<CGFloat> {
        Binding(
            get: { self.paneWidths[panel] ?? panel.defaultWidth },
            set: { newValue in
                self.paneWidths[panel] = newValue
                self.save()
            }
        )
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

        let widthsByRawValue = Dictionary(uniqueKeysWithValues: paneWidths.map { ($0.key.rawValue, Double($0.value)) })
        UserDefaults.standard.set(widthsByRawValue, forKey: defaultsKey + ".paneWidths")
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

        if let widthsByRawValue = UserDefaults.standard.dictionary(forKey: defaultsKey + ".paneWidths") as? [String: Double] {
            paneWidths = Dictionary(uniqueKeysWithValues: widthsByRawValue.compactMap { key, value in
                PanelType(rawValue: key).map { ($0, CGFloat(value)) }
            })
        }
    }
}
