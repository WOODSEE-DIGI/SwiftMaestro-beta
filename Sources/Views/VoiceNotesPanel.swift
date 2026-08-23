import SwiftUI
import CoreAudio

// MARK: - Voice Notes Panel

/// Record-first voice notes: one big record button, an unmissable recording
/// state, and a list of notes with their transcripts inline. Recording streams
/// to disk immediately; transcription happens in the background afterwards.
struct VoiceNotesPanel: View {
    @State private var store = VoiceNotesStore.shared
    @State private var expandedNoteIDs: Set<UUID> = []
    @State private var notePendingDeletion: VoiceNote?
    @State private var exportMessage: String?
    @State private var inputDevices: [AudioDevice] = []
    /// Below this panel height the settings section auto-collapses so the
    /// notes list keeps the room. A manual toggle overrides it until the
    /// panel next crosses the threshold (then automatic behavior resumes).
    @State private var isCompact = false
    @State private var settingsExpandedOverride: Bool?

    private static let compactHeightThreshold: CGFloat = 500

    private var settingsExpanded: Bool {
        settingsExpandedOverride ?? !isCompact
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                recordSection
                Divider()
                settingsSection
                if settingsExpanded { Divider() }
                notesList
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .background(.ultraThinMaterial)
            .onAppear { isCompact = geo.size.height < Self.compactHeightThreshold }
            .onChange(of: geo.size.height) { _, newHeight in
                let compact = newHeight < Self.compactHeightThreshold
                if compact != isCompact {
                    isCompact = compact
                    settingsExpandedOverride = nil
                }
            }
        }
        .alert("Delete Voice Note?", isPresented: Binding(
            get: { notePendingDeletion != nil },
            set: { if !$0 { notePendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let note = notePendingDeletion {
                    do {
                        try store.delete(note)
                    } catch {
                        store.errorMessage = "Couldn't delete: \(error.localizedDescription)"
                    }
                }
                notePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { notePendingDeletion = nil }
        } message: {
            Text("The audio file is moved to the Trash. This can't be undone from here.")
        }
        .alert("Voice Notes", isPresented: Binding(
            get: { exportMessage != nil },
            set: { if !$0 { exportMessage = nil } }
        )) {
            Button("OK") { exportMessage = nil }
        } message: {
            Text(exportMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.circle")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text("Voice Notes")
                .font(.title2.bold())
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    // MARK: - Settings (visible by default; collapsible when the panel is short)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    settingsExpandedOverride = !settingsExpanded
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Color.accentColor)
                    Text("Settings")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(settingsExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(settingsExpanded ? "Collapse settings" : "Expand settings")

            if settingsExpanded {
                // Microphone
                HStack(spacing: 8) {
                    Text("Microphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                    Picker("Microphone", selection: Binding<AudioDeviceID?>(
                        get: { store.selectedInputDeviceID },
                        set: { store.selectedInputDeviceID = $0 }
                    )) {
                        Text("System Default").tag(nil as AudioDeviceID?)
                        ForEach(inputDevices) { device in
                            Text(device.name).tag(device.id as AudioDeviceID?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                // Save location
                HStack(spacing: 8) {
                    Text("Save Recordings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                    Text(store.recordingsFolder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(store.recordingsFolder.path)
                    Button("Choose…") { chooseRecordingsFolder() }
                        .controlSize(.small)
                    if store.recordingsFolderOverride != nil {
                        Button("Reset") { store.recordingsFolderOverride = nil }
                            .controlSize(.small)
                    }
                }

                Text("New recordings go to the chosen folder; existing notes stay where they are. Recording auto-stops after 5 minutes of continuous silence.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .onAppear {
            inputDevices = AudioDeviceManager.shared.inputDevices
        }
    }

    private func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Recordings Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.recordingsFolderOverride = url
        }
    }

    // MARK: - Record

    private var recordSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                // Record / stop button
                Button { store.toggleRecording() } label: {
                    ZStack {
                        Circle()
                            .fill(store.isRecording ? Color.red : Color.accentColor)
                            .frame(width: 56, height: 56)
                            .shadow(color: store.isRecording ? .red.opacity(0.5) : .clear, radius: 8)
                        Image(systemName: store.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .help(store.isRecording ? "Stop recording" : "Start recording")

                if store.isRecording {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(.red)
                                .frame(width: 10, height: 10)
                                .opacity(0.9)
                                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: store.isRecording)
                            Text("Recording")
                                .font(.headline)
                            Text(VoiceNotesStore.durationString(store.recordingElapsed))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        // Retro segmented VU bar (btop-style) over the EQ'd
                        // signal, above the scrolling waveform.
                        RetroLevelMeter(
                            level: store.recordingLevel,
                            peak: store.levelHistory.max() ?? 0,
                            label: "REC")
                            .frame(height: 44)
                        // Live level meter
                        LevelMeter(history: store.levelHistory)
                            .frame(height: 22)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tap to start talking")
                            .font(.headline)
                        Text("Audio saves to disk the moment you start — transcription follows in the background.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if let error = store.errorMessage {
                HStack(spacing: 10) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                    if error.localizedCaseInsensitiveContains("microphone") {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
            } else if let notice = store.noticeMessage {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding()
    }

    // MARK: - Notes list

    private var notesList: some View {
        ScrollView {
            if store.notes.isEmpty {
                VStack(spacing: 8) {
                    Text("No voice notes yet")
                        .font(.subheadline.weight(.medium))
                    Text("Your recordings and their transcripts will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.notes) { note in
                        noteCard(note)
                    }
                }
                .padding()
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func noteCard(_ note: VoiceNote) -> some View {
        let isActive = store.activeNoteID == note.id && store.isRecording
        return VStack(alignment: .leading, spacing: 8) {
            // Title row: date, duration, status
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline.weight(.semibold))
                    Text(VoiceNotesStore.durationString(isActive ? store.recordingElapsed : note.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(note, isActive: isActive)
            }

            // Transcript (visible inline — the point of the app)
            if let transcript = note.transcript, !transcript.isEmpty {
                let expanded = expandedNoteIDs.contains(note.id)
                Text(transcript)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(expanded ? nil : 4)
                    .textSelection(.enabled)
                    .onTapGesture {
                        if expanded { expandedNoteIDs.remove(note.id) } else { expandedNoteIDs.insert(note.id) }
                    }
            } else if let error = note.errorMessage, note.status == .failed {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            // Actions
            HStack(spacing: 8) {
                Button {
                    store.togglePlayback(note)
                } label: {
                    Label(store.playingNoteID == note.id ? "Stop" : "Play",
                          systemImage: store.playingNoteID == note.id ? "stop.fill" : "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if note.status == .failed || note.status == .noSpeech {
                    Button {
                        store.enqueueTranscription(note.id)
                    } label: {
                        Label("Retry Transcription", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Menu {
                    Button {
                        store.copyTranscript(note)
                    } label: {
                        Label("Copy Transcript", systemImage: "doc.on.doc")
                    }
                    .disabled(note.transcript?.isEmpty != false)

                    Divider()

                    Button {
                        Task {
                            do {
                                try await store.exportToAppleNotes(note)
                                await MainActor.run { exportMessage = "Saved to Apple Notes." }
                            } catch {
                                await MainActor.run { exportMessage = "Apple Notes export failed: \(error.localizedDescription)" }
                            }
                        }
                    } label: {
                        Label("Send to Apple Notes", systemImage: "note.text")
                    }
                    .disabled(note.transcript?.isEmpty != false)

                    Button {
                        do {
                            try store.exportToNotesMD(note)
                            exportMessage = "Saved to Notes.md vault (Voice Notes folder)."
                        } catch {
                            exportMessage = error.localizedDescription
                        }
                    } label: {
                        Label("Save to Notes.md", systemImage: "doc.text")
                    }
                    .disabled(note.transcript?.isEmpty != false)

                    Divider()

                    Button {
                        store.revealAudio(note)
                    } label: {
                        Label("Reveal Audio in Finder", systemImage: "folder")
                    }

                    Divider()

                    Button(role: .destructive) {
                        notePendingDeletion = note
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.subheadline)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? Color.red.opacity(0.6) : .clear, lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private func statusBadge(_ note: VoiceNote, isActive: Bool) -> some View {
        if isActive {
            Label("Recording", systemImage: "record.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        } else {
            switch note.status {
            case .queued:
                Label("Queued", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .transcribing:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Transcribing…").font(.caption)
                }
                .foregroundStyle(.secondary)
            case .done:
                Label("Transcribed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .noSpeech:
                Label("No speech detected", systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .failed:
                Label("Transcription failed", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Level Meter

/// Mini waveform fed by the rolling RMS history — live proof the mic hears you.
private struct LevelMeter: View {
    let history: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(history.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.red.opacity(0.35 + Double(level) * 0.65))
                    .frame(width: 3, height: max(3, CGFloat(level) * 22))
            }
            if history.isEmpty {
                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 3)
            }
        }
        .animation(.linear(duration: 0.05), value: history.count)
    }
}
