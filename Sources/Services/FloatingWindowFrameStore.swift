import AppKit
import SwiftUI

// MARK: - Stored Frame

/// A panel window's saved frame: the exact global rect plus the display it
/// lived on, so a layout can be restored onto the same monitor — or clamped
/// onto a surviving one when that monitor is unplugged.
struct StoredFrame: Codable, Hashable, Sendable {
    /// `CGDirectDisplayID` of the screen the window was on (0 = unknown).
    var screenID: UInt32
    /// Window frame in global AppKit coordinates (origin at the primary
    /// display's bottom-left, y increasing upward).
    var frame: CGRect
}

// MARK: - Floating Window Frame Store
//
// Remembers where the user put every floating panel window, independently of
// the (now deprecated) canvas grid. Positions are recorded as windows are
// moved/resized and replayed when the panel reopens — so SwiftMaestro, like
// macOS itself, comes back exactly as the user left it.
//
// Design notes:
// - Windows are identified by `NSWindow.identifier`
//   ("<prefix><WorkspacePanelKind.storageKey>"), so the store can recognise
//   its own panels among `NSApp.windows` without holding references.
// - Cocoa frame autosave stays disabled (see `WindowSizeConfigurator` — it
//   once restored an unusably tiny frame after a crash). This store is the
//   single source of truth instead, which also gives us named workspace
//   layouts on top of plain "remember where I put things".
// - Multi-instance panels (Terminal) share one `storageKey`, so they opt out
//   entirely: restoring one frame would stack every instance in the same
//   spot, and recording would fight between instances.
@MainActor
final class FloatingWindowFrameStore {

    static let shared = FloatingWindowFrameStore()

    /// Namespace prefix for `NSWindow.identifier` values this store owns.
    static let identifierPrefix = "workspace-panel:"

    private let defaultsKey = "SwiftMaestro.WindowFrames"
    private let saveDebounce: Duration = .milliseconds(500)

    /// key (`WorkspacePanelKind.storageKey`) → saved frame.
    private(set) var frames: [String: StoredFrame] = [:]

    private var saveTask: Task<Void, Never>?
    private var observersInstalled = false

    /// Windows that already had a saved frame claimed this session — the
    /// cascade pass must not move them afterwards. Weak, so closed windows
    /// drop out automatically (avoids ObjectIdentifier address reuse).
    private let restoredWindows = NSHashTable<NSWindow>.weakObjects()

    private init() {
        load()
        installObservers()
    }

    // MARK: - Keys

    /// The frame-store key for a panel, or nil when the panel should not
    /// participate (multi-instance kinds such as Terminal).
    static func frameRestoreKey(for kind: WorkspacePanelKind) -> String? {
        if case .terminal = kind { return nil }
        return kind.storageKey
    }

    /// Per-view-mode key for the Apps launcher so List, Grid, and Icons each
    /// remember their own size and position.
    static func launcherModeKey(_ mode: AppsLauncherPanel.ViewMode) -> String {
        "appLauncher.mode.\(mode.rawValue)"
    }

    /// The store key encoded into a window's identifier, if it is one of ours.
    private static func key(for window: NSWindow) -> String? {
        guard let raw = window.identifier?.rawValue,
              raw.hasPrefix(identifierPrefix) else { return nil }
        let key = String(raw.dropFirst(identifierPrefix.count))
        return key.isEmpty ? nil : key
    }

    // MARK: - Restore

    func hasFrame(for key: String) -> Bool {
        frames[key] != nil
    }

    /// Claim the saved frame for this window before the cascade pass runs.
    /// Returns true when a saved frame exists — the caller should then apply
    /// it (the cascade will skip a claimed window).
    func claimRestore(window: NSWindow, key: String) -> Bool {
        guard frames[key] != nil else { return false }
        restoredWindows.add(window)
        return true
    }

    func didRestore(_ window: NSWindow) -> Bool {
        restoredWindows.contains(window)
    }

