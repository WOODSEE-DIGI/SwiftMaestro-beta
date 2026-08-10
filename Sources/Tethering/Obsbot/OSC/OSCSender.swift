import Foundation
import Network

/// Minimal OSC encoder and UDP sender for OBSBOT Center.
///
/// OBSBOT Center (macOS) listens for OSC messages and translates them to webcam control.
/// This avoids reverse-engineering USB/UVC by delegating device control to the official app.
enum OSCMessage {
    case message(address: String, arguments: [OSCArgument])
}

enum OSCArgument {
    case int32(Int32)
    case float32(Float)
    case string(String)

    var typeTag: Character {
        switch self {
        case .int32: return "i"
        case .float32: return "f"
        case .string: return "s"
        }
    }

    func append(to data: inout Data) {
        switch self {
        case .int32(let value):
            data.append(contentsOf: value.bigEndianBytes)
        case .float32(let value):
            var bigEndian = value.bitPattern.bigEndian
            data.append(Data(bytes: &bigEndian, count: 4))
        case .string(let value):
            data.append(oscStringBytes(value))
        }
    }
}

extension Int32 {
    var bigEndianBytes: [UInt8] {
        return [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
    }
}

/// Pack a NUL-terminated string padded to a 4-byte boundary.
private func oscStringBytes(_ string: String) -> Data {
    var data = Data(string.utf8)
    data.append(0)
    let pad = (4 - (data.count % 4)) % 4
    data.append(contentsOf: [UInt8](repeating: 0, count: pad))
    return data
}

extension OSCMessage {
    var data: Data {
        switch self {
        case .message(let address, let arguments):
            var data = Data()
            data.append(oscStringBytes(address))
            var typeTag = ","
            for arg in arguments { typeTag.append(arg.typeTag) }
            data.append(oscStringBytes(typeTag))
            for arg in arguments { arg.append(to: &data) }
            return data
        }
    }
}

/// UDP sender for OSC messages.
@MainActor
final class OSCUDPSender: @unchecked Sendable {
    private var connection: NWConnection?
    private let endpoint: NWEndpoint
    private let queue = DispatchQueue(label: "swiftmaestro.osc")
    private let host: String
    private let port: UInt16

    var isConnected: Bool { connection != nil }

    init(host: String = "127.0.0.1", port: UInt16 = 16284) {
        self.host = host
        self.port = port
        self.endpoint = .hostPort(host: .init(host), port: .init(integerLiteral: port))
    }

    func connect() {
        disconnect()
        let conn = NWConnection(to: endpoint, using: .udp)
        conn.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[OSC] connection failed: \(error)")
            }
        }
        conn.start(queue: queue)
        connection = conn
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    func send(_ message: OSCMessage) {
        guard let connection = connection else { return }
        let data = message.data
        #if DEBUG
        // Verbose hex logging is disabled by default to avoid console spam and CPU overhead.
        // Re-enable only when diagnosing packet-level OSC issues.
        // let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        // let ascii = data.map { (32...126).contains($0) ? String(Character(UnicodeScalar($0))) : "." }.joined()
        // print("[OSC] sending \(data.count) bytes to \(host):\(port)")
        // print("[OSC] hex: \(hex)")
        // print("[OSC] asc: \(ascii)")
        #endif
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[OSC] send error: \(error)")
            }
        })
    }

    deinit {
        connection?.cancel()
    }
}
