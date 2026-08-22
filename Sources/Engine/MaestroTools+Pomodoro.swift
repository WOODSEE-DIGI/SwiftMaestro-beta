import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Pomodoro tools
//
// Agent control over the Pomodoro timer so the user can say "start a
// 25-minute focus block for the communications audit" and the agent drives
// the shared PomodoroStore. Follows the registerDAMTools pattern; the store
// is @MainActor so handlers hop over.

extension MaestroTools {

    static func registerPomodoroTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "pomodoro_control", spec: pomodoroToolSpecs[0],
                category: ToolCategory.time.rawValue,
                handler: { call in await pomodoroControl(call) }),
        ])
    }

    static var pomodoroToolSpecs: [ToolSpec] {
        [
            rawSpec("pomodoro_control",
                "Control the Pomodoro focus timer. Actions: 'start' begins a "
                + "focus block (optional minutes + label), 'break' starts a "
                + "break, 'pause'/'resume'/'toggle' manage a running block, "
                + "'skip' ends the current phase early, 'stop' resets to idle, "
                + "'status' returns the current phase, elapsed/remaining time, "
                + "and today's completed focus stats. Breaks auto-start when a "
                + "focus block completes; a long break lands every N cycles.",
                properties: [
                    "action": ["type": "string", "description": "start | break | pause | resume | toggle | skip | stop | status."],
                    "minutes": ["type": "integer", "description": "Optional duration override for 'start'/'break' (uses the user's configured durations when omitted)."],
                    "label": ["type": "string", "description": "Optional 'what are you working on' label for 'start'."],
                ],
                required: ["action"]),
        ]
    }

    private struct PomodoroArgs: Codable {
        let action: String?
        let minutes: Int?
        let label: String?
    }

    private static func pomodoroControl(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PomodoroArgs.self),
              let action = args.action?.lowercased() else {
            return "Error: action is required."
        }
        return await MainActor.run {
            let store = PomodoroStore.shared
            switch action {
            case "start":
                store.startWork(label: args.label, minutes: args.minutes)
            case "break":
                store.startBreak()
            case "pause":
                store.pause()
            case "resume":
                store.resume()
            case "toggle":
                store.toggle()
            case "skip":
                store.skipPhase()
            case "stop":
                store.stop()
            case "status":
                break
            default:
                return "Error: unknown action '\(action)'. Use start | break | pause | resume | toggle | skip | stop | status."
            }
            return "Pomodoro: \(store.statusDescription)"
        }
    }
}
