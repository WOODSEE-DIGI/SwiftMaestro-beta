import SwiftUI
import UniformTypeIdentifiers

// MARK: - Media Player View
//
// Main container for the BTOP+-styled media player panel. Combines
// the now-playing card, visualization, progress bar, transport controls,
// volume, playlist, and media info into a cohesive retro-themed layout.

struct MediaPlayerView: View {
    @State private var engine = MediaPlayerEngine.shared
    @State private var queue = MediaPlayerQueue.shared

    /// Visualization timer.
    @State private var vizTimer: Timer?
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Now playing card
            MediaPlayerNowPlayingCard(
                mediaInfo: engine.mediaInfo,
                isPlaying: engine.isPlaying
            )
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Visualization
            MediaPlayerVisualization(spectrum: engine.spectrumBands, caps: engine.spectrumCaps)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            // Waveform
            MediaPlayerWaveformView(samples: engine.spectrumBands.map { $0 * 2 - 1 }, barColor: RetroPalette.green)
                .frame(height: 60)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            // Progress bar
            MediaPlayerProgressBar(
                currentTime: engine.currentTime,
                duration: engine.duration ?? 0,
                isSeeking: engine.isSeeking,
                onSeek: { engine.seek(to: $0) }
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            // Transport + Volume row
            HStack(spacing: 8) {
                MediaPlayerTransportView(
                    isPlaying: engine.isPlaying,
                    hasItem: engine.hasItem,
                    onPlayPause: { engine.togglePlayPause() },
                    onSkipBack: { playPrevious() },
                    onSkipForward: { playNext() },
                    onSeekBackward15: { engine.seekRelative(-15) },
                    onSeekForward15: { engine.seekRelative(15) }
                )

                MediaPlayerVolumeView(
                    volume: $engine.volume,
                    isMuted: $engine.isMuted
                )
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            // Shuffle / Repeat / Open File row
            HStack(spacing: 8) {
                Button {
                    queue.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.caption)
                        .foregroundStyle(queue.shuffleEnabled ? RetroPalette.green : RetroPalette.dim)
                }
                .buttonStyle(.plain)

                Button {
                    queue.toggleRepeat()
                } label: {
                    Image(systemName: repeatIcon)
                        .font(.caption)
                        .foregroundStyle(queue.repeatMode != .off ? RetroPalette.green : RetroPalette.dim)
                }
                .buttonStyle(.plain)

                Spacer()

                // Playback speed
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { spd in
                        Button("\(spd, specifier: "%.2g")×") {
                            engine.setRate(Float(spd))
                        }
                    }
                } label: {
                    Text("\(engine.rate, specifier: "%.2g")×")
                        .font(.caption2.monospaced())
                        .foregroundStyle(RetroPalette.green.opacity(0.7))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button {
                    showFilePicker = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                        .foregroundStyle(RetroPalette.green.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            // Playlist
            MediaPlayerPlaylistView(queue: queue) { idx in
                if let url = queue.playIndex(idx) {
                    Task {
                        await engine.load(url: url)
                        engine.play()
                    }
                }
            }
        }
        .background(RetroPalette.background)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: mediaTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .onAppear {
            queue.load()
            startVisualization()
        }
        .onDisappear {
            vizTimer?.invalidate()
        }
        // Player keyboard shortcuts (macOS 14+ .onKeyPress; panel scope).
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            engine.togglePlayPause()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            engine.seekRelative(-15)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            engine.seekRelative(15)
            return .handled
        }
        .onKeyPress(.upArrow) {
            engine.volume = min(1, engine.volume + 0.05)
            return .handled
        }
        .onKeyPress(.downArrow) {
            engine.volume = max(0, engine.volume - 0.05)
            return .handled
        }
        .onKeyPress(keys: ["n"]) { _ in
            playNext()
            return .handled
        }
        .onKeyPress(keys: ["p"]) { _ in
            playPrevious()
            return .handled
        }
    }

    // MARK: - Helpers

    private var repeatIcon: String {
        switch queue.repeatMode {
        case .off:  return "repeat"
        case .one:  return "repeat.1"
        case .all:  return "repeat"
        }
    }

    private var mediaTypes: [UTType] {
        [.movie, .mpeg4Movie, .quickTimeMovie, .audio, .mpeg4Audio, .mp3, .wav]
    }

    // MARK: - File Handling

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let validURLs = urls.filter { MediaPlayerFormat.canPlay($0) }
        guard !validURLs.isEmpty else { return }

        if queue.isEmpty {
            if let url = queue.playFiles(validURLs) {
                Task {
                    await engine.load(url: url)
                    engine.play()
                }
            }
        } else {
            queue.append(contentsOf: validURLs)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                if MediaPlayerFormat.canPlay(url) {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) { [self] in
            guard !urls.isEmpty else { return }
            if queue.isEmpty {
                if let url = queue.playFiles(urls) {
                    Task {
                        await engine.load(url: url)
                        engine.play()
                    }
                }
            } else {
                queue.append(contentsOf: urls)
            }
        }

        return true
    }

    // MARK: - Navigation

    private func playNext() {
        if let url = queue.next() {
            Task {
                await engine.load(url: url)
                engine.play()
            }
        }
    }

    private func playPrevious() {
        if let url = queue.previous() {
            Task {
                await engine.load(url: url)
                engine.play()
            }
        }
    }

    // MARK: - Visualization

    private func startVisualization() {
        vizTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [self] _ in
            // Pull real spectrum data from the audio tap.
            engine.refreshSpectrum()
        }
    }
}
