import Foundation

/// Supported broadcast (publisher) protocols.
enum BroadcastProtocol: String, CaseIterable, Identifiable, Codable, Sendable {
    case rtmp = "RTMP"
    case srt = "SRT"
    case rtmps = "RTMPS"

    var id: String { rawValue }

    var defaultPort: Int {
        switch self {
        case .rtmp: return 1935
        case .srt: return 5000
        case .rtmps: return 443
        }
    }
}

/// A configured broadcast destination.
struct BroadcastSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var inputURL: String
    var broadcastProtocol: BroadcastProtocol
    var serverURL: String
    var streamKey: String
    var isEnabled: Bool

    var outputURL: String {
        let separator = serverURL.hasSuffix("/") ? "" : "/"
        switch broadcastProtocol {
        case .rtmp, .rtmps:
            return "\(broadcastProtocol.rawValue.lowercased())://\(serverURL)\(separator)\(streamKey)"
        case .srt:
            return "srt://\(serverURL)\(separator)\(streamKey)"
        }
    }

    static func `default`() -> BroadcastSession {
        presets[0]
    }

    static var presets: [BroadcastSession] {
        [
            BroadcastSession(
                id: UUID(),
                name: "Twitch",
                inputURL: "rtmp://localhost:1935/live/stream",
                broadcastProtocol: .rtmp,
                serverURL: "live.twitch.tv/live",
                streamKey: "",
                isEnabled: true
            ),
            BroadcastSession(
                id: UUID(),
                name: "YouTube",
                inputURL: "rtmp://localhost:1935/live/stream",
                broadcastProtocol: .rtmp,
                serverURL: "a.rtmp.youtube.com/live2",
                streamKey: "",
                isEnabled: true
            ),
            BroadcastSession(
                id: UUID(),
                name: "Facebook Live",
                inputURL: "rtmp://localhost:1935/live/stream",
                broadcastProtocol: .rtmps,
                serverURL: "live-api-s.facebook.com:443/rtmp",
                streamKey: "",
                isEnabled: true
            ),
            BroadcastSession(
                id: UUID(),
                name: "Instagram Live",
                inputURL: "rtmp://localhost:1935/live/stream",
                broadcastProtocol: .rtmps,
                serverURL: "live-upload.instagram.com:443/rtmp",
                streamKey: "",
                isEnabled: true
            ),
            BroadcastSession(
                id: UUID(),
                name: "TikTok LIVE",
                inputURL: "rtmp://localhost:1935/live/stream",
                broadcastProtocol: .rtmps,
                serverURL: "push.rtmp.tiktok.com/live",
                streamKey: "",
                isEnabled: true
            ),
            BroadcastSession(
                id: UUID(),
                name: "LinkedIn Live",
                inputURL: "rtmp://localhost:1935/live/stream",
                broadcastProtocol: .rtmp,
                serverURL: "live.linkedin.com/live",
                streamKey: "",
                isEnabled: true
            ),
            BroadcastSession(
                id: UUID(),
                name: "X / Twitter",
                inputURL: "rtmp://localhost:1935/live/stream",
                broadcastProtocol: .rtmps,
                serverURL: "x.pscp.tv:443/x",
                streamKey: "",
                isEnabled: true
            ),
            BroadcastSession(
                id: UUID(),
                name: "Kick",
                inputURL: "rtmp://localhost:1935/live/stream",
                broadcastProtocol: .rtmp,
                serverURL: "rtmp.kick.com/live",
                streamKey: "",
                isEnabled: true
            ),
            BroadcastSession(
                id: UUID(),
                name: "Vimeo Live",
                inputURL: "rtmp://localhost:1935/live/stream",
                broadcastProtocol: .rtmp,
                serverURL: "rtmp.vimeo.com/live",
                streamKey: "",
                isEnabled: true
            ),
            BroadcastSession(
                id: UUID(),
                name: "DLive",
                inputURL: "rtmp://localhost:1935/live/stream",
                broadcastProtocol: .rtmp,
                serverURL: "stream.dlive.tv/live",
                streamKey: "",
                isEnabled: true
            )
        ]
    }
}

enum BroadcastStatus: String, Sendable {
    case idle = "Idle"
    case starting = "Starting"
    case live = "Live"
    case stopped = "Stopped"
    case error = "Error"
}

struct BroadcastRuntimeSnapshot: Sendable {
    let sessionID: UUID
    let status: BroadcastStatus
    let pid: Int32?
    let logs: [String]
    let error: String?
    let duration: TimeInterval?
}
