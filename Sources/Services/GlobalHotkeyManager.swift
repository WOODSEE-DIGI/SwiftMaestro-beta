import Foundation
import AppKit
import Carbon

/// Registers a system-wide push-to-talk hotkey that starts/stops WhisperKit
/// recording regardless of whether SwiftMaestro is the active app. This is
/// designed for integration with Elgato Stream Deck or any other tool that can
/// emit a keyboard key: simply program the Stream Deck key to send the chosen
/// key, then hold it to talk and release it to stop and auto-send.
///
/// Requires the user to grant Accessibility permission in System Settings >
/// Privacy & Security > Accessibility for the app to receive global key events.
final class GlobalHotkeyManager: @unchecked Sendable {
    static let shared = GlobalHotkeyManager()

    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var registeredKeyCode: UInt16?
    private var registeredModifiers: NSEvent.ModifierFlags?
    private let stateLock = NSLock()
    private var wasRecordingWhenKeyPressed: Bool = false
    private var isPushToTalkKeyDown: Bool = false

    /// Whether the manager is currently monitoring global key events.
    var isRegistered: Bool { keyDownMonitor != nil }

    private init() {}

    /// Register a global push-to-talk key. Pass 0 for keyCode to disable.
    ///
    /// - Parameters:
    ///   - keyCode: Virtual key code to listen for (e.g., kVK_F13 = 105).
    ///   - modifiers: Modifier flags required to match (default: none).
    ///   - service: The WhisperKitService to start/stop on key events.
    func register(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], service: WhisperKitService) {
        unregister()

        guard keyCode != 0 else {
            registeredKeyCode = nil
            registeredModifiers = nil
            return
        }

        registeredKeyCode = keyCode
        registeredModifiers = modifiers

        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            guard self.matches(event) else { return }
            self.stateLock.lock()
            guard !self.isPushToTalkKeyDown else {
                self.stateLock.unlock()
                return
            }
            self.isPushToTalkKeyDown = true
            self.stateLock.unlock()

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.wasRecordingWhenKeyPressed = service.isRecording
                // Audio input is restricted to the Maestro agent.
                guard AgentCommandCenter.shared.isNavigatorActive else { return }
                service.toggleRecording()
            }
        }

        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self else { return }
            guard self.matches(event) else { return }
            self.stateLock.lock()
            self.isPushToTalkKeyDown = false
            self.stateLock.unlock()

            // Only stop if push-to-talk actually started this recording.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if service.isRecording, !self.wasRecordingWhenKeyPressed {
                    service.toggleRecording()
                }
            }
        }
    }

    /// Stop monitoring global key events.
    func unregister() {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
        if let monitor = keyUpMonitor {
            NSEvent.removeMonitor(monitor)
            keyUpMonitor = nil
        }
        registeredKeyCode = nil
        registeredModifiers = nil
        isPushToTalkKeyDown = false
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == registeredKeyCode else { return false }
        let required = registeredModifiers?.intersection(.deviceIndependentFlagsMask) ?? []
        let actual = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return actual == required
    }
}

// MARK: - Key-code helpers

extension GlobalHotkeyManager {
    /// Human-readable name for a key code, e.g. "F13" or "F1".
    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Escape"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ANSI_KeypadClear: return "Keypad Clear"
        default:
            return "Key \(keyCode)"
        }
    }
}
