import SwiftUI

@main
struct SwiftMaestroApp: App {
    @State private var engine = MLXInferenceEngine()
    @State private var catalog = ModelCatalog()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .environment(catalog)
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(engine)
                .environment(catalog)
        }
        #endif
    }
}
