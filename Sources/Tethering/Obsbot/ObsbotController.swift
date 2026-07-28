import Foundation
import AVFoundation

/// Errors thrown by the OBSBOT controller.
enum ObsbotControllerError: LocalizedError, Sendable {
    case notConnected
    case deviceNotFound
    case transferFailed(String)
    case unsupportedModel(UInt16)
    case alreadyConnected
    case multipleDevicesFound([ObsbotModel])
    case replyParseFailed
    case noReply

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "OBSBOT controller is not connected."
        case .deviceNotFound:
            return "No OBSBOT camera found."
        case .transferFailed(let reason):
            return "USB transfer failed: \(reason)"
        case .unsupportedModel(let pid):
            return "Unsupported OBSBOT model (PID 0x\(String(pid, radix: 16, uppercase: true)))."
        case .alreadyConnected:
            return "OBSBOT controller is already connected."
        case .multipleDevicesFound(let models):
            return "Multiple OBSBOT cameras found: \(models.map(\.name).joined(separator: ", ")). Please leave only one connected."
        case .replyParseFailed:
            return "Failed to parse the camera reply."
        case .noReply:
            return "Camera did not reply."
        }
    }
}

// MARK: - Low-level USB handle

/// IOKit-based USB backend for the OBSBOT controller.
///
/// Uses `ObsbotIOKitController` (Objective-C wrapper) to open the device via IOKit
/// without claiming interfaces. This avoids conflicts with UVCAssistant on macOS.
private final class ObsbotIOKitHandle: @unchecked Sendable {
    private let controller = ObsbotIOKitController()
    private let queue = DispatchQueue(label: "swiftmaestro.obsbot.iokit", qos: .userInitiated)

    private(set) var connectedModel: ObsbotModel?
    private var sequence: UInt16 = 0
    private var nextSequence: UInt16 {
        sequence &+= 1
        return sequence
    }

    var isConnected: Bool { controller.isConnected }

    /// Open the first attached OBSBOT camera. If `preferredProductID` is non-zero,
    /// that model is tried first; otherwise all known PIDs are scanned.
    func connect(preferredProductID: UInt16 = 0) async throws -> ObsbotModel {
        guard !isConnected else {
            throw ObsbotControllerError.alreadyConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: ObsbotControllerError.notConnected)
                    return
                }

                var pids = ObsbotCommandSet.knownProductIDs
                if preferredProductID != 0, !pids.contains(preferredProductID) {
                    pids.insert(preferredProductID, at: 0)
                } else if preferredProductID != 0 {
                    pids.removeAll(where: { $0 == preferredProductID })
                    pids.insert(preferredProductID, at: 0)
                }

                let pidNumbers = pids.map { NSNumber(value: $0) }
                guard let name = self.controller.connect(withProductIDs: pidNumbers) else {
                    continuation.resume(throwing: ObsbotControllerError.deviceNotFound)
                    return
                }

                // Determine the active PID from the controller name.
                let matchedPID = pids.first { pid in
                    let modelName = ObsbotIOKitHandle.name(for: pid)
                    return name.localizedCaseInsensitiveContains(modelName)
                } ?? pids[0]

