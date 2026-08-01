import Foundation

/// A simple routing rule in the Stream Mixer: copy/transcode from a source to
/// a destination. This can bridge a Stream Ingest endpoint to a Broadcast
/// destination, or route any custom FFmpeg input to any output.
struct MixerRoute: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var sourceURL: String
    var destinationURL: String
    var isEnabled: Bool
    var transcode: Bool
    var videoBitrate: String
    var audioBitrate: String

    static func `default`() -> MixerRoute {
        MixerRoute(
            id: UUID(),
            name: "Ingest → Broadcast",
            sourceURL: "rtmp://localhost:1935/live/stream",
            destinationURL: "rtmp://live.twitch.tv/live/",
            isEnabled: true,
            transcode: false,
            videoBitrate: "2500k",
            audioBitrate: "128k"
        )
    }
}

enum MixerRouteStatus: String, Sendable {
    case idle = "Idle"
    case starting = "Starting"
    case active = "Active"
    case stopped = "Stopped"
    case error = "Error"
}

struct MixerRouteSnapshot: Sendable {
    let routeID: UUID
    let status: MixerRouteStatus
    let pid: Int32?
    let logs: [String]
    let error: String?
    let duration: TimeInterval?
}
