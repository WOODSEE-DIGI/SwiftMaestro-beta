import Foundation

/// Broadcasts AI activity events via `DistributedNotificationCenter` so that
/// external apps (e.g. ApexFlow) can monitor SwiftMaestro's inference state
/// without polling or XPC.
enum AIBroadcastService: Sendable {

    // MARK: - Notification Names

    static let generationStarted   = Notification.Name("com.woodseedigi.swiftmaestro.generationStarted")
    static let generationCompleted = Notification.Name("com.woodseedigi.swiftmaestro.generationCompleted")
    static let generationFailed    = Notification.Name("com.woodseedigi.swiftmaestro.generationFailed")
    static let generationCancelled = Notification.Name("com.woodseedigi.swiftmaestro.generationCancelled")
    static let tokenRateUpdate     = Notification.Name("com.woodseedigi.swiftmaestro.tokenRateUpdate")
    static let toolStarted         = Notification.Name("com.woodseedigi.swiftmaestro.toolStarted")
    static let toolCompleted       = Notification.Name("com.woodseedigi.swiftmaestro.toolCompleted")

    // MARK: - Payload Keys

    static let keyModelName    = "modelName"
    static let keyTokensPerSec = "tokensPerSecond"
    static let keyTotalTokens  = "totalTokens"
    static let keyToolName     = "toolName"
    static let keyToolID       = "toolID"
    static let keyDuration     = "duration"
    static let keyError        = "error"
    static let keyAppName      = "appName"

    /// The display name included in every notification so the receiver knows
    /// which AI app is broadcasting.
    private static let appName = "SwiftMaestro"

    // MARK: - Throttled Token Rate (nonisolated unsafe for perf path)

    nonisolated(unsafe) private static var lastRateBroadcast: TimeInterval = 0
    nonisolated(unsafe) private static var pendingTotalTokens: Int = 0
    nonisolated(unsafe) private static var pendingTokensPerSec: Double = 0

    // MARK: - Public API

    static func broadcastGenerationStarted(modelName: String) {
        post(name: generationStarted, payload: [
            keyAppName: appName, keyModelName: modelName
        ])
    }

    static func broadcastGenerationCompleted(
        modelName: String, totalTokens: Int, tokensPerSecond: Double
    ) {
        post(name: generationCompleted, payload: [
            keyAppName: appName, keyModelName: modelName,
            keyTotalTokens: totalTokens, keyTokensPerSec: tokensPerSecond
        ])
    }

    static func broadcastGenerationFailed(modelName: String, error: String) {
        post(name: generationFailed, payload: [
            keyAppName: appName, keyModelName: modelName, keyError: error
        ])
    }

    static func broadcastGenerationCancelled(modelName: String) {
        post(name: generationCancelled, payload: [
            keyAppName: appName, keyModelName: modelName
        ])
    }

    /// Call on every token. Broadcasts at most once per second.
    static func recordToken(totalTokens: Int, tokensPerSecond: Double) {
        pendingTotalTokens = totalTokens
        pendingTokensPerSec = tokensPerSecond
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRateBroadcast >= 1.0 else { return }
        lastRateBroadcast = now
        post(name: tokenRateUpdate, payload: [
            keyAppName: appName,
            keyTotalTokens: pendingTotalTokens,
            keyTokensPerSec: pendingTokensPerSec
        ])
    }

    static func broadcastToolStarted(name toolName: String, id: String) {
        post(name: toolStarted, payload: [
            keyAppName: appName, keyToolName: toolName, keyToolID: id
        ])
    }

    static func broadcastToolCompleted(
        name toolName: String, id: String, duration: TimeInterval
    ) {
        post(name: toolCompleted, payload: [
            keyAppName: appName, keyToolName: toolName,
            keyToolID: id, keyDuration: duration
        ])
    }

    // MARK: - Private

    private static func post(name: Notification.Name, payload: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: Bundle.main.bundleIdentifier,
            userInfo: payload,
            deliverImmediately: true
        )
    }
}
