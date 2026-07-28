import Foundation

/// V3-framed command encoder for the OBSBOT Tiny 2/3 vendor extension-unit protocol.
///
/// Reference: `.obsbot-research/obsbot-mcp/tiny2_specification.md` §4.
enum ObsbotV3Protocol {
    static let payloadSize = 60
    static let magic: UInt8 = 0xAA
    static let flagsSet: UInt8 = 0x25 // SET with nested payload
    static let flagsGet: UInt8 = 0x01 // header-only GET
    static let senderHost: UInt8 = 0x0A

    // MARK: - Wire commands

    static let cmdSleep: UInt16 = 0xA0C2
    static let cmdWake: UInt16 = 0xA0C2
    static let cmdRecenter: UInt16 = 0x00C3
    static let cmdGimbalSpeed: UInt16 = 0x6484
    static let cmdGimbalMoveToAngle: UInt16 = 0x6444
    static let cmdGimbalEuler: UInt16 = 0x6404

    static let receiverSystem: UInt8 = 0x02
    static let receiverDevice: UInt8 = 0x03
    static let receiverGimbal: UInt8 = 0x04

    // MARK: - Preset commands

    static let cmdPresetAdd: UInt16 = 0x3944
    static let cmdPresetUpdate: UInt16 = 0x3E04
    static let cmdPresetRecall: UInt16 = 0x39C4
    static let cmdPresetDelete: UInt16 = 0x3984

    // MARK: - CRC-16/USB

    private static let crcPoly: UInt16 = 0xA001

    static func crc16USB(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ crcPoly
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF
    }

    // MARK: - Frame builders