                let model = ObsbotModel(productID: matchedPID, name: ObsbotIOKitHandle.name(for: matchedPID))
                self.connectedModel = model
                continuation.resume(returning: model)
            }
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.controller.disconnect()
            self.connectedModel = nil
        }
    }

    /// Send a framed V3 command. By default waits for a matching reply.
    ///
    /// - Parameters:
    ///   - command: Builder that returns the raw 60-byte frame.
    ///   - expectedCommand: The wire command for reply validation.
    ///   - expectReply: If false, the command is sent and the function returns immediately
    ///     without polling the mailbox. Use this for gimbal speed/position SETs that the
    ///     camera may not acknowledge.
    ///   - retries: Number of GET attempts to poll for the reply when `expectReply` is true.
    func sendFramed(
        _ command: @Sendable @escaping (UInt16) -> [UInt8],
        expectedCommand: UInt16,
        expectReply: Bool = true,
        retries: Int = 8
    ) async throws -> [UInt8] {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self, self.isConnected else {
                    continuation.resume(throwing: ObsbotControllerError.notConnected)
                    return
                }

                let seq = self.nextSequence
                let frame = command(seq)
                guard frame.count == ObsbotCommandSet.payloadSize else {
                    continuation.resume(throwing: ObsbotControllerError.transferFailed("Invalid frame size"))
                    return
                }

                let data = Data(frame)
                let unit = ObsbotCommandSet.xuUnit
                let selector = ObsbotCommandSet.selectorXU

                guard self.controller.send(data, selector: UInt16(selector), unit: unit) else {
                    continuation.resume(throwing: ObsbotControllerError.transferFailed("SET_CUR failed"))
                    return
                }

                if !expectReply {
                    continuation.resume(returning: [])
                    return
                }

                // Poll the mailbox for the reply.
                let readLength = ObsbotCommandSet.payloadSize
                for attempt in 0..<retries {
                    Thread.sleep(forTimeInterval: 0.05 * Double(attempt + 1))
                    guard let replyData = self.controller.readBytes(withLength: UInt(readLength), selector: UInt16(selector), unit: unit) else {
                        continue
                    }
                    let replyBytes = [UInt8](replyData)
                    let parsed = ObsbotV3Protocol.parseReply(replyBytes, expectedCommand: expectedCommand, expectedSequence: seq)
                    if parsed.valid {
                        continuation.resume(returning: parsed.payload)
                        return
                    }
                }
                continuation.resume(throwing: ObsbotControllerError.noReply)
            }
        }
    }

    /// Send a raw UVC control transfer to selector 0x06.
    func sendRawSelector6(_ bytes: [UInt8]) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self, self.isConnected else {
                    continuation.resume(throwing: ObsbotControllerError.notConnected)
                    return
                }
                var payload = [UInt8](repeating: 0, count: ObsbotCommandSet.payloadSize)
                for i in 0..<min(bytes.count, payload.count) {
                    payload[i] = bytes[i]
                }
                let data = Data(payload)
                let selector = ObsbotCommandSet.selectorStatus
                let unit = ObsbotCommandSet.xuUnit
                if self.controller.send(data, selector: UInt16(selector), unit: unit) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ObsbotControllerError.transferFailed("SET_CUR selector 6 failed"))
                }
            }
        }
    }

    /// Read a standard UVC control (e.g., zoom or pan/tilt) from camera terminal unit 1.
    func readStandardControl(selector: UInt16, length: UInt16, unit: UInt8 = 0x01, bRequest: UInt8 = 0x81) async throws -> [UInt8] {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self, self.isConnected else {
                    continuation.resume(throwing: ObsbotControllerError.notConnected)
                    return
                }
                guard let data = self.controller.readBytes(withLength: UInt(length), selector: selector, unit: unit, bRequest: bRequest) else {
                    continuation.resume(throwing: ObsbotControllerError.transferFailed("GET request 0x\(String(bRequest, radix: 16)) failed for selector 0x\(String(selector, radix: 16))"))
                    return
                }
                continuation.resume(returning: [UInt8](data))
            }
        }
    }

    /// Write a standard UVC control (e.g., zoom or pan/tilt) to camera terminal unit 1.
    func writeStandardControl(selector: UInt16, bytes: [UInt8], unit: UInt8 = 0x01) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self, self.isConnected else {
                    continuation.resume(throwing: ObsbotControllerError.notConnected)
                    return
                }
                let data = Data(bytes)
                if self.controller.send(data, selector: selector, unit: unit) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ObsbotControllerError.transferFailed("SET_CUR failed for selector 0x\(String(selector, radix: 16))"))
                }
            }
        }
    }

    private static func name(for pid: UInt16) -> String {
        switch pid {
        case 0xFEF8: return ObsbotModel.tiny2.name
        case 0xFEF9: return ObsbotModel.tiny2Lite.name
        case 0xFF02: return ObsbotModel.tiny3.name
        case 0xFF04: return ObsbotModel.tiny3Lite.name
        default: return "OBSBOT Unknown (0x\(String(pid, radix: 16, uppercase: true)))"
        }
    }
}

