import Foundation
import SwiftUI
import Sparkle

/// Manages Sparkle's automatic update checking for SwiftMaestro.
///
/// The `SPUStandardUpdaterController` is created once at app launch. It reads the
/// `SUFeedURL` and `SUPublicEDKey` from `Info.plist`, checks the appcast on the
/// schedule configured there, and presents the standard update UI.
@MainActor
@Observable
final class SparkleUpdaterService {

    static let shared = SparkleUpdaterService()

    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Trigger the standard Sparkle "Check for Updates" flow manually.
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