    /// The frame a panel should open at: the saved rect resolved onto a
    /// live display and clamped to that display's visible area and the
    /// panel's minimum size. Nil when nothing is saved.
    func resolvedFrame(for key: String, kind: WorkspacePanelKind) -> CGRect? {
        guard let stored = frames[key] else { return nil }

        let screen = screen(matching: stored.screenID) ?? bestScreen(for: stored.frame)
        let visible = screen.visibleFrame
        let minSize = kind.floatingMinSize

        var rect = stored.frame
        // Never smaller than the panel's floor…
        rect.size.width = max(rect.size.width, minSize.width)
        rect.size.height = max(rect.size.height, minSize.height)
        // …and never larger than the display it is going onto.
        rect.size.width = min(rect.size.width, visible.width)
        rect.size.height = min(rect.size.height, visible.height)

        // Keep the whole window on the display it belongs to. The rect is in
        // global coordinates, so clamping min/max works regardless of which
        // way y runs relative to this screen.
        if rect.maxX > visible.maxX { rect.origin.x = visible.maxX - rect.size.width }
        if rect.minX < visible.minX { rect.origin.x = visible.minX }
        if rect.maxY > visible.maxY { rect.origin.y = visible.maxY - rect.size.height }
        if rect.minY < visible.minY { rect.origin.y = visible.minY }
        return rect
    }

    /// Apply the saved frame to a window. Returns true if one was applied.
    @discardableResult
    func apply(to window: NSWindow, key: String, kind: WorkspacePanelKind) -> Bool {
        guard let rect = resolvedFrame(for: key, kind: kind) else { return false }
        window.setFrame(rect, display: true, animate: false)
        restoredWindows.add(window)
        return true
    }

    /// Apply a centered default frame for a panel that has no saved frame.
    /// Used for the launch windows whose default sizes are intentional
    /// (Agents, Apps launcher); other panels cascade instead.
    @discardableResult
    func applyDefaultFrame(to window: NSWindow, key: String, kind: WorkspacePanelKind) -> Bool {
        let size = NSSize(
            width: kind.floatingDefaultSize.width,
            height: kind.floatingDefaultSize.height)
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        var rect = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height)
        // Clamp to the visible frame so the default never opens off-screen.
        if rect.maxX > visible.maxX { rect.origin.x = visible.maxX - rect.size.width }
        if rect.minX < visible.minX { rect.origin.x = visible.minX }
        if rect.maxY > visible.maxY { rect.origin.y = visible.maxY - rect.size.height }
        if rect.minY < visible.minY { rect.origin.y = visible.minY }

