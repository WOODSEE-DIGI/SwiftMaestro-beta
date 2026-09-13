import SwiftUI

struct ContentView: View {
    @Environment(SetupViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
        }
        .task { await viewModel.load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            appLogoImage
                .frame(width: 42, height: 42)
                .shadow(color: neonPink.opacity(0.55), radius: 12, x: 0, y: 0)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("SwiftMaestro")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Setup")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(neonPink)
                        .background(neonPink.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Text("Private AI. On Your Terms.")
                    .font(.caption)
                    .foregroundStyle(neonCyan)
            }

            Spacer()

            if let manifest = viewModel.manifest {
                Text("v\(manifest.version)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(neonPink.opacity(0.25))
                .frame(height: 1)
        }
    }

    private var neonPink: Color {
        Color(red: 1.0, green: 0.18, blue: 0.53)
    }

    private var neonCyan: Color {
        Color(red: 0.0, green: 0.94, blue: 1.0)
    }

    @ViewBuilder
    private var appLogoImage: some View {
        if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView("Checking for release information…")
                .controlSize(.large)
        case .ready:
            readyView
        case .downloading:
            downloadingView
        case .paused:
            pausedView
        case .verifying:
            verifyingView
        case .verified:
            verifiedView
        case .installing:
            installingView
        case .installed:
            installedView
        case .onlineModelSetup:
            OnlineModelSetupView {
                viewModel.finishOnlineModelSetup()
            }
        case .failed(let message):
            failedView(message)
        }
    }

