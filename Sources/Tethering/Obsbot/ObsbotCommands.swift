import Foundation

/// UVC/USB command set for OBSBOT Tiny-series webcams.
/// Based on the reverse-engineered protocol from the open-source `nod` project
/// (Tiny 2 Lite, PID 0xFEF9) and `obsbot-mcp` (Tiny 2, PID 0xFEF8).
/// The Tiny 3 family (Tiny 3 PID 0xFF02, Tiny 3 Lite) appears to share the
/// same command structure, but each model may expose a different subset.
enum ObsbotCommandSet {
    // USB IDs
    static let vendorID: UInt16 = 0x3564

    /// Known OBSBOT model product IDs.
    /// Tiny 3 Lite added from hardware probe: idVendor 0x3564, idProduct 0xFF04.
    static let knownProductIDs: [UInt16] = [
        0xFEF8, // Tiny 2
        0xFEF9, // Tiny 2 Lite
        0xFF02, // Tiny 3
        0xFF04, // Tiny 3 Lite
    ]

    static let payloadSize = 60
    static let uvcSetCur: UInt8 = 0x01
    static let uvcGetCur: UInt8 = 0x81

    /// UVC extension-unit selectors used by the Tiny 2/3 family.
    /// Selector 0x02: framed V3 command channel.
    /// Selector 0x06: raw status/control writes.
    static let selectorXU: UInt16 = 0x02
    static let selectorStatus: UInt16 = 0x06
    static let xuUnit: UInt8 = 0x02

    /// Standard UVC camera-terminal controls.
    static let ctZoomAbsolute: UInt16 = 0x0B
    static let ctZoomRelative: UInt16 = 0x0C
    static let ctPanTiltAbsolute: UInt16 = 0x0D
    static let ctPanTiltRelative: UInt16 = 0x0E
    static let ctUnit: UInt8 = 0x01

    // MARK: - Device control
    static let hdrOn: [UInt8] = [0x01, 0x01, 0x01]
    static let hdrOff: [UInt8] = [0x01, 0x01, 0x00]
    static let gimbalReset: [UInt8] = [0x16, 0x01, 0x00, 0x00]
    static let sleep: [UInt8] = [0x02, 0x01, 0x01]
    static let wake: [UInt8] = [0x02, 0x01, 0x00]
}

// MARK: - Tracking mode

enum ObsbotTrackingMode: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case normal = "Normal"
    case upperBody = "Upper Body"
    case closeUp = "Close-up"
    case headless = "Headless"
    case lowerBody = "Lower Body"
    case whiteboard = "Whiteboard"
    case hand = "Hand"

    var id: String { rawValue }

    var commandBytes: [UInt8] {
        switch self {
        case .off:        return [0x16, 0x02, 0x00, 0x00]
        case .normal:     return [0x16, 0x02, 0x02, 0x00]
        case .upperBody:  return [0x16, 0x02, 0x02, 0x01]
        case .closeUp:    return [0x16, 0x02, 0x02, 0x02]
        case .headless:   return [0x16, 0x02, 0x02, 0x03]
        case .lowerBody:  return [0x16, 0x02, 0x02, 0x04]
        case .whiteboard: return [0x16, 0x02, 0x04, 0x00]
        case .hand:       return [0x16, 0x02, 0x03, 0x00]
        }
    }
}

// MARK: - FOV

enum ObsbotFOVMode: String, CaseIterable, Identifiable, Sendable {
    case wide = "Wide (86°)"
    case normal = "Normal (78°)"
    case narrow = "Narrow (65°)"

    var id: String { rawValue }

    var wireValue: UInt8 {
        switch self {
        case .wide:   return 0x01
        case .normal: return 0x02
        case .narrow: return 0x03
        }
    }

    var commandBytes: [UInt8] {
        switch self {
        case .wide:   return [0x04, 0x01, 0x01]
        case .normal: return [0x04, 0x01, 0x02]
        case .narrow: return [0x04, 0x01, 0x03]
        }
    }
}

// MARK: - Noise cancellation (on-camera mic DSP)

enum ObsbotNoiseCancellation: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case low = "Weak"
    case medium = "Medium"
    case high = "Strong"

    var id: String { rawValue }

    var commandBytes: [UInt8] {
        switch self {
        case .off:    return [0x0A, 0x01, 0x00]
        case .low:    return [0x0A, 0x01, 0x01]
        case .medium: return [0x0A, 0x01, 0x02]
        case .high:   return [0x0A, 0x01, 0x03]
        }
    }
}

// MARK: - Device model

struct ObsbotModel: Sendable {
    let productID: UInt16
    let name: String
}

extension ObsbotModel {
    static let tiny2 = ObsbotModel(productID: 0xFEF8, name: "OBSBOT Tiny 2")
    static let tiny2Lite = ObsbotModel(productID: 0xFEF9, name: "OBSBOT Tiny 2 Lite")
    static let tiny3 = ObsbotModel(productID: 0xFF02, name: "OBSBOT Tiny 3")
    static let tiny3Lite = ObsbotModel(productID: 0xFF04, name: "OBSBOT Tiny 3 Lite")
}
