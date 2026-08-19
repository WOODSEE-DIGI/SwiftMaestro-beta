import Foundation
import Observation

/// Well-known step identifiers for the first-run setup sheet.
enum SetupStepID {
    /// Extracting / dependency-installing / signing the bundled MCP servers.
    static let mcpServers = "mcpServers"
    /// Hardlinking (or copying) the bundled AI models into the model root.
    static let bundledModels = "bundledModels"
    /// Auto-detecting and enabling web search MCP servers.
    static let webTools = "webTools"
}

/// One named unit of first-run setup work shown in the setup progress sheet.
struct SetupStep: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case pending
        case running
        case done
        case skipped
        case failed(String)
    }

    let id: String
    let title: String
    var outcome: Outcome = .pending
    /// Live one-line description of the exact item being processed right now
    /// (e.g. "Signing node runtime (37 of 214)…"). This is the line that
    /// replaces the spinning beachball for the user.
    var detail: String = ""
    /// Optional 0...1 fraction for the step's own progress bar. nil while the
    /// step is indeterminate.
    var progress: Double? = nil
}

/// Tracks first-run dependency installation so the UI can show a
/// Photoshop/Resolve-style "what's being installed" screen instead of
/// beachballing the main thread with no explanation.
///
/// The heavy lifting happens in `MCPServerBundleService` / `BundledModelService`
/// (deliberately nonisolated so none of it can block the main thread); they
/// report through `SetupReporter`, which hops to the MainActor here.
@MainActor @Observable
final class SetupProgressService {

    /// Nonisolated so background reporters and the AppDelegate can reach the
    /// singleton without an actor hop.
    nonisolated static let shared = SetupProgressService()

    /// The planned steps for this launch. Empty when there is nothing to
    /// install (every launch after the first, and dev builds without bundled
    /// resources) — the sheet only appears when this is non-empty.
    private(set) var steps: [SetupStep] = []
    /// True while install work is actively running.
    private(set) var isRunning = false
    /// True when this launch has real install work to show. Computed BEFORE
    /// any window appears (from `AppDelegate.applicationWillFinishLaunching`)
    /// so ContentView can present the setup sheet instead of the welcome sheet
    /// with no flicker.
    private(set) var hasPendingWork = false
    /// True once `complete()` has run (all install work finished — possibly
    /// with failures; individual step outcomes carry the detail).
    private(set) var isComplete = false

    private nonisolated init() {}

    // MARK: - Planning (called once, pre-UI)

    /// Cheap synchronous scan (UserDefaults + directory-exists checks only —
    /// no enumeration, no I/O beyond a manifest JSON read) deciding whether
    /// this launch needs the setup sheet at all.
    func plan() {
        guard steps.isEmpty, !hasPendingWork else { return }  // once per launch
        var planned: [SetupStep] = []
        if MCPServerBundleService.shared.needsInstall {
            planned.append(SetupStep(id: SetupStepID.mcpServers,
                                     title: "Installing built-in AI tools"))
        }
        if BundledModelService.shared.needsInstall {
            planned.append(SetupStep(id: SetupStepID.bundledModels,
                                     title: "Installing bundled AI models"))
        }
        // Web search configuration is quick on its own — only worth showing
        // when the sheet is already up for heavier work.
        if !planned.isEmpty && WebSetupService.needsConfiguration {
            planned.append(SetupStep(id: SetupStepID.webTools,
                                     title: "Configuring web search tools"))
        }
        steps = planned
        hasPendingWork = !planned.isEmpty
    }

    // MARK: - Lifecycle (called from the app startup task)

    /// Marks the planned work as started. The sheet is already visible by the
    /// time this is called.
    func beginPlannedWork() {
        guard hasPendingWork, !isRunning else { return }
        isRunning = true
    }

    /// Marks setup finished. Any step that never reported an outcome is swept
    /// to a truthful terminal state so the UI can never stick on a spinner.
    func complete() {
        for index in steps.indices {
            switch steps[index].outcome {
            case .running: steps[index].outcome = .done
            case .pending: steps[index].outcome = .skipped
            case .done, .skipped, .failed: break
            }
        }
        isRunning = false
        isComplete = true
    }

    // MARK: - Per-step updates (via SetupReporter)

    func reportBegin(id: String, detail: String = "") {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].outcome = .running
        steps[index].detail = detail
        steps[index].progress = nil
    }

    func reportUpdate(id: String, detail: String, progress: Double? = nil) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        if steps[index].outcome != .running { steps[index].outcome = .running }
        steps[index].detail = detail
        if let progress { steps[index].progress = min(1, max(0, progress)) }
    }

    func reportFinish(id: String, outcome: SetupStep.Outcome, detail: String = "") {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].outcome = outcome
        if !detail.isEmpty { steps[index].detail = detail }
        steps[index].progress = outcome == .done ? 1 : steps[index].progress
    }

    // MARK: - Derived state for the view

    /// The single live "what's happening right now" line — the beachball
    /// replacement. Shows the most recently started running step's detail.
    var currentActivity: String {
        if let running = steps.last(where: { $0.outcome == .running }) {
            return running.detail.isEmpty ? "\(running.title)…" : running.detail
        }
        if isComplete { return "Setup complete." }
        return "Preparing…"
    }

    /// Fraction of steps that have reached a terminal state — drives the
    /// overall progress bar.
    var overallProgress: Double {
        guard !steps.isEmpty else { return 0 }
        let terminal = steps.filter {
            switch $0.outcome {
            case .done, .skipped, .failed: return true
            case .pending, .running: return false
            }
        }.count
        return Double(terminal) / Double(steps.count)
    }
}

/// Sendable handle that background install work uses to report live progress
/// into the (MainActor) setup sheet. Every hop is awaited, so status ordering
/// is preserved within a step even though the work runs off the main thread.
struct SetupReporter: Sendable {
    init() {}

    @MainActor func begin(_ id: String, detail: String = "") {
        SetupProgressService.shared.reportBegin(id: id, detail: detail)
    }

    @MainActor func update(_ id: String, detail: String, progress: Double? = nil) {
        SetupProgressService.shared.reportUpdate(id: id, detail: detail, progress: progress)
    }

    @MainActor func finish(_ id: String, _ outcome: SetupStep.Outcome, detail: String = "") {
        SetupProgressService.shared.reportFinish(id: id, outcome: outcome, detail: detail)
    }
}
