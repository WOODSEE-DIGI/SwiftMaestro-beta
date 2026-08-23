import Foundation
import AVFoundation
import CoreAudio
import SwiftUI
@preconcurrency import WhisperKit

// MARK: - Voice Note Model

/// A single voice note: the audio file is the sacred artifact (streamed to
/// disk from the first buffer), the transcript is a secondary annotation that
/// can be (re)generated any time.
struct VoiceNote: Identifiable, Codable, Sendable, Hashable {
    enum TranscriptStatus: String, Codable, Sendable, Hashable {
        /// Waiting in the transcription queue.
        case queued
        case transcribing
        case done
        /// Transcription ran but found no speech.
        case noSpeech
        case failed
    }

    var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    /// Absolute path to the WAV file. Absolute (not just a filename) so notes
    /// written under a previous custom save location keep resolving forever.
    var audioPath: String
    var transcript: String?
    var status: TranscriptStatus
    var errorMessage: String?

    /// First line of the transcript, for list display.
    var displayTitle: String {
        if let transcript {
            let firstLine = transcript.components(separatedBy: .newlines).first ?? transcript
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed.count > 70 ? String(trimmed.prefix(70)) + "…" : trimmed
            }
        }
        return "Voice Note"
    }
}

// MARK: - Voice Notes Store

/// Record-first voice notes. Recording never depends on the Whisper model —
/// it streams PCM straight to disk via its own AVAudioEngine tap, so the note
/// survives even an app crash (orphaned WAVs are recovered on next launch).
/// Transcription is a serial background queue fed after each recording stops.
@Observable
@MainActor
final class VoiceNotesStore {
    static let shared = VoiceNotesStore()

    private(set) var notes: [VoiceNote] = []
    private(set) var isRecording = false
    /// Live seconds elapsed for the active recording (drives the timer UI).
    private(set) var recordingElapsed: TimeInterval = 0
    /// 0…1 RMS level, updated per tap buffer (drives the level meter).
    private(set) var recordingLevel: Float = 0
    /// Rolling level history for the mini waveform (most recent last).
    private(set) var levelHistory: [Float] = []
    /// The note currently being recorded (shown highlighted in the list).
    private(set) var activeNoteID: UUID?
    private(set) var playingNoteID: UUID?
    var errorMessage: String?
    /// Non-error info shown in the record section (e.g. why a recording stopped).
    var noticeMessage: String?

    private var engine: AVAudioEngine?
    private var writer: AudioRecordingWriter?
    /// True while a detached recording-start is in flight. Prevents a second
    /// tap of the record button from racing two engine startups.
    private var isStartingRecording = false
    private var recordingFrames: Int64 = 0
    private var recordingSampleRate: Double = 48_000
    private var player: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?

    /// Safety net: stop after 5 minutes of CONTINUOUS silence. Voice activity
    /// resets the clock, so thinking pauses never trigger it — but a recording
    /// started and forgotten can't run for hours.
    private static let silenceAutoStopAfter: TimeInterval = 300
    /// Raw RMS above this counts as voice/audible activity. Quiet speech into a
    /// built-in mic measures ~0.02–0.1; room tone stays well under 0.01.
    private static let voiceRMSThreshold: Float = 0.015
    private var lastVoiceActivity: Date?
    private var recordingStartDate: Date?
    private var silenceMonitorTask: Task<Void, Never>?

    private var whisper: WhisperKitService?
    private var notesVaultURL: URL?

    private var pendingTranscriptionIDs: [UUID] = []
    private var transcriptionTask: Task<Void, Never>?

    // MARK: - Settings (persisted)

    private static let defaultsPrefix = "voiceNotes"

