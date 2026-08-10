import SwiftUI
import AppKit

// MARK: - Mail settings tab

/// Settings for the Apple Mail integration: Full Disk Access for the
/// Envelope Index and the Mail automation bridge.
struct MailSettingsTab: View {
    @Environment(ThemeStore.self) private var theme
    @State private var mailService = AppleMailService.shared
    @State private var envelope = MailEnvelopeIndex.shared
    @AppStorage("appleMail.loadRemoteImages") private var loadRemoteImages = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Message Index (Full Disk Access)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(indexStatusColor)
                                .frame(width: 8, height: 8)
                            Text(indexStatusText)
                                .font(.callout)
                            Spacer()
                            if envelope.needsFullDiskAccess && !envelope.isAvailable {
                                Button("Open Settings…") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .font(.caption)
                            }
                        }
                        Text("Message lists read Mail's Envelope Index (SQLite) directly — instant even "
                            + "while Mail is syncing. macOS protects that folder: grant SwiftMaestro "
                            + "Full Disk Access, then quit and relaunch.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                GroupBox("Apple Mail Bridge") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SwiftMaestro drives Mail.app via macOS automation (Apple Events). The first "
                            + "time you compose a draft or read a message, macOS asks for permission to "
                            + "control Mail — grant it once and it sticks.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Load remote images in emails", isOn: $loadRemoteImages)
                        Text("Off by default: remote images can be used for tracking. You can still load "
                            + "them per message from the banner above an email's body.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Mail") { mailService.openMail() }
                    }
                    .padding(8)
                }

                Spacer()
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            if !envelope.isAvailable { envelope.open() }
        }
    }

    private var indexStatusColor: Color {
        if envelope.isAvailable { return .green }
        return envelope.needsFullDiskAccess ? .orange : .red
    }

    private var indexStatusText: String {
        if envelope.isAvailable { return "Envelope Index readable" }
        if envelope.needsFullDiskAccess { return "Blocked — grant Full Disk Access and relaunch" }
        return "Not readable: \(envelope.lastError ?? "unknown")"
    }
}
