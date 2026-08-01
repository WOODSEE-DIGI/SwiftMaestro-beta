import Foundation
import Network
import Combine

/// Discovers NDI sources on the local network via mDNS/Bonjour. The NDI SDK is
/// not required for discovery; actual preview/ingest requires the NDI runtime.
@MainActor
final class NDIBrowserService: ObservableObject {
    static let shared = NDIBrowserService()

    @Published private(set) var sources: [NDISource] = []
    @Published private(set) var isScanning = false
    @Published var error: String?

    private var browser: NWBrowser?
    private var scanTask: Task<Void, Never>?

    private init() {}

    func startScan() {
        stopScan()
        sources = []
        error = nil
        isScanning = true

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_ndi._tcp", domain: nil), using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed(let err):
                    self?.error = err.localizedDescription
                    self?.isScanning = false
                case .cancelled:
                    self?.isScanning = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.sources = results.map { result in
                    let name = result.endpoint.debugDescription
                    return NDISource(
                        id: UUID(),
                        name: name,
                        endpoint: name,
                        isAvailable: true
                    )
                }
            }
        }

        browser.start(queue: .global(qos: .background))
    }

    func stopScan() {
        browser?.cancel()
        browser = nil
        isScanning = false
    }

    deinit {
        browser?.cancel()
    }
}

struct NDISource: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var endpoint: String
    var isAvailable: Bool
}
