import Foundation
#if ENABLE_APP_INTENTS
import AppIntents

/// Exposes SwiftMaestro App Intents to Siri, Shortcuts, and Spotlight.
struct SwiftMaestroAppIntentsPackage: AppIntentsPackage {
    static var includedIntents: [any AppIntent.Type] {
        [
            AskAgentIntent.self,
            StartRecordingIntent.self
        ]
    }
}
#endif