// MARK: - High-level controller

/// Controls an OBSBOT webcam via IOKit UVC control transfers.
///
/// The video-capture path is still handled by `AVCaptureSource`; this class drives
/// PTZ/AI/image commands over the same USB connection.
@MainActor
@Observable
final class ObsbotController: @unchecked Sendable {
    static let shared = ObsbotController()

    private let iokit = ObsbotIOKitHandle()

    private(set) var isConnected = false
    private(set) var model: ObsbotModel?
    private(set) var lastError: String?
    private(set) var statusDump: String?
    private(set) var commandLog: String = ""

    var trackingMode: ObsbotTrackingMode = .off
    var hdrEnabled: Bool = false
    var fovMode: ObsbotFOVMode = .wide
    var noiseCancellation: ObsbotNoiseCancellation = .off

    // PTZ state
    var zoomRatio: Float = 1.0
    var zoomMin: Float = 1.0
    var zoomMax: Float = 4.0
    var zoomMinUnits: UInt16 = 100
    var zoomMaxUnits: UInt16 = 400
    var panAngle: Float = 0
    var tiltAngle: Float = 0
    var panSpeed: Float = 20.0
    var useStandardUVCPanTilt: Bool = false

    private init() {}

    /// Connect to the attached OBSBOT camera.
    func connect(preferredProductID: UInt16 = 0) async {
        lastError = nil
        do {
            model = try await iokit.connect(preferredProductID: preferredProductID)
            isConnected = true
            // Read current zoom range once.
            try? await readZoomRange()
            try? await refreshStatus()
        } catch {
            isConnected = false
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        iokit.disconnect()
        isConnected = false
        model = nil
        lastError = nil
        statusDump = nil
        zoomRatio = 1.0
    }

    // MARK: - Commands

    func setTrackingMode(_ mode: ObsbotTrackingMode) async {
        // The Tiny 2/3 firmware ignores the framed AI_SET_AI_TRACK_MODE command; the
        // working control is a raw write to XU selector 0x06.
        await sendRaw { ObsbotV3Protocol.rawTracking(enable: mode != .off, framing: mode.framingByte) }
        trackingMode = mode
    }

    func setHDR(_ enabled: Bool) async {
        await sendRaw { ObsbotV3Protocol.rawHDR(on: enabled) }
        hdrEnabled = enabled
    }

    func setFOV(_ mode: ObsbotFOVMode) async {
        await sendRaw { ObsbotV3Protocol.rawFOV(mode: mode.wireValue) }
        fovMode = mode
    }

    func setNoiseCancellation(_ mode: ObsbotNoiseCancellation) async {
        await sendRaw(mode.commandBytes)
    }

    func recenterGimbal() async {
        await sendFramed("recenter", { seq in ObsbotV3Protocol.recenterCommand(sequence: seq) }, expected: ObsbotV3Protocol.cmdRecenter, expectReply: false)
    }

    func sleep() async {
        await sendFramed("sleep", { seq in ObsbotV3Protocol.sleepCommand(sequence: seq) }, expected: ObsbotV3Protocol.cmdWake, expectReply: false)
    }

    func wake() async {
        await sendFramed("wake", { seq in ObsbotV3Protocol.wakeCommand(sequence: seq) }, expected: ObsbotV3Protocol.cmdWake, expectReply: false)
    }

    // MARK: - PTZ

    private var activeGimbalHeartbeat: Task<Void, Never>?
    private var activeGimbalPan: Float = 0
    private var activeGimbalTilt: Float = 0

    /// Send a single gimbal speed command. For joystick-style motion use
    /// `startGimbalSpeed` / `stopGimbalSpeed` instead.
    func sendGimbalSpeed(panDegPerSec: Float, tiltDegPerSec: Float, duration: TimeInterval = 0.3) async {
        await sendGimbalSpeedBurst(panDegPerSec: panDegPerSec, tiltDegPerSec: tiltDegPerSec)
        if duration > 0 {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            await sendGimbalSpeedBurst(panDegPerSec: 0, tiltDegPerSec: 0)
        }
    }

    /// Start continuous gimbal motion. The speed command is re-sent every 120 ms
    /// until `stopGimbalSpeed` is called, so the motor keeps moving while the button
    /// is held even if a single command gets dropped.
    func startGimbalSpeed(panDegPerSec: Float, tiltDegPerSec: Float) {
        if useStandardUVCPanTilt {
            startRelativePanTilt(panDegPerSec: panDegPerSec, tiltDegPerSec: tiltDegPerSec)
        } else {
            activeGimbalHeartbeat?.cancel()
            activeGimbalPan = panDegPerSec
            activeGimbalTilt = tiltDegPerSec
            activeGimbalHeartbeat = Task { [self] in
                while !Task.isCancelled {
                    await sendGimbalSpeedBurst(panDegPerSec: activeGimbalPan, tiltDegPerSec: activeGimbalTilt)
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }
        }
    }

    /// Stop continuous gimbal motion and send a zero-speed command.
    func stopGimbalSpeed() {
        if useStandardUVCPanTilt {
            stopRelativePanTilt()
        } else {
            activeGimbalHeartbeat?.cancel()
            activeGimbalHeartbeat = nil
            activeGimbalPan = 0
            activeGimbalTilt = 0
            Task {
                await sendGimbalSpeedBurst(panDegPerSec: 0, tiltDegPerSec: 0)
            }
        }
    }

    // MARK: - Standard UVC fallback pan/tilt

    private var activeRelativePTZHeartbeat: Task<Void, Never>?
    private var activeRelativePan: Int8 = 0
    private var activeRelativeTilt: Int8 = 0

    /// Start continuous pan/tilt using the standard UVC `CT_PANTILT_RELATIVE` control.
    /// This is a fallback for devices that do not respond to the vendor V3 gimbal speed command.
    func startRelativePanTilt(panDegPerSec: Float, tiltDegPerSec: Float) {
        activeRelativePTZHeartbeat?.cancel()

        // UVC relative pan/tilt: 1 = one direction, 0xFF = opposite, 0 = stop.
        // Pan positive = camera's left (vendor yaw positive); tilt positive = up (negative pitch).
        let panDir: Int8 = panDegPerSec > 0 ? 1 : (panDegPerSec < 0 ? -1 : 0)
        let tiltDir: Int8 = tiltDegPerSec > 0 ? 1 : (tiltDegPerSec < 0 ? -1 : 0)
        let panSpeed = UInt8(min(255, max(1, abs(panDegPerSec) * 4)))
        let tiltSpeed = UInt8(min(255, max(1, abs(tiltDegPerSec) * 4)))

        activeRelativePan = panDir
        activeRelativeTilt = tiltDir

        activeRelativePTZHeartbeat = Task { [self] in
            while !Task.isCancelled {
                await sendRelativePanTiltBurst(panDir: activeRelativePan, panSpeed: panSpeed, tiltDir: activeRelativeTilt, tiltSpeed: tiltSpeed)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    /// Stop standard UVC relative pan/tilt motion.
    func stopRelativePanTilt() {
        activeRelativePTZHeartbeat?.cancel()
        activeRelativePTZHeartbeat = nil
        activeRelativePan = 0
        activeRelativeTilt = 0
        Task {
            await sendRelativePanTiltBurst(panDir: 0, panSpeed: 0, tiltDir: 0, tiltSpeed: 0)
        }
    }

    private func sendRelativePanTiltBurst(panDir: Int8, panSpeed: UInt8, tiltDir: Int8, tiltSpeed: UInt8) async {
        var bytes = [UInt8]()
        bytes.append(UInt8(bitPattern: panDir))
        bytes.append(panSpeed)
        bytes.append(UInt8(bitPattern: tiltDir))
        bytes.append(tiltSpeed)
        await sendStandard("panTiltRel", bytes, selector: ObsbotCommandSet.ctPanTiltRelative)
    }

    private func sendGimbalSpeedBurst(panDegPerSec: Float, tiltDegPerSec: Float) async {
        await sendFramed("gimbalSpeed", { seq in
            ObsbotV3Protocol.gimbalSpeedCommand(
                rollDegPerSec: 0,
                pitchDegPerSec: tiltDegPerSec,
                yawDegPerSec: panDegPerSec,
                sequence: seq
            )
        }, expected: ObsbotV3Protocol.cmdGimbalSpeed, expectReply: false)
    }

    func moveToPanTilt(pan: Float, tilt: Float) async {
        await sendFramed("moveToAngle", { seq in
            ObsbotV3Protocol.gimbalMoveToAngle(
                roll: 0,
                pitch: tilt,
                yaw: pan,
                sequence: seq
            )
        }, expected: ObsbotV3Protocol.cmdGimbalMoveToAngle, expectReply: false)
    }

    func readZoomRange() async throws {
        let minBytes = try await iokit.readStandardControl(selector: ObsbotCommandSet.ctZoomAbsolute, length: 2, bRequest: 0x82)
        let maxBytes = try await iokit.readStandardControl(selector: ObsbotCommandSet.ctZoomAbsolute, length: 2, bRequest: 0x83)
        zoomMinUnits = UInt16(minBytes[0]) | (UInt16(minBytes[1]) << 8)
        zoomMaxUnits = UInt16(maxBytes[0]) | (UInt16(maxBytes[1]) << 8)
        // Map the raw zoom-unit range to a ratio range. The exact mapping depends on the
        // device; Tiny 2/3 Lite are observed to use 100≈1x, 400≈4x.
        zoomMin = 1.0
        zoomMax = max(1.0, Float(zoomMaxUnits) / Float(zoomMinUnits))
    }

    func readPanTiltPosition() async {
        do {
            let bytes = try await iokit.readStandardControl(selector: ObsbotCommandSet.ctPanTiltAbsolute, length: 8)
            let panArcSec = ObsbotV3Protocol.int32FromBytes(bytes, offset: 0)
            let tiltArcSec = ObsbotV3Protocol.int32FromBytes(bytes, offset: 4)
            panAngle = Float(panArcSec) / 3600.0
            tiltAngle = Float(tiltArcSec) / 3600.0
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setZoomRatio(_ ratio: Float) async {
        let clamped = max(zoomMin, min(ratio, zoomMax))
        let unitValue = UInt16(Float(zoomMinUnits) + Float(zoomMaxUnits - zoomMinUnits) * (clamped - zoomMin) / (zoomMax - zoomMin))
        var bytes = [UInt8]()
        bytes.append(UInt8(unitValue & 0xFF))
        bytes.append(UInt8((unitValue >> 8) & 0xFF))
        await sendStandard(bytes)
        zoomRatio = clamped
    }

    // MARK: - Presets

    func recallPreset(_ index: Int) async {
        let slot = UInt32(max(0, min(index, 2)))
        await sendFramed("presetRecall", { seq in ObsbotV3Protocol.presetRecallCommand(slot: slot, sequence: seq) }, expected: ObsbotV3Protocol.cmdPresetRecall, expectReply: false)
    }

    func savePreset(_ index: Int, name: String = "") async {
        let slot = UInt32(max(0, min(index, 2)))
        let pan = panAngle
        let tilt = tiltAngle
        let roll: Float = 0
        let zoom = zoomRatio
        await sendFramed("presetSave", { seq in ObsbotV3Protocol.presetSaveCommand(slot: slot, pan: pan, tilt: tilt, roll: roll, zoom: zoom, sequence: seq) }, expected: ObsbotV3Protocol.cmdPresetUpdate, expectReply: false)
    }

    func deletePreset(_ index: Int) async {
        let slot = UInt32(max(0, min(index, 2)))
        await sendFramed("presetDelete", { seq in ObsbotV3Protocol.presetDeleteCommand(slot: slot, sequence: seq) }, expected: ObsbotV3Protocol.cmdPresetDelete, expectReply: false)
    }

    /// Refresh the 60-byte status block and update the tracked state.
    func refreshStatus() async {
        do {
            let status = try await iokit.readStandardControl(selector: ObsbotCommandSet.selectorStatus, length: 60)
            statusDump = status.enumerated().map { String(format: "%02X:%02X", $0, $1) }.joined(separator: " ")
            decodeStatus(status)
        } catch {
            lastError = error.localizedDescription
        }
        await readPanTiltPosition()
    }

    // MARK: - Private helpers

    private func sendRaw(_ bytes: [UInt8]) async {
        guard isConnected else {
            lastError = ObsbotControllerError.notConnected.localizedDescription
            commandLog = "[raw] Not connected"
            return
        }
        do {
            try await iokit.sendRawSelector6(bytes)
            lastError = nil
            commandLog = "[raw] OK: \(bytes.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " "))"
        } catch {
            lastError = error.localizedDescription
            commandLog = "[raw] Error: \(error.localizedDescription)"
        }
    }

    private func sendRaw(_ builder: @escaping () -> [UInt8]) async {
        await sendRaw(builder())
    }

    private func sendFramed(
        _ commandName: String,
        _ command: @Sendable @escaping (UInt16) -> [UInt8],
        expected: UInt16,
        expectReply: Bool = true
    ) async {
        guard isConnected else {
            lastError = ObsbotControllerError.notConnected.localizedDescription
            commandLog = "[\(commandName)] Not connected"
            return
        }
        do {
            _ = try await iokit.sendFramed(command, expectedCommand: expected, expectReply: expectReply)
            lastError = nil
            commandLog = "[\(commandName)] Sent"
        } catch {
            lastError = error.localizedDescription
            commandLog = "[\(commandName)] Error: \(error.localizedDescription)"
        }
    }

    private func sendStandard(_ commandName: String, _ bytes: [UInt8], selector: UInt16) async {
        guard isConnected else {
            lastError = ObsbotControllerError.notConnected.localizedDescription
            commandLog = "[\(commandName)] Not connected"
            return
        }
        do {
            try await iokit.writeStandardControl(selector: selector, bytes: bytes)
            lastError = nil
            commandLog = "[\(commandName)] OK: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))"
        } catch {
            lastError = error.localizedDescription
            commandLog = "[\(commandName)] Error: \(error.localizedDescription)"
        }
    }

    private func sendStandard(_ bytes: [UInt8]) async {
        await sendStandard("zoom", bytes, selector: ObsbotCommandSet.ctZoomAbsolute)
    }

    private func decodeStatus(_ status: [UInt8]) {
        // Decoding matches the Tiny 2 Lite status layout from `nod`.
        // Tiny 3/3 Lite may move these bytes; the raw dump is always available.
        guard status.count >= 0x1D else { return }

        let modeByte1 = status[0x18]
        let modeByte2 = status[0x1C]
        trackingMode = decodeTrackingMode(modeByte1, modeByte2)
        hdrEnabled = status[0x06] == 0x01

        switch status[0x08] {
        case 0x01: noiseCancellation = .low
        case 0x02: noiseCancellation = .medium
        case 0x03: noiseCancellation = .high
        default:   noiseCancellation = .off
        }
    }

    private func decodeTrackingMode(_ b1: UInt8, _ b2: UInt8) -> ObsbotTrackingMode {
        switch (b1, b2) {
        case (0x00, _): return .off
        case (0x02, 0x00): return .normal
        case (0x02, 0x01): return .upperBody
        case (0x02, 0x02): return .closeUp
        case (0x02, 0x03): return .headless
        case (0x02, 0x04): return .lowerBody
        case (0x04, _): return .whiteboard
        case (0x03, _): return .hand
        default: return .off
        }
    }
}

// MARK: - AVCaptureDevice extension

extension AVCaptureDevice {
    /// Whether this AVFoundation device is a known OBSBOT webcam.
    var isObsbotDevice: Bool {
        localizedName.lowercased().contains("obsbot")
    }

    /// Best-guess model name for UI labels.
    var obsbotDisplayName: String {
        localizedName
    }
}

// MARK: - Tracking mode framing byte

extension ObsbotTrackingMode {
    var framingByte: UInt8 {
        switch self {
        case .off:        return 0x00
        case .normal:     return 0x00
        case .upperBody:  return 0x01
        case .closeUp:    return 0x02
        case .headless:   return 0x03
        case .lowerBody:  return 0x04
        case .whiteboard: return 0x00
        case .hand:       return 0x00
        }
    }
}
