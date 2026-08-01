import SwiftUI
import AppKit

// MARK: - Mail settings tab (OwnTrack relay)

/// Settings for the Apple Mail integration and the embedded OwnTrack
/// tracking relay. The relay listens on localhost:8087 and serves tracking
/// pixels / click redirects for messages sent through Mail.app.
struct MailSettingsTab: View {
    @Environment(ThemeStore.self) private var theme
    @State private var mailService = AppleMailService.shared
    @State private var relayManager = OwnTrackRelayManager.shared
    @State private var envelope = MailEnvelopeIndex.shared
    @State private var health: Bool?
    @AppStorage("appleMail.loadRemoteImages") private var loadRemoteImages = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Embedded Tracking Relay") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                            Text(statusText)
                                .font(.callout)
                            Spacer()
                            if relayManager.isRunning {
                                Button("Stop Relay") { relayManager.stopRelay(); refreshHealth() }
                            } else {
                                Button("Start Relay") { relayManager.startRelay(); refreshHealth() }
                            }
                        }
                        if let error = relayManager.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Toggle("Start relay automatically at launch", isOn: Bindable(relayManager).autoStartRelay)
                        Text("The relay runs inside SwiftMaestro — nothing external to install. It records "
                            + "open and click events for tracked messages and persists them as JSON.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                GroupBox("Relay Endpoint") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Base URL") {
                            TextField("http://localhost:8087", text: Bindable(mailService).relayBaseURLString)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())
                        }
                        Text("Localhost works for tracking messages you open yourself. For tracking opens "
                            + "on other people's machines, this must be a publicly reachable URL "
                            + "(e.g. https://track.woodsee.com) that forwards to the relay — the pixel "
                            + "fires on the recipient's device.")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Event store") {
                            HStack {
                                Text(relayManager.storeURL.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button("Reveal") {
                                    try? FileManager.default.createDirectory(
                                        at: relayManager.storeURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                                    NSWorkspace.shared.activateFileViewerSelecting([relayManager.storeURL])
                                }
                                .font(.caption)
                            }
                        }
                        Text("Same JSON format as the standalone TrackingRelayServer — existing "
                            + "relay-store.json files can be dropped in directly.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

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
                        Text("Off by default: remote images are also tracking pixels. You can still load "
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
            refreshHealth()
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

    private var statusColor: Color {
        switch health {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary
        }
    }

    private var statusText: String {
        switch health {
        case .some(true):
            return relayManager.isRunning ? "Embedded relay running" : "Relay reachable (external)"
        case .some(false): return "Relay offline"
        case .none: return "Checking…"
        }
    }

    private func refreshHealth() {
        Task {
            health = await mailService.checkRelayHealth()
        }
    }
}
