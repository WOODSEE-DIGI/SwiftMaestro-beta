import Foundation
import Sparkle

/// Manages Sparkle's automatic update checking for SwiftMaestro.
///
/// This service creates and owns a single `SPUUpdater` instance configured with
/// the standard user driver and the app's `Info.plist` (`SUFeedURL`,
/// `SUPublicEDKey`, `SUEnableAutomaticChecks`, etc.). It also acts as the
/// updater delegate so every stage of an update check/download/install cycle is
/// logged. Sparkle's generic "An error occurred while downloading the update"
/// dialog hides the underlying failure, so having detailed Console logs is
/// essential for diagnosing delta-update failures.
@MainActor
@Observable
final class SparkleUpdaterService: NSObject {

    static let shared = SparkleUpdaterService()

    // `SPUUpdater`'s delegate is supplied at initialization time and weakly
    // referenced, so we initialize the updater after `super.init()` so we can
    // pass `self`. The implicitly-unwrapped optional is safe because the
    // singleton never releases it.
    private var updater: SPUUpdater!

    /// Recent update-cycle events, newest first. Kept small so it doesn't grow
    /// unbounded; used for debugging when a user reports update failures.
    private(set) var recentEvents: [String] = []
    private let maxRecentEvents = 50

    override init() {
        super.init()

        let hostBundle = Bundle.main
        let userDriver = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: self
        )

        // Start the updater. If the Info.plist feed URL or public key is
        // missing, this fails silently in release but logs in Console.
        do {
            _ = try updater.start()
        } catch {
            logEvent("Failed to start updater: \(error.localizedDescription)")
        }
    }

    /// Trigger the standard Sparkle "Check for Updates" flow manually.
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    private func logEvent(_ message: String) {
        let timestamp = DateFormatter.localizedString(
            from: Date(),
            dateStyle: .none,
            timeStyle: .medium
        )
        let entry = "[\(timestamp)] \(message)"
        recentEvents.insert(entry, at: 0)
        if recentEvents.count > maxRecentEvents {
            recentEvents.removeLast()
        }
        NSLog("[SparkleUpdaterService] \(entry)")
    }
}

// MARK: - SPUUpdaterDelegate

extension SparkleUpdaterService: SPUUpdaterDelegate {

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        logEvent("Appcast loaded with \(appcast.items.count) item(s)")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        var details = "versionString=\(item.versionString)"
        details += ", displayVersionString=\(item.displayVersionString)"
        details += ", fileURL=\(item.fileURL?.absoluteString ?? "nil")"
        if let deltaItems = item.deltaUpdates, !deltaItems.isEmpty {
            let versions = deltaItems.map { $0.value.versionString }.joined(separator: ", ")
            details += ", deltaUpdates=[\(versions)]"
        } else {
            details += ", deltaUpdates=[]"
        }
        logEvent("Found valid update: \(details)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        logEvent("No update found: \(error.localizedDescription)")
    }

    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        logEvent("Will download update from \(request.url?.absoluteString ?? "nil")")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        logEvent("Downloaded update: \(item.versionString)")
    }

    func updater(
        _ updater: SPUUpdater,
        failedToDownloadUpdate item: SUAppcastItem,
        error: Error
    ) {
        let nsError = error as NSError
        var description = nsError.localizedDescription
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            description += " (underlying: \(underlying.localizedDescription))"
        }
        logEvent("FAILED to download update \(item.versionString): \(description)")
        logEvent("Failed item fileURL: \(item.fileURL?.absoluteString ?? "nil")")
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        logEvent("Will extract update: \(item.versionString)")
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        logEvent("Extracted update: \(item.versionString)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        logEvent("Will install update: \(item.versionString)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        var description = nsError.localizedDescription
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            description += " | underlying: \(underlying.localizedDescription)"
        }
        logEvent("Update cycle ABORTED: \(description) (domain=\(nsError.domain), code=\(nsError.code))")
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if let error {
            logEvent("Update cycle finished with error: \(error.localizedDescription)")
        } else {
            logEvent("Update cycle finished successfully (check=\(updateCheck))")
        }
    }
}
