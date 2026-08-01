import Foundation

/// Supported ingest protocols for the bundled FFmpeg listener.
enum IngestProtocol: String, CaseIterable, Identifiable, Codable, Sendable {
    case rtmp = "RTMP"
    case srt = "SRT"
    case rtp = "RTP"

    var id: String { rawValue }

    var defaultPort: Int {
        switch self {
        case .rtmp: return 1935
        case .srt: return 5000
        case .rtp: return 5004
        }
    }

    var scheme: String {
        switch self {
        case .rtmp: return "rtmp"
        case .srt: return "srt"
        case .rtp: return "rtp"
        }
    }
}

/// A single running or configured ingest endpoint.
struct IngestSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var streamProtocol: IngestProtocol
    var port: Int
    var path: String
    var isEnabled: Bool
    var autoRestart: Bool
    var saveToFile: Bool
    var outputDirectory: String?

    var inputURL: String {
        switch streamProtocol {
        case .rtmp:
            return "\(streamProtocol.scheme)://0.0.0.0:\(port)\(path)"
        case .srt:
            return "srt://0.0.0.0:\(port)?mode=listener"
        case .rtp:
            return "rtp://0.0.0.0:\(port)"
        }
    }

    var displayName: String {
        "\(streamProtocol.rawValue) :\(port)\(path)"
    }

    static func `default`(streamProtocol: IngestProtocol = .rtmp) -> IngestSession {
        IngestSession(
            id: UUID(),
            streamProtocol: streamProtocol,
            port: streamProtocol.defaultPort,
            path: "/live/stream",
            isEnabled: true,
            autoRestart: true,
            saveToFile: false,
            outputDirectory: nil
        )
    }
}

/// Runtime status for an ingest session.
enum IngestStatus: String, Sendable {
    case idle = "Idle"
    case starting = "Starting"
    case listening = "Listening"
    case receiving = "Receiving"
    case stopped = "Stopped"
    case error = "Error"
}

/// A snapshot of a running ingest session suitable for UI updates.
struct IngestRuntimeSnapshot: Sendable {
    let sessionID: UUID
    let status: IngestStatus
    let pid: Int32?
    let logs: [String]
    let error: String?
    let bytesReceived: Int64?
    let duration: TimeInterval?
}
