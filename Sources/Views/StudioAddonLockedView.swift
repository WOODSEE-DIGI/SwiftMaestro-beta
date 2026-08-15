import SwiftUI

/// Placeholder shown in place of a Studio feature while the Studio add-on is
/// locked. Explains that Studio is an optional, not-yet-ready add-on and offers
/// an inline enable toggle (the same `StudioAddon.isAvailable` gate).
struct StudioAddonLockedView: View {
    @State private var addon = StudioAddon.shared

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Studio Add-on")
                .font(.title2.bold())
            Text("Cameras, Stream Ingest, Broadcast, Stream Mixer, NDI Browser, Color Adjustments, and Scenes are an optional add-on that isn't ready yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Toggle(isOn: $addon.isAvailable) {
                Text("Enable Studio (beta)")
            }
            .toggleStyle(.switch)
            .frame(maxWidth: 210)
            Text("Off by default while it's under development.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