    /// Build a framed V3 SET command with a nested payload.
    ///
    /// - Parameters:
    ///   - cmd: Wire command (little-endian opcode).
    ///   - receiver: Subsystem receiver byte.
    ///   - payload: Nested payload bytes; may be empty for header-only commands.
    ///   - sequence: Sequence number; increments per sent frame.
    /// - Returns: 60-byte frame ready for `SET_CUR` on XU selector `0x02`.
    static func buildSetFrame(cmd: UInt16, receiver: UInt8, payload: [UInt8], sequence: UInt16) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: payloadSize)
        frame[0] = magic
        frame[1] = flagsSet
        frame[2] = UInt8(sequence & 0xFF)
        frame[3] = UInt8((sequence >> 8) & 0xFF)

        // len = 12 for header-only, 16 + payload.count when nested
        let headerLen: UInt16 = payload.isEmpty ? 12 : UInt16(16 + payload.count)
        frame[4] = UInt8(headerLen & 0xFF)
        frame[5] = UInt8((headerLen >> 8) & 0xFF)

        frame[8] = senderHost
        frame[9] = receiver
        frame[10] = UInt8(cmd & 0xFF)
        frame[11] = UInt8((cmd >> 8) & 0xFF)

        if !payload.isEmpty {
            let payloadLen = UInt16(payload.count)
            frame[12] = UInt8(payloadLen & 0xFF)
            frame[13] = UInt8((payloadLen >> 8) & 0xFF)

            // payload CRC over bytes [12, 16 + payloadLen) with token bytes zeroed
            var payloadSegment = [UInt8](repeating: 0, count: 4 + payload.count)
            for i in 0..<payload.count {
                payloadSegment[4 + i] = payload[i]
            }
            let payloadCRC = crc16USB(payloadSegment)
            frame[14] = UInt8(payloadCRC & 0xFF)
            frame[15] = UInt8((payloadCRC >> 8) & 0xFF)

            for i in 0..<payload.count {
                frame[16 + i] = payload[i]
            }
        }

        // Header CRC over bytes [0, headerLen) with token bytes zeroed
        var headerForCRC = Array(frame[0..<Int(headerLen)])
        headerForCRC[6] = 0
        headerForCRC[7] = 0
        let headerCRC = crc16USB(headerForCRC)
        frame[6] = UInt8(headerCRC & 0xFF)
        frame[7] = UInt8((headerCRC >> 8) & 0xFF)

        return frame
    }

    /// Build a header-only GET frame.
    static func buildGetFrame(cmd: UInt16, receiver: UInt8, sequence: UInt16) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: payloadSize)
        frame[0] = magic
        frame[1] = flagsGet
        frame[2] = UInt8(sequence & 0xFF)
        frame[3] = UInt8((sequence >> 8) & 0xFF)
        frame[4] = 12
        frame[5] = 0
        frame[8] = senderHost
        frame[9] = receiver
        frame[10] = UInt8(cmd & 0xFF)
        frame[11] = UInt8((cmd >> 8) & 0xFF)

        var headerForCRC = Array(frame[0..<12])
        headerForCRC[6] = 0
        headerForCRC[7] = 0
        let headerCRC = crc16USB(headerForCRC)
        frame[6] = UInt8(headerCRC & 0xFF)
        frame[7] = UInt8((headerCRC >> 8) & 0xFF)

        return frame
    }

    // MARK: - Convenience command builders

    static func sleepCommand(sequence: UInt16) -> [UInt8] {
        buildSetFrame(cmd: cmdWake, receiver: receiverSystem, payload: [0x01], sequence: sequence)
    }

    static func wakeCommand(sequence: UInt16) -> [UInt8] {
        buildSetFrame(cmd: cmdWake, receiver: receiverSystem, payload: [0x00], sequence: sequence)
    }

    static func recenterCommand(sequence: UInt16) -> [UInt8] {
        buildSetFrame(cmd: cmdRecenter, receiver: receiverDevice, payload: [UInt8](repeating: 0, count: 6), sequence: sequence)
    }

    /// Gimbal speed command: roll, pitch, yaw in degrees per second.
    ///
    /// Vendor/tool convention: pitch positive = down; yaw positive = camera's left.
    /// Provide values as they appear on the wire.
    static func gimbalSpeedCommand(rollDegPerSec: Float, pitchDegPerSec: Float, yawDegPerSec: Float, sequence: UInt16) -> [UInt8] {
        var payload = [UInt8]()
        payload.append(contentsOf: float32Bytes(rollDegPerSec))
        payload.append(contentsOf: float32Bytes(pitchDegPerSec))
        payload.append(contentsOf: float32Bytes(yawDegPerSec))
        return buildSetFrame(cmd: cmdGimbalSpeed, receiver: receiverGimbal, payload: payload, sequence: sequence)
    }

    /// Move gimbal to absolute Euler angle (roll, pitch, yaw in degrees).
    static func gimbalMoveToAngle(roll: Float, pitch: Float, yaw: Float, sequence: UInt16) -> [UInt8] {
        var payload = [UInt8]()
        payload.append(contentsOf: float32Bytes(roll))
        payload.append(contentsOf: float32Bytes(pitch))
        payload.append(contentsOf: float32Bytes(yaw))
        return buildSetFrame(cmd: cmdGimbalMoveToAngle, receiver: receiverGimbal, payload: payload, sequence: sequence)
    }

    /// Preset recall: slot index 0-based.
    static func presetRecallCommand(slot: UInt32, sequence: UInt16) -> [UInt8] {
        var payload = [UInt8]()
        payload.append(contentsOf: uInt32Bytes(slot))
        payload.append(contentsOf: float32Bytes(1.0))
        payload.append(contentsOf: float32Bytes(1.0))
        payload.append(contentsOf: float32Bytes(1.0))
        payload.append(contentsOf: float32Bytes(1.0))
        return buildSetFrame(cmd: cmdPresetRecall, receiver: receiverGimbal, payload: payload, sequence: sequence)
    }

    /// Preset save (add/update): slot index 0-based, pose in degrees, zoom ratio.
    static func presetSaveCommand(slot: UInt32, pan: Float, tilt: Float, roll: Float, zoom: Float, sequence: UInt16) -> [UInt8] {
        var payload = [UInt8]()
        payload.append(contentsOf: uInt32Bytes(slot))
        payload.append(contentsOf: float32Bytes(pan))
        payload.append(contentsOf: float32Bytes(tilt))
        payload.append(contentsOf: float32Bytes(roll))
        payload.append(contentsOf: float32Bytes(zoom))
        payload.append(contentsOf: float32Bytes(-1000.0)) // sentinel for add/update
        return buildSetFrame(cmd: cmdPresetUpdate, receiver: receiverGimbal, payload: payload, sequence: sequence)
    }

    /// Preset delete: slot index 0-based.
    static func presetDeleteCommand(slot: UInt32, sequence: UInt16) -> [UInt8] {
        return buildSetFrame(cmd: cmdPresetDelete, receiver: receiverGimbal, payload: uInt32Bytes(slot), sequence: sequence)
    }

    // MARK: - UVC raw controls (selector 0x06)

    /// Raw HDR/WDR command for selector 0x06.
    static func rawHDR(on: Bool) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: payloadSize)
        payload[0] = 0x01
        payload[1] = on ? 0x01 : 0x00
        return payload
    }

    /// Raw FOV command for selector 0x06.
    static func rawFOV(mode: UInt8) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: payloadSize)
        payload[0] = 0x04
        payload[1] = mode
        return payload
    }

    /// Raw AI tracking command for selector 0x06.
    static func rawTracking(enable: Bool, framing: UInt8) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: payloadSize)
        payload[0] = 0x16
        payload[1] = enable ? 0x02 : 0x00
        payload[2] = framing
        return payload
    }

    // MARK: - Helpers

    static func float32Bytes(_ value: Float) -> [UInt8] {
        var v = value
        var bytes = [UInt8](repeating: 0, count: 4)
        memcpy(&bytes, &v, 4)
        return bytes
    }

    static func uInt32Bytes(_ value: UInt32) -> [UInt8] {
        return [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ]
    }

    static func int32Bytes(_ value: Int32) -> [UInt8] {
        return [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ]
    }

    static func int32FromBytes(_ bytes: [UInt8], offset: Int) -> Int32 {
        guard bytes.count >= offset + 4 else { return 0 }
        return Int32(bytes[offset]) |
               (Int32(bytes[offset + 1]) << 8) |
               (Int32(bytes[offset + 2]) << 16) |
               (Int32(bytes[offset + 3]) << 24)
    }

    static func floatFromBytes(_ bytes: [UInt8], offset: Int) -> Float {
        guard bytes.count >= offset + 4 else { return 0 }
        var bytesCopy = Array(bytes[offset..<offset + 4])
        var value: Float = 0
        memcpy(&value, &bytesCopy, 4)
        return value
    }
}

