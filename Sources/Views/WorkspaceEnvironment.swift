import SwiftUI

/// Whether the current view is hosted inside a workspace canvas tile.
/// `WorkspacePanelContainer` sets this to `true` so child panels can avoid
/// polluting the main window toolbar with their own `.toolbar` items.
private struct WorkspaceEmbeddedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isWorkspaceEmbedded: Bool {
        get { self[WorkspaceEmbeddedKey.self] }
        set { self[WorkspaceEmbeddedKey.self] = newValue }
    }
}
