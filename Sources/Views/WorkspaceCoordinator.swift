import AppKit
import SwiftUI

// MARK: - Active Sheet

/// The single modal sheet the app is currently presenting.
///
/// SwiftUI only honours ONE `.sheet` modifier per view; stacking two (for
/// example new-agent + onboarding) silently drops one, which previously
/// suppressed the first-run model picker. Everything funnels through one enum
/// so every sheet can present in turn. It lives on the coordinator (not a
/// view) because the requests arrive as notifications from anywhere in the
/// app — including places with no view of their own.
enum WorkspaceActiveSheet: Identifiable {
    case newAgent
    case onboarding
    case welcome
    case setup
    case whisperSetup
    case notesOnboarding
    case agentCategory(AgentRecord)
    case diagnosticReport(description: String, mediaPath: String)
    case savePreset

    var id: Int {
        switch self {
        case .newAgent: return 1
        case .onboarding: return 2
        case .welcome: return 0
        case .setup: return 6
        case .whisperSetup: return 3
        case .notesOnboarding: return 4
        case .agentCategory(let agent): return 5 + agent.id.hashValue
        case .diagnosticReport: return 7
        case .savePreset: return 8
        }
    }
}

// MARK: - Workspace Coordinator

/// Process-wide coordinator for "open this panel" and "show this sheet"
/// requests.
///
/// The canvas-free workspace is a bag of floating `NSWindow`s, so there is no
/// longer a single always-on window to hang `NotificationCenter` observers
/// off. This singleton owns them instead: it observes the app's panel/sheet
/// notifications directly (no view required) and turns them into window
/// presentations through an `openWindow` closure bound by whichever live view
/// currently has one (the Agents window and the Window menu both bind it).
///
/// Sheets are different: they need a real view to attach to. The Agents
/// window is the app's control centre and hosts them; when it isn't on
/// screen a sheet request reopens it first and then presents.
@MainActor
@Observable
final class WorkspaceCoordinator {

    static let shared = WorkspaceCoordinator()

    /// The sheet to present in the Agents window, if any.
    var activeSheet: WorkspaceActiveSheet?

    /// True while the Agents window is on screen. Set by that window's
    /// appear/disappear callbacks.
    var isAgentsWindowPresented = false

    /// Opens a panel's floating window. Bound by the Agents window and the
    /// Window menu — either is enough, so requests keep working even when the
    /// other is gone.
    private var openWindow: ((WorkspacePanelKind) -> Void)?

    private var observersInstalled = false

    private init() {}

    // MARK: - Binding

    func bindOpenWindow(_ closure: @escaping (WorkspacePanelKind) -> Void) {
        openWindow = closure
    }

    // MARK: - Observers

    /// Install the notification observers once. Idempotent, so every live
    /// view can call it from `onAppear` without stacking duplicates.
    func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default

        center.addObserver(
            forName: .openWorkspacePanel, object: nil, queue: .main
        ) { [weak self] notification in
            guard let kind = notification.object as? WorkspacePanelKind else { return }
            MainActor.assumeIsolated { self?.openPanel(kind) }
        }

        center.addObserver(
            forName: .openDiagnosticReport, object: nil, queue: .main
        ) { [weak self] notification in
            let description = notification.userInfo?["description"] as? String ?? ""
            let mediaPath = notification.userInfo?["mediaPath"] as? String ?? ""
            MainActor.assumeIsolated {
                self?.presentSheet(.diagnosticReport(description: description, mediaPath: mediaPath))
            }
        }

