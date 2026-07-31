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
    @State private var health: Bool?

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

                GroupBox("Apple Mail Bridge") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SwiftMaestro drives Mail.app via macOS automation (Apple Events). The first "
                            + "time you compose a draft or read a message, macOS asks for permission to "
                            + "control Mail — grant it once and it sticks.")
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
        .onAppear { refreshHealth() }
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
