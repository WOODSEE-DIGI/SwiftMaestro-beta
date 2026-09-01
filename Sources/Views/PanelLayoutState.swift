import SwiftUI

// MARK: - Panel Type

/// Identifies each panel in the layout.
enum PanelType: String, CaseIterable, Identifiable, Codable, Sendable {
    case plans
    case chat
    case tasks
    // Terminal moved out of this per-agent chat panel system entirely â it's
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

/// A single panel in the layout â its type and whether it's floating.
struct PanelSlot: Identifiable, Equatable, Codable, Sendable {
    let type: PanelType
    var isFloating: Bool = false
    var id: String { type.id }
}

// MARK: - Panel Layout State

/// Observable state managing panel order, visibility, and floating status.
///
/// Each chat/agent window owns its own instance so showing or hiding the Plans
/// or Tasks panel in one window does not affect other windows. Only the
/// user-adjusted docked widths are persisted globally (they apply as defaults
/// to every new window).
@Observable
@MainActor
final class PanelLayoutState {

    /// Global shared instance for app-level panel layout access (e.g. menu bar,
    /// window creation). Per-window views may create their own local instances.
    static let shared = PanelLayoutState()

    /// Ordered list of panels in the main window.
    var mainSlots: [PanelSlot] = PanelType.allCases.map { PanelSlot(type: $0) }

    /// Which panels are currently floating (shown in separate windows).
    var floatingPanels: Set<PanelType> = []

    /// Visibility â some panels can be hidden entirely.
    var hiddenPanels: Set<PanelType> = []

    /// User-adjusted docked widths for fixed-width panels (drag-resized via
    /// `ResizablePanelHost`'s dividers). Panels not present here use their
    /// `PanelType.defaultWidth`. The flexible `chat` panel never appears here.
    var paneWidths: [PanelType: CGFloat] = [:]

    private let defaultsKey = "SwiftMaestro.PanelLayout"

    init() {
        loadWidths()
    }

    // MARK: - Pane Widths

    /// A two-way binding to a panel's docked width, backed by `paneWidths` and
    /// persisted on every change. Falls back to the panel's default width.
    func widthBinding(for panel: PanelType) -> Binding<CGFloat> {
        Binding(
            get: { self.paneWidths[panel] ?? panel.defaultWidth },
            set: { newValue in
                self.paneWidths[panel] = newValue
                self.saveWidths()
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
    }

    func isFloating(_ panel: PanelType) -> Bool {
        floatingPanels.contains(panel)
    }

    func float(_ panel: PanelType) {
        guard panel.supportsFloat else { return }
        floatingPanels.insert(panel)
    }

    func dock(_ panel: PanelType) {
        floatingPanels.remove(panel)
        if !mainSlots.contains(where: { $0.type == panel }) {
            mainSlots.append(PanelSlot(type: panel))
        }
    }

    // MARK: - Drag Reordering

    func movePanel(_ panel: PanelType, to newIndex: Int) {
        guard let oldIndex = mainSlots.firstIndex(where: { $0.type == panel }) else { return }
        let slot = mainSlots.remove(at: oldIndex)
        let adjustedIndex = newIndex > oldIndex ? newIndex - 1 : newIndex
        mainSlots.insert(slot, at: min(adjustedIndex, mainSlots.count))
    }

    // MARK: - Persistence (widths only)

    private func saveWidths() {
        let widthsByRawValue = Dictionary(uniqueKeysWithValues: paneWidths.map { ($0.key.rawValue, Double($0.value)) })
        UserDefaults.standard.set(widthsByRawValue, forKey: defaultsKey + ".paneWidths")
    }

    private func loadWidths() {
        if let widthsByRawValue = UserDefaults.standard.dictionary(forKey: defaultsKey + ".paneWidths") as? [String: Double] {
            paneWidths = Dictionary(uniqueKeysWithValues: widthsByRawValue.compactMap { key, value in
                PanelType(rawValue: key).map { ($0, CGFloat(value)) }
            })
        }
    }
}