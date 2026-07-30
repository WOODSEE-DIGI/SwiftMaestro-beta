import Foundation

/// Feature gate for the Studio add-on (Cameras, Stream Ingest, Broadcast,
/// Stream Mixer, NDI Browser, Color Adjustments, Scenes).
///
/// Studio is not production-ready, so it ships LOCKED by default. A Settings →
/// Add-ons toggle (or the toggle inside the locked panel) opens it for
/// development. The eventual free-vs-donation/paid decision plugs into this
/// single `isAvailable` seam — no payment or licensing code lives here.
@Observable
@MainActor
final class StudioAddon {
    static let shared = StudioAddon()

    private static let enabledKey = "addon.studio.enabled"

    /// Whether the Studio add-on is unlocked. Persisted across launches.
    var isAvailable: Bool {
        didSet { UserDefaults.standard.set(isAvailable, forKey: Self.enabledKey) }
    }

    private init() {
        self.isAvailable = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }
}

extension WorkspacePanelKind {
    /// Whether this panel belongs to the Studio add-on (the "Studio" sidebar section).
    var isStudioApp: Bool {
        switch self {
        case .tethering, .streamIngest, .broadcast, .streamMixer,
             .ndiBrowser, .colorAdjustments, .scenes:
            return true
        default:
            return false
        }
    }
}
