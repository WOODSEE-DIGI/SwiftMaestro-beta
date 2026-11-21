import SwiftUI

/// Whether the current view is hosted inside a workspace panel (was a canvas
/// tile; now any panel rendered by `WorkspacePanelContentView`). Child panels
/// use this to avoid adding toolbar items that would fight with the panel's
/// own floating window header. Default is `false`; set to `true` when the
/// content is rendered inside `WorkspacePanelContentView`.
private struct WorkspaceEmbeddedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isWorkspaceEmbedded: Bool {
        get { self[WorkspaceEmbeddedKey.self] }
        set { self[WorkspaceEmbeddedKey.self] = newValue }
    }
}
