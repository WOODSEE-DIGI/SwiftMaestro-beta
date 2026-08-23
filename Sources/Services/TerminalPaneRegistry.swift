import Foundation
import SwiftTerm

// MARK: - Terminal Pane Registry
//
// Long-lived terminal NSViews, keyed by pane ID and owned OUTSIDE the SwiftUI
// view tree. Splitting/closing/retheming restructures the SwiftUI layout,
// which would otherwise tear down and recreate each pane's NSView — killing
// the shell/serial process with it. The representables fetch (or create)
// their view here; processes are terminated only by explicit pane/tab close,
// never by SwiftUI layout churn.

final class TerminalPaneRegistry: @unchecked Sendable {
    static let shared = TerminalPaneRegistry()

    private var shellViews: [UUID: TappedLocalProcessTerminalView] = [:]
    private var serialViews: [UUID: TappedTerminalView] = [:]

    /// Fetch the existing view for a pane, or create one via `make`.
    func shellView(for paneID: UUID, make: () -> TappedLocalProcessTerminalView) -> TappedLocalProcessTerminalView {
        if let existing = shellViews[paneID] { return existing }
        let view = make()
        shellViews[paneID] = view
        return view
    }

    func serialView(for paneID: UUID, make: () -> TappedTerminalView) -> TappedTerminalView {
        if let existing = serialViews[paneID] { return existing }
        let view = make()
        serialViews[paneID] = view
        return view
    }

    /// Terminate the pane's process and drop its view (explicit close only).
    func terminate(_ paneID: UUID) {
        if let shell = shellViews.removeValue(forKey: paneID) {
            shell.terminate()
        }
        if let serial = serialViews.removeValue(forKey: paneID) {
            serial.serialSession?.close()
        }
    }
}
