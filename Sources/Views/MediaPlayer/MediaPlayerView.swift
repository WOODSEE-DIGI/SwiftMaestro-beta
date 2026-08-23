import SwiftUI
import UniformTypeIdentifiers
import CoreAudio

// MARK: - Media Player View
//
// Main container for the BTOP+-styled media player panel. Combines
// the now-playing card, visualization, progress bar, transport controls,
// volume, playlist, and media info into a cohesive retro-themed layout.

struct MediaPlayerView: View {
    @Environment(WhisperKitService.self) private var whisper
    @State private var engine = MediaPlayerEngine.shared
    @State private var queue = MediaPlayerQueue.shared
    @State private var outputDevices: [AudioDevice] = []
    @State private var pairedBluetooth: [PairedBluetoothAudioDevice] = []
    @State private var connectingAddresses: Set<String> = []
    @State private var deviceListenerToken: UUID?
    @State private var airPlayHandle = AirPlayRoutePickerHandle()

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

                // Audio output route — same device manager as Audio Control,
                // refreshed live by the CoreAudio hot-plug listener. Selecting
                // sets the system output (AVPlayer follows it); paired-but-idle
                // Bluetooth devices can be connected from here too.
                Menu {
                    Button {
                        whisper.selectedOutputDeviceID = nil
                    } label: {
                        if whisper.selectedOutputDeviceID == nil {
                            Label("System Default", systemImage: "checkmark")
                        } else {
                            Text("System Default")
                        }
                    }

                    Divider()

                    ForEach(outputDevices) { device in
                        Button {
                            whisper.selectedOutputDeviceID = device.id
                            AudioDeviceManager.shared.setDefaultOutputDevice(id: device.id)
                        } label: {
                            if activeOutputID == device.id {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }

                    let unconnected = pairedBluetooth.filter { bt in
                        !bt.isConnected
                            && !outputDevices.filter(\.isBluetooth).map(\.name).contains(bt.name)
                    }
                    if !unconnected.isEmpty {
                        Divider()
                        ForEach(unconnected) { bt in
                            Button {
                                connectBluetooth(bt)
                            } label: {
                                Text(connectingAddresses.contains(bt.address)
                                     ? "\(bt.name) — connecting…"
                                     : "\(bt.name) — not connected, tap to connect")
                            }
                        }
                    }

                    Divider()

                    Button("AirPlay Devices…") {
                        airPlayHandle.openPicker()
                    }
                } label: {
                    Text("OUT: \(activeOutputName)")
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(RetroPalette.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(RetroPalette.green.opacity(0.4), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("Audio output device (same route as Audio Control)")
                .fixedSize()
                .background(
                    // Hidden system picker that the "AirPlay Devices…" menu
                    // item forwards into; associated with the media player so
                    // AirPlay targets this stream.
                    AirPlayRoutePicker(handle: airPlayHandle, player: engine.playerForVideo)
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                )

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
            refreshOutputDevices()
            deviceListenerToken = AudioDeviceManager.shared.addDevicesChangedHandler {
                refreshOutputDevices()
            }
        }
        .onDisappear {
            vizTimer?.invalidate()
            if let deviceListenerToken {
                AudioDeviceManager.shared.removeDevicesChangedHandler(deviceListenerToken)
                self.deviceListenerToken = nil
            }
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

    /// The route audio actually takes: the user's saved choice, else the
    /// current system default.
    private var activeOutputID: AudioDeviceID? {
        if let saved = whisper.selectedOutputDeviceID,
           outputDevices.contains(where: { $0.id == saved }) {
            return saved
        }
        return AudioDeviceManager.shared.defaultOutputDeviceID
    }

    private var activeOutputName: String {
        if let id = activeOutputID,
           let device = outputDevices.first(where: { $0.id == id }) {
            return device.name
        }
        return "System"
    }

    private func refreshOutputDevices() {
        outputDevices = AudioDeviceManager.shared.outputDevices
        pairedBluetooth = AudioDeviceManager.shared.pairedBluetoothAudioDevices
    }

    private func connectBluetooth(_ device: PairedBluetoothAudioDevice) {
        connectingAddresses.insert(device.address)
        Task {
            let match = await AudioDeviceManager.shared.connectBluetoothAndAwaitDevice(device)
            await MainActor.run {
                refreshOutputDevices()
                if let match {
                    whisper.selectedOutputDeviceID = match.id
                    AudioDeviceManager.shared.setDefaultOutputDevice(id: match.id)
                }
                connectingAddresses.remove(device.address)
            }
        }
    }

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