        center.addObserver(
            forName: .newAgentRequested, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentSheet(.newAgent) }
        }

        center.addObserver(
            forName: .agentCategoryRequested, object: nil, queue: .main
        ) { [weak self] notification in
            guard let agent = notification.object as? AgentRecord else { return }
            MainActor.assumeIsolated { self?.presentSheet(.agentCategory(agent)) }
        }

        center.addObserver(
            forName: .removeAgentRequested, object: nil, queue: .main
        ) { [weak self] notification in
            guard let agent = notification.object as? AgentRecord else { return }
            MainActor.assumeIsolated { self?.removeAgent(agent) }
        }

        center.addObserver(
            forName: .openInMaestroDAM, object: nil, queue: .main
        ) { [weak self] notification in
            if let path = notification.userInfo?["path"] as? String {
                UserDefaults.standard.set(path, forKey: "crm.pendingDAMAssetPath")
            }
            MainActor.assumeIsolated { self?.openPanel(.damBrowser) }
        }

        center.addObserver(
            forName: .sendToMaestroDB, object: nil, queue: .main
        ) { [weak self] notification in
            if let path = notification.userInfo?["path"] as? String {
                UserDefaults.standard.set(path, forKey: "crm.pendingMaestroDBAssetPath")
            }
            MainActor.assumeIsolated { self?.openPanel(.maestroDB) }
        }

        // A workspace-layout recall replaces the whole open set, so every
        // panel in the new layout needs its window (re)presented — and any
        // panel that dropped out dismisses itself via its own isFloating
        // observer.
        center.addObserver(
            forName: .workspaceLayoutRecalled, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentOpenPanels() }
        }
    }

    // MARK: - Panels

    /// Open a panel: mark it open in the layout and present its window.
    /// The single call site every "open this panel" action goes through.
    ///
    /// Terminal is special-cased: every open mints a fresh instance so
    /// multiple terminals can coexist.
    func openPanel(_ kind: WorkspacePanelKind) {
        let kindToOpen: WorkspacePanelKind = {
            if case .terminal = kind { return .terminal(UUID()) }
            return kind
        }()

        let result = WorkspaceLayoutState.shared.open(kindToOpen)
        switch result {
        case .floated, .dockedDirectly:
            openWindow?(kindToOpen)
        case .alreadyOpen:
            // Self-healing: if state says this panel is open but its window
            // vanished (restoration didn't recreate it, or a crash left things
            // out of sync), re-clicking should still work. `openWindow` is
            // safe when a matching window already exists — it fronts it
            // rather than duplicating it.
            openWindow?(kindToOpen)
            NotificationCenter.default.post(name: .bringWorkspacePanelToFront, object: kindToOpen)
            if case .agentChat(let id) = kindToOpen {
                NotificationCenter.default.post(name: .bringAgentChatToFront, object: id)
            }
        }
    }

    /// Present every panel the layout currently has open. Used after a
    /// workspace-layout recall.
    private func presentOpenPanels() {
        for kind in WorkspaceLayoutState.shared.allOpenPanels {
            openWindow?(kind)
        }
    }

    // MARK: - Sheets

    /// Present a sheet in the Agents window, reopening that window first when
    /// it isn't on screen (it is the app's only sheet host).
    func presentSheet(_ sheet: WorkspaceActiveSheet) {
        guard isAgentsWindowPresented else {
            openWindow?(.agents)
            // Let the window attach before the sheet is offered; the host
            // also nudges any already-pending sheet on appear.
            DispatchQueue.main.async { [weak self] in
                self?.activeSheet = sheet
            }
            return
        }
        activeSheet = sheet
    }

    // MARK: - Agent removal

    /// Archive an agent and close its chat panel. Never leaves the workspace
    /// with no panels at all — falls back to the navigator chat.
    func removeAgent(_ agent: AgentRecord) {
        guard let workspace = MaestroTools.workspace else { return }
        workspace.archiveAgent(id: agent.id)
        ChatViewModelCache.shared.drop(agent.id)
        let kind = WorkspacePanelKind.agentChat(agent.id)
        WorkspaceLayoutState.shared.close(kind)
        if WorkspaceLayoutState.shared.allOpenPanels.isEmpty {
            openPanel(.agentChat(workspace.navigator.id))
        }
    }
}

// MARK: - Bootstrap

/// Runs the one-time launch bootstrap exactly once.
///
/// The launch sequence (MCP server install, bundled model install, tool
/// registration, store wiring…) lives in the Agents window's `.task`, but an
/// unstructured task owned by this singleton means closing that window a
/// second into launch can't cancel half-finished setup — the closure holds
/// strong references to every store it touches, so they outlive the view.
@MainActor
final class WorkspaceBootstrap {

    static let shared = WorkspaceBootstrap()

    private var started = false
    private var task: Task<Void, Never>?
    /// Objects the launch sequence creates that nothing else owns strongly
    /// (for example `BusWorker`, which `MaestroTools` only holds weakly).
    /// Released only when the process exits — a closed window must not tear
    /// down infrastructure the rest of the app is using.
    private var retained: [AnyObject] = []

    private init() {}

    func start(_ body: @escaping @MainActor () async -> Void) {
        guard !started else { return }
        started = true
        task = Task { await body() }
    }

    /// Keep `object` alive for the lifetime of the process.
    func retain(_ object: AnyObject) {
        retained.append(object)
    }
}
