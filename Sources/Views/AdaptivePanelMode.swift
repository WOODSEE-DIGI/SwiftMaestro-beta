import SwiftUI

// MARK: - Adaptive Panel Mode

/// Determines how the Agents / Apps launcher panels render their content
/// based on the available tile width. The mode is derived from the
/// `GeometryReader` width inside each panel, so resizing the tile
/// (or dragging it wide across the screen) automatically switches layout.
///
/// - **iconsOnly** (< 56 pt): Compact icon rail — just SF Symbols in a
///   vertical column. Useful when the panel is squeezed to a minimal dock.
/// - **iconsWithLabels** (56...200 pt): The current vertical list — icon +
///   label per row, sections collapsible. Default for typical narrow tiles.
/// - **horizontalColumns** (> 200 pt): Items flow into horizontal columns
///   across the panel width. Section headers become column dividers. Labels
///   sit below icons in a grid. Perfect for a wide, low panel stretched
///   across the top or bottom of the screen.
enum AdaptivePanelMode: Equatable {
    case iconsOnly
    case iconsWithLabels
    case horizontalColumns

    /// Derive the mode from an available width measurement (legacy, width-only).
    static func from(width: CGFloat) -> Self {
        if width < 56 { return .iconsOnly }
        if width < 200 { return .iconsWithLabels }
        return .horizontalColumns
    }

    /// Derive the mode from both width and height, using aspect ratio to
    /// determine orientation. A panel wider than tall = horizontal layout;
    /// a panel taller than wide = vertical layout.
    ///
    /// - **iconsOnly**: width < 56 pt (squeezed rail)
    /// - **iconsWithLabels**: taller than wide (vertical orientation → list)
    /// - **horizontalColumns**: wider than tall (horizontal orientation → grid)
    static func from(width: CGFloat, height: CGFloat) -> Self {
        if width < 56 { return .iconsOnly }
        // Use aspect ratio to determine orientation:
        // wider than tall → horizontal columns; taller than wide → vertical list
        if width > height { return .horizontalColumns }
        return .iconsWithLabels
    }

    /// Ideal icon size for the current mode.
    var iconSize: CGFloat {
        switch self {
        case .iconsOnly: return 20
        case .iconsWithLabels: return 16
        case .horizontalColumns: return 22
        }
    }

    /// Spacing between items in the current mode.
    var itemSpacing: CGFloat {
        switch self {
        case .iconsOnly: return 6
        case .iconsWithLabels: return 2
        case .horizontalColumns: return 8
        }
    }

    /// Whether to show text labels alongside icons.
    var showsLabels: Bool {
        switch self {
        case .iconsOnly: return false
        case .iconsWithLabels, .horizontalColumns: return true
        }
    }
}

// MARK: - Adaptive Layout Container

/// A container that measures its width via `GeometryReader` and passes the
/// resolved `AdaptivePanelMode` to its content builder. Panels wrap their
/// body in this so they can switch layouts reactively.
struct AdaptivePanelContainer<Content: View>: View {
    @ViewBuilder let content: (AdaptivePanelMode) -> Content

    var body: some View {
        GeometryReader { geo in
            content(AdaptivePanelMode.from(width: geo.size.width))
        }
    }
}
