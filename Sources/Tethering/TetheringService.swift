import Foundation
import Observation

/// Central service that discovers capture sources and manages active sessions.
@MainActor
@Observable
final class TetheringService: Sendable {
    static let shared = TetheringService()

    let destination = CaptureDestination()

    private(set) var availableSources: [any CaptureSource] = []
    private(set) var sessions: [CaptureSourceID: CaptureSession] = [:]
    private(set) var discoveryError: String?
    private(set) var isDiscovering = false
    var selectedSourceID: CaptureSourceID? = nil

    private let enumerators: [CaptureSourceEnumerator] = [
        PTPSourceEnumerator(),
        AVCaptureSourceEnumerator(),
        NDISourceEnumerator()
    ]

    private init() {}

    func discover() async {
        isDiscovering = true
        discoveryError = nil
        defer { isDiscovering = false }

        var found: [any CaptureSource] = []
        await withTaskGroup(of: CaptureSourceDiscovery.self) { group in
            for enumerator in enumerators {
                group.addTask {
                    await enumerator.discover()
                }
            }
            for await result in group {
                switch result {
                case .available(let sources):
                    found.append(contentsOf: sources)
                case .error(let message):
                    discoveryError = message
                }
            }
        }

        // Preserve selection if the ID is still present; otherwise try to match by name.
        let previousSelection = selectedSourceID
        let previousName = previousSelection.flatMap { id in sessions[id]?.source.name }
        availableSources = found

        if let previousSelection, availableSources.contains(where: { $0.id == previousSelection }) {
            // Keep existing selection.
        } else if let previousName,
                  let fallback = availableSources.first(where: { $0.name == previousName }) {
            selectedSourceID = fallback.id
        } else if selectedSourceID != nil, availableSources.isEmpty {
            selectedSourceID = nil
        }
    }

    func session(for source: any CaptureSource) -> CaptureSession {
        if let existing = sessions[source.id] {
            return existing
        }
        let session = CaptureSession(source: source, destination: destination)
        sessions[source.id] = session
        return session
    }

    func disconnectAll() async {
        for (_, session) in sessions {
            await session.disconnect()
        }
        sessions.removeAll()
    }

    func removeSession(_ id: CaptureSourceID) async {
        if let session = sessions[id] {
            await session.disconnect()
            sessions.removeValue(forKey: id)
        }
    }
}
