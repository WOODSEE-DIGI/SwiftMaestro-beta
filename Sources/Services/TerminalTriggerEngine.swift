import AppKit
import Foundation

// MARK: - Terminal Trigger Engine
//
// iTerm2-style triggers: regex rules evaluated against completed lines of
// terminal output, firing a beep and/or a tab-badge alert. Output is tapped
// at the single choke point where process/serial bytes enter SwiftTerm
// (TappedLocalProcessTerminalView.dataReceived for shells, SerialSession's
// read pump for serial tabs), so rules fire regardless of which pane or tab
// produced the line.
//
// v1 actions: NSBeep (no permissions needed) + tab-chip badge via a callback
// the Terminal panel registers. UNUserNotification was considered but
// notifications from ad-hoc Debug builds are unreliable — revisit at Release.

/// One trigger rule.
struct TerminalTrigger: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Regular expression matched against each completed output line (after
    /// ANSI escape stripping).
    var pattern: String
    var isEnabled: Bool = true
    var beep: Bool = true
    var badge: Bool = true

    /// Compiled lazily; invalid patterns simply never match.
    var regex: NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [])
    }
}

@Observable
final class TerminalTriggerEngine: @unchecked Sendable {
    static let shared = TerminalTriggerEngine()

    var triggers: [TerminalTrigger] = [] { didSet { save() } }

    /// Registered by the Terminal panel: (tabID, trigger, matchedLine) → Void.
    /// Used to badge the tab chip until the user focuses that tab.
    var onBadge: ((UUID, TerminalTrigger, String) -> Void)?

    // MARK: - Output processing

    /// Per-pane partial-line buffers (output arrives in arbitrary chunks).
    private var lineBuffers: [UUID: String] = [:]
    private let lock = NSLock()

    /// Feed raw output bytes from one pane. `paneID` keys the line buffer;
    /// `tabID` is what gets badged. Safe from any thread.
    func processOutput(_ bytes: ArraySlice<UInt8>, pane: UUID, tab: UUID) {
        let text = Self.stripANSI(String(decoding: bytes, as: UTF8.self))

        lock.lock()
        var buffer = (lineBuffers[pane] ?? "") + text
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[..<newline]))
            buffer.removeFirst(buffer.distance(from: buffer.startIndex, to: newline) + 1)
        }
        lineBuffers[pane] = buffer
        let rules = triggers.filter { $0.isEnabled }
        lock.unlock()

        guard !rules.isEmpty, !lines.isEmpty else { return }

        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for rule in rules {
                guard let regex = rule.regex,
                      regex.firstMatch(in: line, range: range) != nil else { continue }
                fire(rule, line: line, tab: tab)
            }
        }
    }

    /// Drop a pane's buffer when its tab closes.
    func clearPane(_ pane: UUID) {
        lock.lock()
        lineBuffers[pane] = nil
        lock.unlock()
    }

    // MARK: - Firing

    private func fire(_ rule: TerminalTrigger, line: String, tab: UUID) {
        if rule.beep {
            DispatchQueue.main.async { NSSound.beep() }
        }
        if rule.badge {
            let callback = onBadge
            DispatchQueue.main.async { callback?(tab, rule, line) }
        }
    }

    // MARK: - ANSI stripping

    private static let ansiRegex: NSRegularExpression? = {
        // CSI sequences + OSC (…BEL or …ST) + single-char escapes.
        let pattern = "\\u{1B}\\[[0-9;?]*[A-Za-z@`]|\\u{1B}\\][^\\u{7}\\u{1B}]*(?:\\u{7}|\\u{1B}\\\\)|\\u{1B}[()][0-9A-B]|\\u{1B}[=>]"
        return try? NSRegularExpression(pattern: pattern)
    }()

    static func stripANSI(_ text: String) -> String {
        guard let regex = ansiRegex else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: ""
        )
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftMaestro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("terminal-triggers.json")
    }

    private init() {
        load()
    }

    private func save() {
        try? JSONEncoder().encode(triggers).write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([TerminalTrigger].self, from: data) else { return }
        triggers = decoded
    }
}

// MARK: - Output-tapped terminal view

#if canImport(SwiftTerm)
import SwiftTerm

/// LocalProcessTerminalView with an output tap: every process byte slice is
/// forwarded to the trigger engine before SwiftTerm renders it. Subclassing
/// the open `dataReceived` choke point keeps the vendored SwiftTerm pristine.
final class TappedLocalProcessTerminalView: LocalProcessTerminalView {
    /// (pane, tab) identifiers for trigger line-buffering + badging.
    var triggerPaneID: UUID?
    var triggerTabID: UUID?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if let pane = triggerPaneID, let tab = triggerTabID {
            TerminalTriggerEngine.shared.processOutput(slice, pane: pane, tab: tab)
        }
        super.dataReceived(slice: slice)
    }
}

/// Serial-tab terminal: plain SwiftTerm.TerminalView that OWNS its
/// SerialSession and its delegate proxy (so both survive SwiftUI layout churn
/// together with the pooled view).
///
/// Why a proxy instead of self-delegation: SwiftTerm.TerminalView is
/// MainActor-isolated while TerminalViewDelegate is not, so the view can't
/// conform cross-module in Swift 6 strict concurrency. A plain NSObject
/// delegate is exactly the pattern the shell tabs already use.
final class TappedTerminalView: SwiftTerm.TerminalView {
    var triggerPaneID: UUID?
    var triggerTabID: UUID?
    var serialSession: SerialSession?

    /// Strong ref keeps the delegate alive for the view's lifetime.
    var delegateProxy: SerialTerminalDelegate?
}

/// Nonisolated delegate for serial tabs; forwards keystrokes to the view's
/// SerialSession and opens links on the main thread.
final class SerialTerminalDelegate: NSObject, SwiftTerm.TerminalViewDelegate {
    weak var view: TappedTerminalView?

    init(view: TappedTerminalView) {
        self.view = view
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    /// Keystrokes from the terminal → the board.
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        view?.serialSession?.send(Array(data))
    }
}
#endif
