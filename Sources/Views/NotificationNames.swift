import Foundation

extension Notification.Name {
    static let openInMaestroDAM = Notification.Name("openInMaestroDAM")
    static let sendToMaestroDB = Notification.Name("sendToMaestroDB")
    /// A workspace-layout preset was recalled. The open-panel set just changed
    /// wholesale, so every panel in the new layout needs its window
    /// (re)presented and any panel that dropped out closes itself.
    static let workspaceLayoutRecalled = Notification.Name("workspaceLayoutRecalled")
}
