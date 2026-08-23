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
    @State private var pairedBluetooth: [PairedBluetoothAudioDevice] = []
    @State private var connectingAddresses: Set<String> = []
    @State private var airPlayHandle = AirPlayRoutePickerHandle()

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
                // Single always-visible device list (no dropdown, no hidden
                // icons): every HAL output, paired-but-unconnected Bluetooth
                // devices with a one-tap Connect, and AirPlay as a real row.
                VStack(spacing: 2) {
                    outputRow(
                        name: "System Default",
                        icon: "sparkles",
                        isSelected: selectedOutputID == nil,
                        detail: nil
                    ) {
                        selectedOutputID = nil
                        whisper.selectedOutputDeviceID = nil
                        refreshState()
                    }

                    ForEach(outputDevices) { device in
                        outputRow(
                            name: device.name,
                            icon: outputIcon(for: device),
                            isSelected: selectedOutputID == device.id,
                            detail: nil
                        ) {
                            selectedOutputID = device.id
                            AudioDeviceManager.shared.setDefaultOutputDevice(id: device.id)
                            whisper.selectedOutputDeviceID = device.id
                            refreshState()
                        }
                    }

                    let unconnected = unconnectedBluetoothOutputs
                    ForEach(unconnected) { bt in
                        outputRow(
                            name: bt.name,
                            icon: bt.name.localizedCaseInsensitiveContains("airpods") ? "airpodspro" : "headphones",
                            isSelected: false,
                            detail: connectingAddresses.contains(bt.address) ? "Connecting…" : "Not connected — tap to connect",
                            dimmed: true
                        ) {
                            connectBluetooth(bt)
                        }
                    }

                    // AirPlay targets (Apple TV / HomePod / other Macs) are not
                    // CoreAudio devices — this row drives the system picker.
                    HStack(spacing: 10) {
                        Image(systemName: "airplayaudio")
                            .font(.body)
                            .frame(width: 24)
                        Text("AirPlay Devices…")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                    .onTapGesture { airPlayHandle.openPicker() }
                    .overlay(alignment: .leading) {
                        AirPlayRoutePicker(handle: airPlayHandle)
                            .frame(width: 24, height: 24)
                            .padding(.leading, 10)
                            .opacity(0.02)
                    }
                    .help("Route audio to Apple TV, HomePod, or another Mac via AirPlay")
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

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
        pairedBluetooth = AudioDeviceManager.shared.pairedBluetoothAudioDevices
        refreshState()
    }

    /// Paired BT devices that aren't currently present as HAL outputs —
    /// shown dimmed with a Connect affordance, like the Sound menu does.
    private var unconnectedBluetoothOutputs: [PairedBluetoothAudioDevice] {
        let connectedNames = Set(outputDevices.filter(\.isBluetooth).map(\.name))
        return pairedBluetooth.filter { !$0.isConnected && !connectedNames.contains($0.name) }
    }

    private func outputIcon(for device: AudioDevice) -> String {
        if device.isBluetooth {
            return device.name.localizedCaseInsensitiveContains("airpods") ? "airpodspro" : "headphones"
        }
        let name = device.name.lowercased()
        if name.contains("display") || name.contains("benq") || name.contains("monitor") { return "display" }
        if name.contains("mac") { return "macmini" }
        return "hifispeaker"
    }

    /// One-tap connect for a paired-but-idle Bluetooth device (Sound-menu
    /// behavior): open the BT link, then once CoreAudio surfaces it (the
    /// hot-plug listener also refreshes the list), select it as output.
    private func connectBluetooth(_ device: PairedBluetoothAudioDevice) {
        connectingAddresses.insert(device.address)
        Task {
            let match = await AudioDeviceManager.shared.connectBluetoothAndAwaitDevice(device)
            await MainActor.run {
                refreshDevices()
                if let match {
                    selectedOutputID = match.id
                    AudioDeviceManager.shared.setDefaultOutputDevice(id: match.id)
                    whisper.selectedOutputDeviceID = match.id
                }
                connectingAddresses.remove(device.address)
            }
        }
    }

    /// One row of the always-visible output device list: icon, name,
    /// optional dimmed detail line, and a trailing check when selected.
    /// Large tap target, no hidden controls.
    private func outputRow(
        name: String,
        icon: String,
        isSelected: Bool,
        detail: String?,
        dimmed: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 24)
                    .foregroundStyle(isSelected ? Color.accentColor : (dimmed ? .secondary : .primary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .foregroundStyle(dimmed ? .secondary : .primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
/// Handle that lets a custom SwiftUI row trigger the AVRoutePickerView's
/// popover (it has no public "open" API — we click its internal button).
final class AirPlayRoutePickerHandle {
    fileprivate weak var pickerView: AVRoutePickerView?

    func openPicker() {
        guard let pickerView else { return }
        if let button = Self.findButton(in: pickerView) {
            button.performClick(nil)
        }
    }

    private static func findButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        for sub in view.subviews {
            if let found = findButton(in: sub) { return found }
        }
        return nil
    }
}

struct AirPlayRoutePicker: NSViewRepresentable {
    let handle: AirPlayRoutePickerHandle
    /// Optional player association — routes that player's audio specifically.
    var player: AVPlayer? = nil

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        if let player {
            view.player = player
        }
        handle.pickerView = view
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        if let player, nsView.player !== player {
            nsView.player = player
        }
    }
}
