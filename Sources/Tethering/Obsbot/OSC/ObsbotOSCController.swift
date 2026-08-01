import Foundation

/// OSC-based controller for OBSBOT webcams via OBSBOT Center.
///
/// Reference: `obsbot_center_osc_definition.xlsx` (downloaded from
/// https://www.obsbot.com/explore/obsbot-center/osc) and the official
/// TouchOSC sample `OBSBOT_WebCam_Sample-UDP.tosc`.
///
/// The TouchOSC sample sends **one** argument for most commands (targeting the
/// currently selected device). We follow that convention here, matching the
/// exact packets the official sample emits.
///
/// Requires OBSBOT Center to be running on the same Mac. The default OSC UDP
/// port is 16284.
@MainActor
@Observable
final class ObsbotOSCController: @unchecked Sendable {
    static let shared = ObsbotOSCController()

    private let sender = OSCUDPSender()
    private var heartbeatTimer: Timer?

    private(set) var isConnected = false
    private(set) var lastError: String?
    var statusMessage: String = ""

    var panTiltSpeed: Int32 = 80
    var zoomValue: Int32 = 0
    var aiMode: Int32 = 0
    var fovMode: Int32 = 0
    var trackingMode: Int32 = 1
    var trackingSpeed: Int32 = 1

    private init() {}

    func connect() {
        disconnect()
        sender.connect()
        isConnected = true
        lastError = nil
        statusMessage = "OSC ready on 127.0.0.1:16284"
        // Select the first device, then announce presence and request device info.
        selectDevice(0)
        send(.message(address: "/OBSBOT/WebCam/General/Connected", arguments: [.int32(1)]))
        getDeviceInfo()
        startHeartbeat()
    }

    func disconnect() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        sender.disconnect()
        isConnected = false
        statusMessage = ""
    }

    // MARK: - Gimbal

    func gimbalMove(direction: GimbalDirection, speed: Int32) {
        let address: String
        switch direction {
        case .up:    address = "/OBSBOT/WebCam/General/SetGimbalUp"
        case .down:  address = "/OBSBOT/WebCam/General/SetGimbalDown"
        case .left:  address = "/OBSBOT/WebCam/General/SetGimbalLeft"
        case .right: address = "/OBSBOT/WebCam/General/SetGimbalRight"
        }
        send(.message(address: address, arguments: [.int32(speed)]))
    }

    func gimbalMove(pan: Int32, tilt: Int32) {
        if pan > 0 {
            gimbalMove(direction: .left, speed: abs(pan))
        } else if pan < 0 {
            gimbalMove(direction: .right, speed: abs(pan))
        }
        if tilt > 0 {
            gimbalMove(direction: .up, speed: abs(tilt))
        } else if tilt < 0 {
            gimbalMove(direction: .down, speed: abs(tilt))
        }
    }

    func gimbalStop() {
        gimbalMove(direction: .up, speed: 0)
        gimbalMove(direction: .down, speed: 0)
        gimbalMove(direction: .left, speed: 0)
        gimbalMove(direction: .right, speed: 0)
    }

    func gimbalReset() {
        // The official sample sends a single integer argument of 1.
        send(.message(address: "/OBSBOT/WebCam/General/ResetGimbal", arguments: [.int32(1)]))
    }

    func gimbalMoveTo(pan: Float, tilt: Float, speed: Float = 30) {
        send(.message(address: "/OBSBOT/WebCam/General/SetGimMotorDegreeEx",
                      arguments: [.float32(speed), .float32(pan), .float32(tilt)]))
    }

    // MARK: - Zoom

    func setZoom(_ value: Int32) {
        zoomValue = max(0, min(100, value))
        send(.message(address: "/OBSBOT/WebCam/General/SetZoom", arguments: [.int32(zoomValue)]))
    }

    func setZoomSpeed(_ value: Int32, speed: Int32 = 0) {
        zoomValue = max(0, min(100, value))
        send(.message(address: "/OBSBOT/WebCam/General/SetZoomSpeed",
                      arguments: [.int32(zoomValue), .int32(speed)]))
    }

    func zoomMax() {
        send(.message(address: "/OBSBOT/WebCam/General/SetZoomMax", arguments: [.int32(1)]))
    }

    func zoomMin() {
        send(.message(address: "/OBSBOT/WebCam/General/SetZoomMin", arguments: [.int32(1)]))
    }

    // MARK: - View / FOV

    func setView(_ mode: Int32) {
        fovMode = max(0, min(2, mode))
        send(.message(address: "/OBSBOT/WebCam/General/SetView", arguments: [.int32(fovMode)]))
    }

    // MARK: - Device

    func selectDevice(_ index: Int32) {
        send(.message(address: "/OBSBOT/WebCam/General/SelectDevice",
                      arguments: [.int32(max(0, index))]))
    }

    // MARK: - Sleep / Wake

    func setSleep(_ asleep: Bool) {
        send(.message(address: "/OBSBOT/WebCam/General/WakeSleep",
                      arguments: [.int32(asleep ? 0 : 1)]))
    }

    // MARK: - AI / Tracking

    /// Tiny 3 / Tiny 3 Lite AI mode:
    /// 0 -> Human Tracking-Single Mode
    /// 1 -> Human Tracking-Group Mode
    /// 2 -> Voice Tracking
    /// 3 -> Desk Mode
    /// 4 -> Hand
    /// 5 -> Whiteboard
    func setAIMode(_ mode: Int32) {
        aiMode = max(0, min(5, mode))
        send(.message(address: "/OBSBOT/WebCam/Tiny/SetAiMode", arguments: [.int32(aiMode)]))
    }

    func setTrackingMode(_ mode: Int32) {
        trackingMode = max(0, min(2, mode))
        send(.message(address: "/OBSBOT/WebCam/Tiny/SetTrackingMode", arguments: [.int32(trackingMode)]))
    }

    func setTrackingSpeed(_ speed: Int32) {
        trackingSpeed = max(0, min(2, speed))
        send(.message(address: "/OBSBOT/WebCam/Tiny/SetTrackingSpeed", arguments: [.int32(trackingSpeed)]))
    }

    func setAILock(_ locked: Bool) {
        send(.message(address: "/OBSBOT/WebCam/Tiny/ToggleAILock", arguments: [.int32(locked ? 1 : 0)]))
    }

    // MARK: - Presets

    func triggerPreset(_ index: Int32) {
        send(.message(address: "/OBSBOT/WebCam/Tiny/TriggerPreset",
                      arguments: [.int32(max(0, min(2, index)))]))
    }

    // MARK: - Queries

    func getDeviceInfo() {
        send(.message(address: "/OBSBOT/WebCam/General/GetDeviceInfo", arguments: [.int32(0)]))
    }

    func getZoomInfo() {
        send(.message(address: "/OBSBOT/WebCam/General/GetZoomInfo", arguments: [.int32(0)]))
    }

    func getGimbalPosition() {
        send(.message(address: "/OBSBOT/WebCam/General/GetGimbalPosInfo", arguments: [.int32(0)]))
    }

    // MARK: - Private

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.send(.message(address: "/OBSBOT/WebCam/General/Connected", arguments: [.int32(1)]))
        }
    }

    private func send(_ message: OSCMessage) {
        sender.send(message)
        statusMessage = "Sent \(message.address)"
    }
}

extension ObsbotOSCController {
    enum GimbalDirection {
        case up, down, left, right
    }
}

private extension OSCMessage {
    var address: String {
        switch self {
        case .message(let address, _): return address
        }
    }
}