    // MARK: - Ready

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let profile = viewModel.profile {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recommended for this Mac")
                        .font(.headline)
                    Text(viewModel.recommendationReason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        systemInfoItem(icon: "memorychip", label: "Memory", value: ByteFormatter.string(profile.totalRAMBytes))
                        systemInfoItem(icon: "externaldrive", label: "Free disk", value: ByteFormatter.string(profile.freeDiskBytes))
                    }
                    .padding(.top, 4)
                }
                .padding(.bottom, 4)
            } else {
                Text("Choose an installer")
                    .font(.headline)
            }

            HStack(spacing: 12) {
                payloadCard(.full)
                payloadCard(.light)
            }

            if let warning = selectionWarning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
            }

            Divider()

            DisclosureGroup("Advanced: custom package URL") {
                customDownloadView
                    .padding(.top, 8)
            }
            .font(.callout)

            Spacer()

            localPayloadActionView
        }
        .padding(20)
        .onChange(of: viewModel.selection) { _, _ in
            Task { await viewModel.refreshLocalPayloadStatus() }
        }
    }

    @ViewBuilder
    private var localPayloadActionView: some View {
        switch viewModel.localPayloadStatus {
        case .complete(let bytes, let expected):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("A complete installer was found (\(ByteFormatter.string(bytes)) of \(ByteFormatter.string(expected))).")
                        .font(.callout)
                }
                HStack {
                    Spacer()
                    Button("Re-download") {
                        viewModel.discardLocalPayload()
                        Task { await viewModel.startDownload() }
                    }
                    Button("Verify & Install") {
                        Task { await viewModel.useLocalPayload() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        case .partial(let bytes, let expected):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("A partial download was found (\(ByteFormatter.string(bytes)) of \(ByteFormatter.string(expected))).")
                        .font(.callout)
                }
                HStack {
                    Spacer()
                    Button("Start Fresh") {
                        viewModel.discardLocalPayload()
                        Task { await viewModel.startDownload() }
                    }
                    Button("Resume Download") {
                        Task { await viewModel.startDownload() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        case .none:
            HStack {
                Spacer()
                Button("Download") {
                    Task { await viewModel.startDownload() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func systemInfoItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.monospaced())
            }
        }
    }

    private var selectionWarning: String? {
        guard let profile = viewModel.profile,
              let manifest = viewModel.manifest else { return nil }
        let free = profile.freeDiskBytes
        let selectedBytes: Int64 = {
            switch viewModel.selection {
            case .full: return manifest.full.sizeBytes
            case .light: return manifest.light.sizeBytes
            default: return 0
            }
        }()
        let needed = selectedBytes + 1_073_741_824
        if free < needed {
            return "Not enough free disk space. You need at least \(ByteFormatter.string(selectedBytes + 1_073_741_824)) available."
        }
        return nil
    }

    private func payloadCard(_ key: SetupViewModel.PayloadSelection) -> some View {
        let selected = viewModel.selection == key
        let recommended = viewModel.recommendation == key
        let info: PayloadManifest.Payload? = {
            guard let manifest = viewModel.manifest else { return nil }
            switch key {
            case .full: return manifest.full
            case .light: return manifest.light
            default: return nil
            }
        }()

        return Button {
            viewModel.selection = key
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(info?.displayName ?? "—")
                        .font(.headline)
                    Spacer()
                    if recommended {
                        Text("Recommended")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .cornerRadius(4)
                    }
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                Text(info?.summary ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(info.map { ByteFormatter.string($0.sizeBytes) } ?? "")
                    .font(.callout.monospaced())
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(selected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var customDownloadView: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("https://…/SwiftMaestro-X.Y.Z-full.pkg", text: customURLBinding)
                .textFieldStyle(.roundedBorder)
            TextField("SHA-256 (optional — fetched from .sha256 sidecar when blank)", text: customSHABinding)
                .textFieldStyle(.roundedBorder)
            Text("The package must be signed and use the standard macOS installer format.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var customURLBinding: Binding<String> {
        Binding(
            get: {
                if case .custom(let url, _) = viewModel.selection { return url }
                return ""
            },
            set: { newValue in
                if case .custom(_, let sha) = viewModel.selection {
                    viewModel.selection = .custom(url: newValue, sha256: sha)
                } else {
                    viewModel.selection = .custom(url: newValue, sha256: "")
                }
            }
        )
    }

    private var customSHABinding: Binding<String> {
        Binding(
            get: {
                if case .custom(_, let sha) = viewModel.selection { return sha }
                return ""
            },
            set: { newValue in
                if case .custom(let url, _) = viewModel.selection {
                    viewModel.selection = .custom(url: url, sha256: newValue)
                } else {
                    viewModel.selection = .custom(url: "", sha256: newValue)
                }
            }
        )
    }

    // MARK: - Downloading

    private var downloadingView: some View {
        VStack(spacing: 12) {
            ProgressView(value: downloadFraction)
                .controlSize(.large)

            HStack {
                Text("\(ByteFormatter.string(viewModel.downloader.bytesDownloaded)) of \(ByteFormatter.string(viewModel.downloader.expectedBytes))")
                    .font(.callout.monospaced())
                Spacer()
                Text(percentText)
                    .font(.callout.monospaced())
            }

            HStack {
                Text("Speed: \(ByteFormatter.speed(viewModel.downloader.bytesPerSecond))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Remaining: \(ByteFormatter.eta(viewModel.downloader.estimatedSecondsRemaining))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Pause") {
                    viewModel.pauseDownload()
                }
            }
        }
        .padding(8)
    }

    private var downloadFraction: Double {
        guard viewModel.downloader.expectedBytes > 0 else { return 0 }
        return Double(viewModel.downloader.bytesDownloaded) / Double(viewModel.downloader.expectedBytes)
    }

    private var percentText: String {
        let fraction = downloadFraction
        return "\(Int(fraction * 100))%"
    }

    // MARK: - Installing

    private var installingView: some View {
        VStack(spacing: 16) {
            if viewModel.installHasReceivedFraction {
                ProgressView(value: viewModel.installProgress)
                    .controlSize(.large)
            } else {
                ProgressView()
                    .controlSize(.large)
            }

            Text(viewModel.installMessage)
                .font(.callout)
                .multilineTextAlignment(.center)

            if viewModel.installHasReceivedFraction {
                Text("\(Int(viewModel.installProgress * 100))%")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let start = viewModel.installStartTime {
                TimelineView(.animation(minimumInterval: 1.0)) { _ in
                    Text("Elapsed: \(elapsedString(since: start))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("Show installer log") {
                installerLogView
                    .frame(maxHeight: 160)
            }
            .font(.callout)

            Text("This can take a few minutes. Do not quit the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var installerLogView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.installLogLines.indices, id: \.self) { index in
                        Text(viewModel.installLogLines[index])
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
            }
            .background(Color.black.opacity(0.25))
            .cornerRadius(6)
            .onChange(of: viewModel.installLogLines) { _, _ in
                let lastIndex = viewModel.installLogLines.count - 1
                guard lastIndex >= 0 else { return }
                withAnimation {
                    proxy.scrollTo(lastIndex, anchor: .bottom)
                }
            }
        }
    }

    private func elapsedString(since date: Date) -> String {
        let total = Int(Date().timeIntervalSince(date))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Paused

    private var pausedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Download paused")
                .font(.headline)
            Text("The partial file was kept. You can resume at any time — even after quitting.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Resume") {
                Task { await viewModel.resumeDownload() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Verifying

    private var verifyingView: some View {
        VStack(spacing: 12) {
            ProgressView(value: viewModel.verifyProgress)
                .controlSize(.large)
            Text("Verifying integrity (SHA-256)…")
                .font(.callout)
            Text("\(Int(viewModel.verifyProgress * 100))%")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    // MARK: - Verified → Install

    private var verifiedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Download verified")
                .font(.headline)
            Text("The package matches its published SHA-256 checksum and is ready to install.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Toggle("Keep the installer file after installation (recommended — avoids re-downloading next time)", isOn: keepPayloadBinding)
                .font(.callout)
            Button("Install SwiftMaestro") {
                Task { await viewModel.install() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var keepPayloadBinding: Binding<Bool> {
        Binding(
            get: { viewModel.keepPayload },
            set: { viewModel.keepPayload = $0 }
        )
    }

    // MARK: - Installed

    private var installedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("SwiftMaestro is installed")
                .font(.headline)
            Text("Launch it from your Applications folder. Model downloads run inside the app with the same resume and integrity protection.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Set up a model source (optional)") {
                viewModel.showOnlineModelSetup()
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Failed

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.headline)
            ScrollView {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            HStack {
                Spacer()
                Button("Back") {
                    viewModel.dismissError()
                }
                Button("Try Again") {
                    Task { await viewModel.retry() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(8)
    }
}