// MARK: - Frame parsing

extension ObsbotV3Protocol {
    /// Parse a 60-byte V3 reply. Returns nil if the frame is invalid or a stale/no-reply.
    static func parseReply(_ bytes: [UInt8], expectedCommand: UInt16, expectedSequence: UInt16) -> (payload: [UInt8], valid: Bool) {
        guard bytes.count == payloadSize else { return ([], false) }
        guard bytes[0] == magic else { return ([], false) }

        let headerLen = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
        guard headerLen >= 12, headerLen <= payloadSize else { return ([], false) }

        // Header CRC check
        var headerForCRC = Array(bytes[0..<Int(headerLen)])
        headerForCRC[6] = 0
        headerForCRC[7] = 0
        let headerCRC = crc16USB(headerForCRC)
        let storedHeaderCRC = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        guard headerCRC == storedHeaderCRC else { return ([], false) }

        let replyCmd = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)
        let replySeq = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        guard replyCmd == expectedCommand && replySeq == expectedSequence else { return ([], false) }

        if headerLen > 12 {
            let payloadLen = UInt16(bytes[12]) | (UInt16(bytes[13]) << 8)
            guard payloadLen <= 44 else { return ([], false) }
            let payloadStart = 16
            let payloadEnd = min(Int(payloadStart) + Int(payloadLen), payloadSize)
            let payload = Array(bytes[payloadStart..<payloadEnd])

            // Payload CRC check
            var payloadSegment = [UInt8](repeating: 0, count: 4 + payload.count)
            for i in 0..<payload.count {
                payloadSegment[4 + i] = payload[i]
            }
            let payloadCRC = crc16USB(payloadSegment)
            let storedPayloadCRC = UInt16(bytes[14]) | (UInt16(bytes[15]) << 8)
            guard payloadCRC == storedPayloadCRC else { return ([], false) }

            return (payload, true)
        }

        return ([], true)
    }
}