        window.setFrame(rect, display: true, animate: false)
        restoredWindows.add(window)
        return true
    }

    // MARK: - Apps Launcher Mode Frames

    /// Apply the saved frame for an Apps launcher view mode. If the user has
    /// never positioned that mode, snap it to the appropriate screen edge
    /// instead.
    @discardableResult
    func applyLauncherModeFrame(
        to window: NSWindow,
        mode: AppsLauncherPanel.ViewMode
    ) -> Bool {
        let key = Self.launcherModeKey(mode)
        if hasFrame(for: key) {
            return apply(to: window, key: key, kind: .appLauncher)
        }
        let rect = snapFrame(for: mode, window: window)
        window.setFrame(rect, display: true, animate: true)
        restoredWindows.add(window)
        return true
    }

    /// Default snap frame for an Apps launcher mode. List snaps to the nearest
    /// left/right edge as a tall narrow panel; Grid and Icons snap to the
    /// nearest top/bottom edge as a wide/short panel.
    private func snapFrame(
        for mode: AppsLauncherPanel.ViewMode,
        window: NSWindow
    ) -> NSRect {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let padding: CGFloat = 8
        let current = window.frame

        switch mode {
        case .list, .automatic:
            let width: CGFloat = 280
            let height = min(visible.height * 0.85, max(520, visible.height * 0.6))
            let x = current.midX < visible.midX
                ? visible.minX + padding
                : visible.maxX - width - padding
            var y = current.midY - height / 2
            y = max(visible.minY, min(visible.maxY - height, y))
            return NSRect(x: x, y: y, width: width, height: height)
        case .grid:
            let height: CGFloat = 520
            let width = min(1200, visible.width * 0.9)
            let y = current.midY < visible.midY
                ? visible.minY + padding
                : visible.maxY - height - padding
            var x = current.midX - width / 2
            x = max(visible.minX, min(visible.maxX - width, x))
            return NSRect(x: x, y: y, width: width, height: height)
        case .icon:
            let size = NSSize(width: 320, height: 220)
            let y = current.midY < visible.midY
                ? visible.minY + padding
                : visible.maxY - size.height - padding
            var x = current.midX - size.width / 2
            x = max(visible.minX, min(visible.maxX - size.width, x))
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }
    }

    /// Re-apply saved frames to every currently open panel window that has
    /// one. Used after a workspace-layout preset is recalled.
    func applyToOpenWindows(kinds: [WorkspacePanelKind]) {
        for kind in kinds {
            guard let key = Self.frameRestoreKey(for: kind),
                  hasFrame(for: key),
                  let window = NSApp.windows.first(where: {
                      $0.identifier?.rawValue == Self.identifierPrefix + key
                  }) else { continue }
            apply(to: window, key: key, kind: kind)
        }
    }

    // MARK: - Record

    /// Record a window's current frame under its key (debounced write).
    func record(window: NSWindow, key: String) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let stored = StoredFrame(screenID: Self.screenID(of: screen), frame: window.frame)
        guard frames[key] != stored else { return }
        frames[key] = stored
        scheduleSave()
    }

    // MARK: - Presets

    /// Snapshot the saved frames for the given panels (workspace-layout save).
    func snapshot(kinds: [WorkspacePanelKind]) -> [String: StoredFrame] {
        var snapshot: [String: StoredFrame] = [:]
        for kind in kinds {
            guard let key = Self.frameRestoreKey(for: kind), let stored = frames[key] else { continue }
            snapshot[key] = stored
        }
        return snapshot
    }

    /// Replace the store with a preset's frames and re-apply them to open
    /// panels. An empty snapshot (the built-in presets predate frame
    /// storage) leaves current positions untouched.
    func restore(_ snapshot: [String: StoredFrame], applyingToOpenPanels kinds: [WorkspacePanelKind]) {
        guard !snapshot.isEmpty else { return }
        frames = snapshot
        persistNow()
        applyToOpenWindows(kinds: kinds)
    }

    /// Forget every saved position (Window menu → "Reset Window Positions").
    func resetAll() {
        frames = [:]
        saveTask?.cancel()
        saveTask = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// One-time migration: the Agents and Apps launcher default sizes changed
    /// (narrower Agents, wider Apps). Clear any previously saved frames for
    /// those two windows so the new defaults take effect on next launch.
    /// V2 clears frames again after the Apps launcher switched to a wide
    /// horizontal-grid default (1100x520).
    func migrateLauncherFramesIfNeeded() {
        let key = defaultsKey + ".launcherResizeV2.done"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for storageKey in ["agents", "appLauncher"] {
            frames.removeValue(forKey: storageKey)
        }
        persistNow()
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: - Displays

    private static func screenID(of screen: NSScreen) -> UInt32 {
        // `NSScreenNumber` is the AppKit device-description key holding the
        // screen's `CGDirectDisplayID`. Built from the raw string because the
        // typed-enum static member isn't visible to this target.
        let key = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    private func screen(matching id: UInt32) -> NSScreen? {
        guard id != 0 else { return nil }
        return NSScreen.screens.first { Self.screenID(of: $0) == id }
    }

    /// Best display for a saved rect when its original screen is gone:
    /// the one sharing the most area with it, else the nearest by centre
    /// distance, else the main display.
    private func bestScreen(for rect: CGRect) -> NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main ?? NSScreen.screens[0] }

        var bestArea: CGFloat = -1
        var best: NSScreen?
        for screen in screens {
            let overlap = rect.intersection(screen.frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        if bestArea > 0, let best { return best }

        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return screens.min(by: { a, b in
            distanceSquared(centre, a.frame) < distanceSquared(centre, b.frame)
        }) ?? (NSScreen.main ?? screens[0])
    }

    private func distanceSquared(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [saveDebounce] in
            try? await Task.sleep(for: saveDebounce)
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    private func persistNow() {
        guard let data = try? JSONEncoder().encode(frames) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        persistNow()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        if let decoded = try? JSONDecoder().decode([String: StoredFrame].self, from: data) {
            frames = decoded
        } else {
            // Don't silently wipe the user's saved positions if the schema
            // drifted — keep the raw blob for diagnostics.
            UserDefaults.standard.set(data, forKey: defaultsKey + ".corrupt")
            print("FloatingWindowFrameStore: failed to decode saved frames. Corrupt data preserved at \(defaultsKey).corrupt")
        }
    }

    // MARK: - Observation

    /// One pair of app-wide observers (not per window) keyed off the window
    /// identifier — no per-window tokens to leak when panels close.
    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default

        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self.noteWindowChanged(window) }
            }
        }
        // Write through immediately on quit so the last position survives.
        center.addObserver(forName: NSApplication.willTerminateNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func noteWindowChanged(_ window: NSWindow) {
        guard let key = Self.key(for: window) else { return }
        record(window: window, key: key)
    }
}

// MARK: - Window Frame Configurator

/// Attaches frame persistence to a floating panel window: tags the window
/// with its panel key, claims + applies any saved frame (beating the cascade
/// pass), and thereafter the store's app-wide observers record its position.
/// Restores are idempotent — `viewDidMoveToWindow` can fire more than once.
struct WindowFrameConfigurator: NSViewRepresentable {
    let kind: WorkspacePanelKind
    /// The Apps launcher view mode, when this panel is the Apps launcher.
    /// Used to store and restore a separate frame per mode.
    var appsViewMode: AppsLauncherPanel.ViewMode? = nil

    func makeNSView(context: Context) -> FrameTaggingView {
        let view = FrameTaggingView()
        view.kind = kind
        view.appsViewMode = appsViewMode
        return view
    }

    func updateNSView(_ nsView: FrameTaggingView, context: Context) {
        let previousMode = nsView.appsViewMode
        nsView.kind = kind
        nsView.appsViewMode = appsViewMode
        if kind == .appLauncher,
           let mode = appsViewMode,
           previousMode != mode {
            nsView.applyLauncherModeFrame(mode: mode)
        }
    }

    final class FrameTaggingView: NSView {
        var kind: WorkspacePanelKind?
        var appsViewMode: AppsLauncherPanel.ViewMode?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let kind else { return }

            if kind == .appLauncher, let mode = appsViewMode {
                applyLauncherModeFrame(mode: mode)
                return
            }

            guard let key = FloatingWindowFrameStore.frameRestoreKey(for: kind) else { return }

            window.identifier = NSUserInterfaceItemIdentifier(
                FloatingWindowFrameStore.identifierPrefix + key)

            let store = FloatingWindowFrameStore.shared
            // Claim synchronously so `WindowCascadeConfigurator` (which fires
            // on a 50 ms delay) sees the window as already positioned.
            if kind == .agents {
                // Agents control centre: always open at the intentional default
                // size. It is not a user-resizable-persistent panel.
                _ = store.claimRestore(window: window, key: key)
                store.applyDefaultFrame(to: window, key: key, kind: kind)
            } else if store.claimRestore(window: window, key: key) {
                // Apply immediately, then once more after SwiftUI's own window
                // frame restoration has had a chance to run — otherwise a late
                // restore from the system can overwrite the position we just
                // applied and the panel comes back where macOS last saw it
                // rather than where the user put it.
                applySavedFrame(to: window, key: key, kind: kind)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak window] in
                    guard let window else { return }
                    self.applySavedFrame(to: window, key: key, kind: kind)
                }
            } else if kind == .appLauncher {
                // No saved frame for the Apps launcher — apply its intentional
                // default size so the new horizontal grid is visible.
                store.applyDefaultFrame(to: window, key: key, kind: kind)
            }
        }

        func applyLauncherModeFrame(mode: AppsLauncherPanel.ViewMode) {
            guard let window, let kind, kind == .appLauncher else { return }
            let key = FloatingWindowFrameStore.launcherModeKey(mode)
            window.identifier = NSUserInterfaceItemIdentifier(
                FloatingWindowFrameStore.identifierPrefix + key)
            FloatingWindowFrameStore.shared.applyLauncherModeFrame(to: window, mode: mode)
        }

        private func applySavedFrame(to window: NSWindow, key: String, kind: WorkspacePanelKind) {
            _ = FloatingWindowFrameStore.shared.apply(to: window, key: key, kind: kind)
        }
    }
}
