import SwiftUI

/// Minimal 3-page welcome screen shown on first launch.
/// Page 1: What SwiftMaestro is. Page 2: Privacy. Page 3: iCloud choice.
struct WelcomeView: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(MLXInferenceEngine.self) private var engine
    let onDone: () -> Void

    @State private var page = 0
    @State private var useICloud = true
    @State private var isICloudAvailable = true

    var body: some View {
        VStack(spacing: 0) {
            // Page indicator
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 16)

            // Pages
            ZStack {
                switch page {
                case 0: introPage
                case 1: privacyPage
                case 2: icloudPage
                default: introPage
                }
            }
            .animation(.easeInOut(duration: 0.25), value: page)

            // Navigation
            HStack {
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Spacer()
                if page < 2 {
                    Button(page == 0 ? "Get Started" : "Next") { page += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Using SwiftMaestro") { applyAndDismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 420)
        .interactiveDismissDisabled()
        .onAppear {
            isICloudAvailable = NotesiCloudSupport.iCloudVaultURL != nil
            if !isICloudAvailable { useICloud = false }
        }
    }

    // MARK: - Page 1: Welcome

    private var introPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to SwiftMaestro")
                        .font(.largeTitle.bold())
                    Text("Your personal AI assistant, fully on-device.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            Text("SwiftMaestro runs AI models directly on your Apple Silicon Mac. No servers, no accounts, no cloud — everything stays on your machine.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Page 2: Privacy

    private var privacyPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Privacy-First Design", systemImage: "lock.shield")
                .font(.title2.bold())

            privacyRow(icon: "cpu", title: "100% Local Inference",
                       desc: "AI models run on your GPU. Your conversations never leave this Mac.")
            privacyRow(icon: "lock.fill", title: "No Account Required",
                       desc: "No sign-up, no telemetry, no analytics. Open and use immediately.")
            privacyRow(icon: "key.fill", title: "Keychain Security",
                       desc: "Credentials stored in the macOS Keychain — never in plain text.")
            privacyRow(icon: "icloud.fill", title: "iCloud is Optional",
                       desc: "Notes sync via iCloud Drive or stay fully local. You choose.")

            Spacer()
        }
        .padding(32)
    }

    private func privacyRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Page 3: iCloud Permission

    private var icloudPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Notes.md Sync", systemImage: "icloud.and.arrow.up")
                .font(.title2.bold())

            Text("SwiftMaestro includes a built-in Markdown notes vault. Choose where your notes are stored:")
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                iCloudOption(
                    icon: "icloud.fill", title: "Sync with iCloud Drive",
                    desc: "Notes sync across all your Apple devices via iCloud.",
                    selected: useICloud && isICloudAvailable,
                    enabled: isICloudAvailable
                ) { useICloud = true }

                iCloudOption(
                    icon: "folder.fill", title: "Store Locally",
                    desc: "Notes stay in ~/Documents/SwiftMaestro Notes. No sync.",
                    selected: !useICloud || !isICloudAvailable,
                    enabled: true
                ) { useICloud = false }
            }

            if !isICloudAvailable {
                Label("iCloud Drive is not available on this Mac.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("You can change this later in Settings → Notes.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(32)
    }

    private func iCloudOption(icon: String, title: String, desc: String,
                              selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(selected ? .blue : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(desc).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? .blue : .secondary.opacity(0.4))
                    .font(.title3)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.blue.opacity(0.08) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(selected ? Color.blue.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.5)
    }

    // MARK: - Actions

    private func applyAndDismiss() {
        NotesiCloudSupport.isEnabled = useICloud && isICloudAvailable
        NotesiCloudSupport.onboardingChoiceMade = true
        NotificationCenter.default.post(name: .notesVaultDefaultsChanged, object: nil)
        onDone()
    }
}
