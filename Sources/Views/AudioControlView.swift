import SwiftUI
import CoreAudio
import AVKit

/// Native audio control panel: choose system input/output devices, mute them,
/// and set their volume. Lives under "Swift Apps" in the sidebar.
struct AudioControlView: View {
    @Environment(WhisperKitService.self) private var whisper
    @State private var inputDevices: [AudioDevice] = []
    @State private var outputDevices: [AudioDevice] = []
    @State private var selectedInputID: AudioDeviceID?
    @State private var selectedOutputID: AudioDeviceID?
    @State private var inputMuted: Bool = false
    @State private var outputMuted: Bool = false
    @State private var inputVolume: Double = 0.5
    @State private var outputVolume: Double = 0.5
    @State private var meter = MeterDisplay()
    @State private var deviceListenerToken: UUID?

    var body: some View {
        Form {
            Section("Input") {
                Picker("Input Device", selection: Binding(
                    get: { selectedInputID },
                    set: { newValue in
                        selectedInputID = newValue
                        if let id = newValue {
                            AudioDeviceManager.shared.setDefaultInputDevice(id: id)
                            whisper.selectedInputDeviceID = id
                        } else {
                            whisper.selectedInputDeviceID = nil
                        }
                        refreshState()
                    }
                )) {
                    Text("System Default").tag(AudioDeviceID?.none)
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("Volume")
                    Slider(value: Binding(
                        get: { inputVolume },
                        set: { newValue in
                            inputVolume = newValue
                            if let id = selectedInputID {
                                AudioDeviceManager.shared.setVolume(deviceID: id, scope: kAudioDevicePropertyScopeInput, volume: Float(newValue))
                            }
                        }
                    ), in: 0...1)
                }

                Toggle("Mute Input", isOn: Binding(
                    get: { inputMuted },
                    set: { newValue in
                        inputMuted = newValue
                        if let id = selectedInputID {
                            AudioDeviceManager.shared.setMuted(deviceID: id, scope: kAudioDevicePropertyScopeInput, muted: newValue)
                        }
                    }
                ))
            }

            Section("Output") {
                HStack {
                    Spacer()
                    AirPlayRoutePicker()
                        .frame(width: 22, height: 22)
                        .help("AirPlay: route audio to Apple TV, HomePod, or another Mac")
                }
                Picker("Output Device", selection: Binding(
                    get: { selectedOutputID },
                    set: { newValue in
                        selectedOutputID = newValue
                        if let id = newValue {
                            AudioDeviceManager.shared.setDefaultOutputDevice(id: id)
                            whisper.selectedOutputDeviceID = id
                        } else {
                            whisper.selectedOutputDeviceID = nil
                        }
                        refreshState()
                    }
                )) {
                    Text("System Default").tag(AudioDeviceID?.none)
                    ForEach(outputDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("Volume")
                    Slider(value: Binding(
                        get: { outputVolume },
                        set: { newValue in
                            outputVolume = newValue
                            if let id = selectedOutputID {
                                AudioDeviceManager.shared.setVolume(deviceID: id, scope: kAudioDevicePropertyScopeOutput, volume: Float(newValue))
                            }
                        }
                    ), in: 0...1)
                }

                Toggle("Mute Output", isOn: Binding(
                    get: { outputMuted },
                    set: { newValue in
                        outputMuted = newValue
                        if let id = selectedOutputID {
                            AudioDeviceManager.shared.setMuted(deviceID: id, scope: kAudioDevicePropertyScopeOutput, muted: newValue)
                        }
                    }
                ))
            }

            Section("Live Input Monitor") {
                VStack(spacing: 8) {
                    RetroSpectrumMeter(spectrum: meter.spectrum, caps: meter.spectrumCaps)
                        .frame(height: 128)
                    RetroLevelMeter(level: meter.level, peak: meter.peak, label: "MIC")
                    HStack {
                        Button(meter.isRunning ? "Stop Monitor" : "Start Monitor") {
                            meter.toggle()
                        }
                        .controlSize(.small)
                        if meter.isRunning {
                            Circle()
                                .fill(RetroPalette.green)
                                .frame(width: 8, height: 8)
                            Text("listening — mic check")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }

            Section("Equalizer") {
                RetroEQBank()
                    .listRowBackground(Color.clear)
                Text("Applied to the Voice Notes recording chain — meters and the "
                     + "recording see the EQ'd signal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }

            Section {
                Button("Refresh Devices") {
                    refreshDevices()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task {
            refreshDevices()
            // Rebuild the pickers when devices hot-plug (AirPods connecting,
            // USB interfaces, HDMI) — CoreAudio fires kAudioHardwarePropertyDevices.
            deviceListenerToken = AudioDeviceManager.shared.addDevicesChangedHandler {
                refreshDevices()
            }
        }
        .onDisappear {
            meter.stop()
            if let deviceListenerToken {
                AudioDeviceManager.shared.removeDevicesChangedHandler(deviceListenerToken)
                self.deviceListenerToken = nil
            }
        }
    }

    private func refreshDevices() {
        inputDevices = AudioDeviceManager.shared.inputDevices
        outputDevices = AudioDeviceManager.shared.outputDevices
        refreshState()
    }

    private func refreshState() {
        // AudioDeviceIDs are not stable across reboots; validate against current devices
        // and fall back to the system default when the saved device is no longer present.
        selectedInputID = AudioDeviceManager.shared.validInputDeviceID(whisper.selectedInputDeviceID)
            ?? AudioDeviceManager.shared.defaultInputDeviceID
        selectedOutputID = AudioDeviceManager.shared.validOutputDeviceID(whisper.selectedOutputDeviceID)
            ?? AudioDeviceManager.shared.defaultOutputDeviceID

        // Keep persisted state in sync when the saved ID is stale.
        if selectedInputID != whisper.selectedInputDeviceID {
            whisper.selectedInputDeviceID = selectedInputID
        }
        if selectedOutputID != whisper.selectedOutputDeviceID {
            whisper.selectedOutputDeviceID = selectedOutputID
        }

        if let id = selectedInputID {
            inputMuted = AudioDeviceManager.shared.isMuted(deviceID: id, scope: kAudioDevicePropertyScopeInput)
            inputVolume = Double(AudioDeviceManager.shared.volume(deviceID: id, scope: kAudioDevicePropertyScopeInput) ?? 0.5)
        }
        if let id = selectedOutputID {
            outputMuted = AudioDeviceManager.shared.isMuted(deviceID: id, scope: kAudioDevicePropertyScopeOutput)
            outputVolume = Double(AudioDeviceManager.shared.volume(deviceID: id, scope: kAudioDevicePropertyScopeOutput) ?? 0.5)
        }
    }
}

// MARK: - AirPlay route picker

/// The system AirPlay picker (Apple TV, HomePod, AirPlay-capable Macs).
/// AirPlay targets are NOT CoreAudio HAL devices, so they can't appear in the
/// output-device picker — this is the sanctioned AppKit control for them.
struct AirPlayRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
