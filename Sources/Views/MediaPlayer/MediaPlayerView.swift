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

            // Video surface when the item has picture; retro spectrum for
            // audio-only files. (Waveform stays either way.)
            if engine.mediaInfo.hasVideo {
                MediaPlayerVideoView(player: engine.playerForVideo)
                    .frame(minHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            } else {
                // Visualization
                MediaPlayerVisualization(spectrum: engine.spectrumBands, caps: engine.spectrumCaps)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)

                // Waveform
                MediaPlayerWaveformView(samples: engine.spectrumBands.map { $0 * 2 - 1 }, barColor: RetroPalette.green)
                    .frame(height: 60)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }

            // FFmpeg preparation / failure status
            if engine.isPreparingMedia {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("CONVERTING FOR PLAYBACK…")
                        .font(.caption2.monospaced())
                        .foregroundStyle(RetroPalette.amber)
                }
                .padding(.bottom, 4)
            } else if let prepError = engine.preparationError {
                Text(prepError)
                    .font(.caption2.monospaced())
                    .foregroundStyle(RetroPalette.red)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }

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
                        .font(.body.weight(.medium))
                        .foregroundStyle(queue.shuffleEnabled ? RetroPalette.green : RetroPalette.dim)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(queue.shuffleEnabled ? "Shuffle: on" : "Shuffle: off")

                Button {
                    queue.toggleRepeat()
                } label: {
                    Image(systemName: repeatIcon)
                        .font(.body.weight(.medium))
                        .foregroundStyle(queue.repeatMode != .off ? RetroPalette.green : RetroPalette.dim)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(queue.repeatMode == .off ? "Repeat: off" : queue.repeatMode == .one ? "Repeat: one" : "Repeat: all")

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
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(RetroPalette.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(RetroPalette.green.opacity(0.4), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("Playback speed")
                .fixedSize()

                Spacer()

                Button {
                    showFilePicker = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(RetroPalette.green)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add files to the playlist")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            // Playlist
            MediaPlayerPlaylistView(queue: queue, onPlayEntry: { idx in
                if let url = queue.playIndex(idx) {
                    Task {
                        await engine.load(url: url)
                        engine.play()
                    }
                }
            }, onOpenFiles: { showFilePicker = true })
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
        // Generic AV supertypes PLUS every extension MediaPlayerFormat can
        // play (native or via FFmpeg) — .movie/.audio alone don't reliably
        // cover .mkv/.webm/.opus/.dts on every macOS version, which would
        // leave FFmpeg-fallback formats unpickable in the file picker.
        let generic: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .audio, .mpeg4Audio, .mp3, .wav]
        let byExtension = MediaPlayerFormat.allSupported.compactMap { UTType(filenameExtension: $0) }
        var seen = Set(generic)
        return generic + byExtension.filter { seen.insert($0).inserted }
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
