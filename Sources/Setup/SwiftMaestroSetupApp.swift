import SwiftUI

@main
struct SwiftMaestroSetupApp: App {
    @State private var viewModel = SetupViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .frame(minWidth: 560, minHeight: 460)
                .tint(Color(red: 1.0, green: 0.18, blue: 0.53))
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}