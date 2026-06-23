import SwiftUI

/// First-run dialog shown when the WhisperKit speech-to-text model needs to be
/// downloaded. Appears automatically on startup (gated by `whisperkit.seenV1`),
/// explains what is being installed, shows download + loading progress, and lets
/// the user continue in the background while the download completes.
struct WhisperKitSetupSheet: View {
    @Environment(WhisperKitService.self) private var whisper
    let onDone: () -> Void

    private enum Phase: Equatable {
        case downloading
        case loading
        case ready
        case failed(String)
    }

    @State private var phase: Phase = .downloading

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switch phase {
            case .downloading: downloadingSection
            case .loading: loadingSection
            case .ready: readySection
            case .failed(let msg): failedSection(msg)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled()
        .onChange(of: whisper.modelState) { _, newState in
            updatePhase(for: newState)
        }
        .onAppear {
            updatePhase(for: whisper.modelState)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speech Recognition").font(.largeTitle.bold())
            Text("SwiftMaestro can transcribe your voice into text using Whisper — "
                + "a speech recognition model that runs entirely on your Mac. "
                + "This requires a one-time download (~3 GB).")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Downloading

    private var downloadingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if let progress = whisper.downloadProgress, progress > 0 {
                        ProgressView(value: progress) {
                            Text("Downloading Whisper model…")
                        }
                        Text("\(Int(progress * 100))%")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        ProgressView {
                            Text("Preparing download…")
                        }
                    }
                    Text("Stored in ~/Documents/huggingface/models/ — you can change the model in Settings → Whisper.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Continue in background") {
                    onDone()
                }
                Spacer()
            }
        }
    }

    // MARK: - Loading (post-download, loading into memory)

    private var loadingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView {
                        Text("Loading model into memory…")
                    }
                    Text("This only takes a moment after the download finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Continue in background") { onDone() }
                Spacer()
            }
        }
    }

    // MARK: - Ready

    private var readySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speech recognition ready")
                            .font(.body.bold())
                        Text("Click the microphone button in the chat bar to start transcribing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Start chatting") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Failed

    private func failedSection(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Couldn't load speech model", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Skip for now") { onDone() }
                Spacer()
                Button("Try again") { whisper.ensureModelLoaded() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Helpers

    private func updatePhase(for state: WKModelState) {
        switch state {
        case .downloading:
            phase = .downloading
        case .loading, .prewarming:
            phase = .loading
        case .loaded:
            phase = .ready
        default:
            // If we're in a failed state and have an error message, keep it
            if case .failed = phase { return }
            if let error = whisper.errorMessage {
                phase = .failed(error)
            }
        }
    }
}