    /// Microphone override for voice notes. nil = system default input.
    var selectedInputDeviceID: AudioDeviceID? {
        get {
            let value = UserDefaults.standard.integer(forKey: "\(Self.defaultsPrefix).inputDeviceID")
            return value == 0 ? nil : AudioDeviceID(value)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(Int(newValue), forKey: "\(Self.defaultsPrefix).inputDeviceID")
            } else {
                UserDefaults.standard.removeObject(forKey: "\(Self.defaultsPrefix).inputDeviceID")
            }
        }
    }

    /// Custom save folder for recordings. nil = default app-support folder.
    var recordingsFolderOverride: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: "\(Self.defaultsPrefix).recordingsPath"),
                  !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.path, forKey: "\(Self.defaultsPrefix).recordingsPath")
            } else {
                UserDefaults.standard.removeObject(forKey: "\(Self.defaultsPrefix).recordingsPath")
            }
        }
    }

    /// Where NEW recordings are written. The notes.json index always stays in
    /// the app-support directory — it's app state, not user data.
    var recordingsFolder: URL { recordingsFolderOverride ?? storeDirectory }

    // MARK: - Locations

    private var storeDirectory: URL {
        SwiftMaestroPaths.appSupportDir.appendingPathComponent("VoiceNotes", isDirectory: true)
    }
    private var indexURL: URL {
        storeDirectory.appendingPathComponent("notes.json")
    }

    func audioURL(for note: VoiceNote) -> URL {
        URL(fileURLWithPath: note.audioPath)
    }

    // MARK: - Wiring (called once from SwiftMaestroApp)

    /// Attach the app's shared services. The whisper reference is used ONLY
    /// for post-recording transcription — never on the recording path.
    /// Starts the transcription queue (init defers it until the model
    /// service exists).
    func attach(whisper: WhisperKitService, notesVault: URL?) {
        self.whisper = whisper
        self.notesVaultURL = notesVault
        for note in notes where note.status == .queued {
            if !pendingTranscriptionIDs.contains(note.id) {
                pendingTranscriptionIDs.append(note.id)
            }
        }
        startTranscriptionQueueIfNeeded()
    }

    private init() {
        loadIndex()
        recoverOrphanedRecordings()
    }

    // MARK: - Index persistence

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([VoiceNote].self, from: data) else { return }
        notes = decoded
        // Anything interrupted mid-transcription last session goes back to queued.
        for idx in notes.indices where notes[idx].status == .transcribing {
            notes[idx].status = .queued
        }
    }

    private func saveIndex() {
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Crash recovery: any WAV on disk that isn't in the index is a recording
    /// that survived the app dying. Scans the default folder AND the custom
    /// save folder (if set). Duration is recovered from file size — a killed
    /// mid-write header can claim 0 samples.
    private func recoverOrphanedRecordings() {
        var scanDirs = [storeDirectory]
        if let custom = recordingsFolderOverride, custom != storeDirectory {
            scanDirs.append(custom)
        }

        let known = Set(notes.map(\.audioPath))
        var recovered = false
        for dir in scanDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "wav" && !known.contains(file.path) {
                let duration = AudioRecordingWriter.recoveredDuration(fileURL: file)
                guard duration > 0.5 else { continue }  // ignore empty/aborted stubs
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                var note = VoiceNote(
                    id: UUID(), createdAt: created, duration: duration,
                    audioPath: file.path,
                    transcript: nil, status: .queued, errorMessage: nil
                )
                note.errorMessage = "Recovered after unexpected quit"
                notes.append(note)
                pendingTranscriptionIDs.append(note.id)
                recovered = true
            }
        }
        if recovered {
            notes.sort { $0.createdAt > $1.createdAt }
            saveIndex()
            // The queue starts when attach() wires up the whisper service.
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard !isRecording, !isStartingRecording else { return }
        isStartingRecording = true
        errorMessage = nil
        noticeMessage = nil

        // Chat dictation and a voice note can't share the mic — the voice note wins.
        if let whisper, whisper.isRecording {
            whisper.toggleRecording()
        }

        // Snapshot everything the detached worker needs — it must NOT touch
        // MainActor state (and definitely not run engine startup on the main
        // thread: starting AVAudioEngine on main right after the TCC grant
        // deadlocks against CoreAudio's RealtimeMessenger notification flush
        // — observed as a _dispatch_assert_queue_fail + beach ball).
        let deviceID = selectedInputDeviceID
        let folder = recordingsFolder
        let indexDir = storeDirectory
        let stamp = Self.fileStampFormatter.string(from: Date())
        let fileURL = folder.appendingPathComponent("Voice Note \(stamp).wav")

        Task.detached { [weak self] in
            await self?.runRecordingStart(
                selectedDeviceID: deviceID,
                indexDir: indexDir,
                recordingsFolder: folder,
                fileURL: fileURL
            )
        }
    }

    /// All engine/permission/file work for starting a recording. Runs OFF the
    /// main actor; UI-state mutations hop back via MainActor.run.
    private nonisolated func runRecordingStart(
        selectedDeviceID: AudioDeviceID?,
        indexDir: URL,
        recordingsFolder: URL,
        fileURL: URL
    ) async {
        guard await AudioProcessor.requestRecordPermission() else {
            await MainActor.run {
                self.errorMessage = "Microphone access denied. Allow SwiftMaestro in System Settings → Privacy & Security → Microphone."
                self.isStartingRecording = false
            }
            return
        }

        let engine = AVAudioEngine()

        // Apply the chosen microphone (if any) BEFORE the tap/start.
        // Device IDs go stale across reboots and unplugged hardware, so
        // validate first — an invalid ID crashes AVAudioEngine.
        if let deviceID = AudioDeviceManager.shared.validInputDeviceID(selectedDeviceID),
           let audioUnit = engine.inputNode.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(
                audioUnit,
                AudioUnitPropertyID(kAudioOutputUnitProperty_CurrentDevice),
                kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        } else if selectedDeviceID != nil {
            // Saved device vanished — fall back to default and say so.
            await MainActor.run {
                self.noticeMessage = "Saved microphone is no longer available — using the default input."
            }
        }

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        // Guard the classic installTap crash on bogus device formats.
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            await MainActor.run {
                self.errorMessage = "No usable microphone found."
                self.isStartingRecording = false
            }
            return
        }

        // Insert the shared 8-band EQ BEFORE the tap and writer: recordings
        // and the level meter both see the EQ'd signal. The EQ node connects
        // through to the (muted) main mixer so the render graph has a full
        // pull path; outputVolume 0 keeps it silent — no feedback.
        let eqNode = AudioEQSettings.makeEQUnit(from: await AudioEQSettings.shared.snapshot)
        engine.attach(eqNode)
        engine.connect(input, to: eqNode, format: hwFormat)
        engine.connect(eqNode, to: engine.mainMixerNode, format: hwFormat)
        engine.mainMixerNode.outputVolume = 0

        try? FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
        do {
            try FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        } catch {
            await MainActor.run {
                self.errorMessage = "Couldn't create the recordings folder: \(error.localizedDescription)"
                self.isStartingRecording = false
            }
            return
        }

        // Record at the hardware sample rate — no sample-rate converter on
        // the sacred path. WhisperKit resamples itself at transcription time.
        let writer = AudioRecordingWriter(
            fileURL: fileURL,
            sampleRate: hwFormat.sampleRate,
            channels: 1
        )
        do {
            try await writer.open()
        } catch {
            await MainActor.run {
                self.errorMessage = "Couldn't create the recording file: \(error.localizedDescription)"
                self.isStartingRecording = false
            }
            return
        }

        // The tap sits on the EQ node's output (post-EQ). It captures the
        // writer actor directly (Sendable) — no MainActor hop for disk writes,
        // and no reading of actor state from the RT thread. UI updates keep
        // the existing MainActor task pattern.
        eqNode.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channelData = buffer.floatChannelData else { return }

            // Channel 0 only (mono); de-interleave if the device insists on it.
            let channelCount = Int(buffer.format.channelCount)
            let stride = buffer.format.isInterleaved ? channelCount : 1
            var samples = [Float]()
            samples.reserveCapacity(frames)
            var sumSquares: Float = 0
            for i in 0..<frames {
                let s = channelData[0][i * stride]
                samples.append(s)
                sumSquares += s * s
            }
            let rawRMS = sqrt(sumSquares / Float(frames))
            let rms = min(1, rawRMS * 3)

            Task {
                try? await writer.appendSlice(samples)
            }
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.recordingFrames += Int64(frames)
                self.recordingElapsed = Double(self.recordingFrames) / self.recordingSampleRate
                self.recordingLevel = rms
                self.levelHistory.append(rms)
                if self.levelHistory.count > 48 { self.levelHistory.removeFirst(self.levelHistory.count - 48) }
                if rawRMS >= Self.voiceRMSThreshold {
                    self.lastVoiceActivity = Date()
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            eqNode.removeTap(onBus: 0)
            try? await writer.close()
            try? FileManager.default.removeItem(at: fileURL)
            await MainActor.run {
                self.engine = nil
                self.writer = nil
                self.errorMessage = "Couldn't start recording: \(error.localizedDescription)"
                self.isStartingRecording = false
            }
            return
        }

        // Commit on the main actor: the note enters the list the moment
        // recording starts — the user sees it existing while they talk.
        await MainActor.run {
            self.engine = engine
            self.writer = writer
            self.recordingSampleRate = hwFormat.sampleRate
            self.recordingFrames = 0
            self.recordingElapsed = 0
            self.levelHistory = []
            self.recordingLevel = 0

            let note = VoiceNote(
                id: UUID(), createdAt: Date(), duration: 0,
                audioPath: fileURL.path,
                transcript: nil, status: .queued, errorMessage: nil
            )
            self.notes.insert(note, at: 0)
            self.activeNoteID = note.id
            self.isRecording = true
            self.recordingStartDate = Date()
            self.lastVoiceActivity = nil
            self.isStartingRecording = false
            self.startSilenceMonitor()
            self.saveIndex()
        }
    }

    /// 1 Hz watchdog for the 5-minute silence auto-stop. The clock runs from
    /// recording start until the first voice activity, then from the last
    /// voice activity — so "hit record and walked away" and "fell silent
    /// mid-recording" both get caught.
    private func startSilenceMonitor() {
        silenceMonitorTask?.cancel()
        silenceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard let self, self.isRecording else { return }
                let reference = self.lastVoiceActivity ?? self.recordingStartDate
                guard let reference else { continue }
                if Date().timeIntervalSince(reference) >= Self.silenceAutoStopAfter {
                    self.noticeMessage = "Recording auto-stopped after 5 minutes of silence."
                    self.stopRecording()
                    return
                }
            }
        }
    }

    private func stopRecording() {
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil
        let engine = self.engine
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        self.engine = nil

        let elapsed = Double(recordingFrames) / max(1, recordingSampleRate)

        Task {
            try? await writer?.close()
            self.writer = nil
        }

        isRecording = false
        recordingLevel = 0

        if let id = activeNoteID, let idx = notes.firstIndex(where: { $0.id == id }) {
            notes[idx].duration = elapsed
            saveIndex()
            // Transcription is the secondary process: queue it and forget.
            enqueueTranscription(id)
        }
        activeNoteID = nil
    }

    /// Best-effort finalize on quit. The launch-time orphan scan is the real
    /// safety net (the data is all on disk; only the WAV header's sample count
    /// may be stale, which `recoveredDuration` compensates for).
    func finalizeForAppQuit() {
        guard isRecording else { return }
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        let writer = self.writer
        let id = activeNoteID
        let elapsed = Double(recordingFrames) / max(1, recordingSampleRate)
        Task {
            try? await writer?.close()
            await MainActor.run { [weak self] in
                guard let self, let id,
                      let idx = self.notes.firstIndex(where: { $0.id == id }) else { return }
                self.notes[idx].duration = elapsed
                self.saveIndex()
            }
        }
    }

    // MARK: - Transcription queue

    /// Queue (or re-queue) a note for background transcription.
    func enqueueTranscription(_ id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[idx].status != .done, notes[idx].status != .transcribing else { return }
        notes[idx].status = .queued
        notes[idx].errorMessage = nil
        if !pendingTranscriptionIDs.contains(id) {
            pendingTranscriptionIDs.append(id)
        }
        saveIndex()
        startTranscriptionQueueIfNeeded()
    }

    private func startTranscriptionQueueIfNeeded() {
        guard transcriptionTask == nil else { return }
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard !self.pendingTranscriptionIDs.isEmpty else { break }
                let nextID = self.pendingTranscriptionIDs.removeFirst()
                await self.transcribeNote(id: nextID)
            }
            self.transcriptionTask = nil
        }
    }

    private func transcribeNote(id: UUID) async {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        let fileURL = audioURL(for: notes[idx])
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            notes[idx].status = .failed
            notes[idx].errorMessage = "Audio file missing"
            saveIndex()
            return
        }

        notes[idx].status = .transcribing
        do {
            guard let whisper else {
                throw WhisperKitService.VoiceNoteTranscriptionError.modelUnavailable
            }
            let text = try await whisper.transcribeAudioFile(at: fileURL)
            guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
            notes[idx].transcript = text
            notes[idx].status = .done
            notes[idx].errorMessage = nil
        } catch WhisperKitService.VoiceNoteTranscriptionError.noSpeechDetected {
            guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
            notes[idx].status = .noSpeech
        } catch {
            guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
            notes[idx].status = .failed
            notes[idx].errorMessage = error.localizedDescription
        }
        saveIndex()
    }

    // MARK: - Playback

    func togglePlayback(_ note: VoiceNote) {
        if playingNoteID == note.id {
            player?.stop()
            player = nil
            playingNoteID = nil
            playerDelegate = nil
            return
        }
        player?.stop()
        do {
            let player = try AVAudioPlayer(contentsOf: audioURL(for: note))
            let delegate = PlayerDelegate { [weak self] in
                Task { @MainActor [weak self] in
                    self?.playingNoteID = nil
                    self?.player = nil
                }
            }
            player.delegate = delegate
            self.player = player
            self.playerDelegate = delegate
            player.play()
            playingNoteID = note.id
        } catch {
            errorMessage = "Couldn't play recording: \(error.localizedDescription)"
            playingNoteID = nil
        }
    }

    private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        let onFinish: @Sendable () -> Void
        init(onFinish: @escaping @Sendable () -> Void) { self.onFinish = onFinish }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish() }
    }

    // MARK: - Export

    /// Create an Apple Note with the transcript (default folder).
    func exportToAppleNotes(_ note: VoiceNote) async throws {
        guard let transcript = note.transcript, !transcript.isEmpty else { return }
        let title = "Voice Note — \(Self.listStampFormatter.string(from: note.createdAt))"
        let body = "\(transcript)\n\n— Recorded \(Self.listStampFormatter.string(from: note.createdAt)) (\(Self.durationString(note.duration)))"
        try await AppleNotesService().createNote(title: title, body: body, in: nil)
    }

    /// Save a Markdown file into the Notes.md vault's "Voice Notes" folder.
    func exportToNotesMD(_ note: VoiceNote) throws {
        guard let transcript = note.transcript, !transcript.isEmpty else { return }
        guard let vaultURL = notesVaultURL else {
            throw VoiceNoteExportError.noNotesVault
        }
        let folder = vaultURL.appendingPathComponent("Voice Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Self.fileStampFormatter.string(from: note.createdAt)
        let fileURL = folder.appendingPathComponent("Voice Note \(stamp).md")
        let content = """
        # Voice Note — \(Self.listStampFormatter.string(from: note.createdAt))

        \(transcript)

        ---
        Duration: \(Self.durationString(note.duration)) · Recorded \(Self.listStampFormatter.string(from: note.createdAt))
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func copyTranscript(_ note: VoiceNote) {
        guard let transcript = note.transcript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    func revealAudio(_ note: VoiceNote) {
        NSWorkspace.shared.activateFileViewerSelecting([audioURL(for: note)])
    }

    /// Delete the note AND its audio file (moved to Trash, recoverable).
    func delete(_ note: VoiceNote) throws {
        if playingNoteID == note.id { togglePlayback(note) }
        pendingTranscriptionIDs.removeAll { $0 == note.id }
        notes.removeAll { $0.id == note.id }
        saveIndex()
        try FileManager.default.trashItem(at: audioURL(for: note), resultingItemURL: nil)
    }

    enum VoiceNoteExportError: LocalizedError {
        case noNotesVault
        var errorDescription: String? {
            "The Notes.md vault isn't available yet — open the Notes.md panel once first."
        }
    }

    // MARK: - Formatting

    static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }()

    static let listStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func durationString(_ duration: TimeInterval) -> String {
        let s = Int(duration.rounded())
        return s < 3600
            ? String(format: "%d:%02d", s / 60, s % 60)
            : String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
