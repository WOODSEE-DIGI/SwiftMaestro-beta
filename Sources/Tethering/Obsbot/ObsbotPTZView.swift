import SwiftUI

/// Compact PTZ / AI controls for an OBSBOT webcam, modelled after Ecamm Live.
///
/// Two control paths are supported:
/// - **OSC** (recommended): sends Open Sound Control messages to the official OBSBOT Center
///   app running on the same Mac. No USB reverse-engineering is required and all Tiny 3 Lite
///   PTZ commands work.
/// - **USB/UVC**: direct USB control transfer fallback (requires the camera to be free for
///   control transfers and the correct protocol for the model).
struct ObsbotPTZView: View {
    @State private var usbController = ObsbotController.shared
    @State private var oscController = ObsbotOSCController.shared
    @State private var useOSC = true
    @State private var selectedPreset = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "camera.fill")
                    .foregroundStyle(Color.accentColor)
                Text("OBSBOT Controls")
                    .font(.headline)
                Spacer()
                if let model = usbController.model, !useOSC {
                    Label(model.name, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if useOSC {
                    Toggle("OSC", isOn: $useOSC)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Button(oscController.isConnected ? "Disconnect" : "Connect OSC") {
                        if oscController.isConnected {
                            oscController.disconnect()
                        } else {
                            oscController.connect()
                        }
                    }
                    .controlSize(.small)
                } else {
                    Toggle("OSC", isOn: $useOSC)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Button(usbController.isConnected ? "Disconnect" : "Connect USB") {
                        Task {
                            if usbController.isConnected {
                                usbController.disconnect()
                            } else {
                                await usbController.connect()
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }

            if useOSC {
                oscControls
            } else {
                usbControls
            }
        }
        .padding(10)
        .background(.regularMaterial)
        .cornerRadius(12)
    }

    // MARK: - OSC controls

    @ViewBuilder
    private var oscControls: some View {
        if oscController.isConnected {
            connectedOSCControls
        } else {
            Text(oscController.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var connectedOSCControls: some View {
        HStack(alignment: .top, spacing: 14) {
            oscDirectionalPad

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ptzIconButton(icon: "minus.magnifyingglass") {
                        oscController.setZoom(oscController.zoomValue - 10)
                    }
                    .help("Zoom out")

                    Text("Zoom \(oscController.zoomValue)")
                        .font(.caption)
                        .frame(minWidth: 54)

                    ptzIconButton(icon: "plus.magnifyingglass") {
                        oscController.setZoom(oscController.zoomValue + 10)
                    }
                    .help("Zoom in")
                }

                HStack(spacing: 6) {
                    Picker("Preset", selection: Binding(
                        get: { selectedPreset },
                        set: { selectedPreset = $0 }
                    )) {
                        ForEach(0..<3, id: \.self) { i in
                            Text("P\(i + 1)").tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 56)

                    Button("Recall") {
                        oscController.triggerPreset(Int32(selectedPreset))
                    }
                    .controlSize(.small)
                    .help("Recall preset position \(selectedPreset + 1). OSC protocol has no save command; save presets in OBSBOT Center.")
                }

                HStack(spacing: 6) {
                    Button("Sleep") { oscController.setSleep(true) }
                        .controlSize(.small)
                    Button("Wake") { oscController.setSleep(false) }
                        .controlSize(.small)
                    Button("Reset") { oscController.gimbalReset() }
                        .controlSize(.small)
                }
            }
        }

        HStack(spacing: 8) {
            Text("Speed: \(oscController.panTiltSpeed)")
                .font(.caption)
                .frame(width: 70, alignment: .leading)
            Slider(value: Binding(
                get: { Double(oscController.panTiltSpeed) },
                set: { oscController.panTiltSpeed = Int32($0) }
            ), in: 5...100, step: 5) {}
                .frame(maxWidth: 200)
        }

        HStack(spacing: 8) {
            Picker("AI Mode", selection: Binding(
                get: { oscController.aiMode },
                set: { oscController.setAIMode($0) }
            )) {
                Text("Human Single").tag(Int32(0))
                Text("Human Group").tag(Int32(1))
                Text("Voice").tag(Int32(2))
                Text("Desk").tag(Int32(3))
                Text("Hand").tag(Int32(4))
                Text("Whiteboard").tag(Int32(5))
            }
            .pickerStyle(.menu)
            .frame(width: 130)

            Picker("FOV", selection: Binding(
                get: { oscController.fovMode },
                set: { oscController.setView($0) }
            )) {
                Text("Wide").tag(Int32(0))
                Text("Normal").tag(Int32(1))
                Text("Narrow").tag(Int32(2))
            }
            .pickerStyle(.segmented)
            .frame(width: 150)

            Spacer()
        }

        HStack(spacing: 8) {
            Picker("Tracking", selection: Binding(
                get: { oscController.trackingMode },
                set: { oscController.setTrackingMode($0) }
            )) {
                Text("Headroom").tag(Int32(0))
                Text("Standard").tag(Int32(1))
                Text("Motion").tag(Int32(2))
            }
            .pickerStyle(.menu)
            .frame(width: 130)

            Picker("Trk Speed", selection: Binding(
                get: { oscController.trackingSpeed },
                set: { oscController.setTrackingSpeed($0) }
            )) {
                Text("Slow").tag(Int32(0))
                Text("Std").tag(Int32(1))
                Text("Fast").tag(Int32(2))
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 70)

            Spacer()
        }

        HStack {
            Button("Query") {
                oscController.getDeviceInfo()
                oscController.getGimbalPosition()
                oscController.getZoomInfo()
            }
            .font(.caption)
            .controlSize(.small)

            Spacer()

            Text(oscController.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var oscDirectionalPad: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                Spacer().frame(width: 28)
                PTZPressButtonV2(icon: "arrowtriangle.up.fill") {
                    oscController.gimbalMove(direction: .up, speed: oscController.panTiltSpeed)
                } onRelease: {
                    oscController.gimbalStop()
                }
                .frame(width: 28, height: 28)
                .help("Tilt up")
                Spacer().frame(width: 28)
            }
            HStack(spacing: 2) {
                PTZPressButtonV2(icon: "arrowtriangle.left.fill") {
                    oscController.gimbalMove(direction: .left, speed: oscController.panTiltSpeed)
                } onRelease: {
                    oscController.gimbalStop()
                }
                .frame(width: 28, height: 28)
                .help("Pan left")

                Button {
                    // Stop any active movement first, then recenter.
                    oscController.gimbalStop()
                    oscController.gimbalReset()
                } label: {
                    Image(systemName: "smallcircle.filled.circle")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .help("Stop and recenter gimbal")

                PTZPressButtonV2(icon: "arrowtriangle.right.fill") {
                    oscController.gimbalMove(direction: .right, speed: oscController.panTiltSpeed)
                } onRelease: {
                    oscController.gimbalStop()
                }
                .frame(width: 28, height: 28)
                .help("Pan right")
            }
            HStack(spacing: 2) {
                Spacer().frame(width: 28)
                PTZPressButtonV2(icon: "arrowtriangle.down.fill") {
                    oscController.gimbalMove(direction: .down, speed: oscController.panTiltSpeed)
                } onRelease: {
                    oscController.gimbalStop()
                }
                .frame(width: 28, height: 28)
                .help("Tilt down")
                Spacer().frame(width: 28)
            }
        }
    }

    // MARK: - USB controls (fallback)

    @ViewBuilder
    private var usbControls: some View {
        if usbController.isConnected {
            connectedUSBControls
        } else if let error = usbController.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var connectedUSBControls: some View {
        HStack(alignment: .top, spacing: 14) {
            usbDirectionalPad

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ptzIconButton(icon: "minus.magnifyingglass") {
                        await usbController.setZoomRatio(usbController.zoomRatio - 0.1)
                    }
                    .help("Zoom out")

                    Text("Zoom \(String(format: "%.1fx", usbController.zoomRatio))")
                        .font(.caption)
                        .frame(minWidth: 54)

                    ptzIconButton(icon: "plus.magnifyingglass") {
                        await usbController.setZoomRatio(usbController.zoomRatio + 0.1)
                    }
                    .help("Zoom in")
                }

                HStack(spacing: 6) {
                    Picker("Preset", selection: $selectedPreset) {
                        ForEach(0..<3, id: \.self) { i in
                            Text("P\(i + 1)").tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 56)

                    Button("Recall") {
                        Task { await usbController.recallPreset(selectedPreset) }
                    }
                    .controlSize(.small)

                    Button("Save") {
                        Task { await usbController.savePreset(selectedPreset) }
                    }
                    .controlSize(.small)
                }

                HStack(spacing: 6) {
                    Button("Sleep") { Task { await usbController.sleep() } }
                        .controlSize(.small)
                    Button("Wake") { Task { await usbController.wake() } }
                        .controlSize(.small)

                    Toggle("UVC PTZ", isOn: $usbController.useStandardUVCPanTilt)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Use standard UVC pan/tilt instead of vendor protocol")
                }
            }
        }

        HStack(spacing: 8) {
            Text("Speed: \(Int(usbController.panSpeed))°/s")
                .font(.caption)
                .frame(width: 70, alignment: .leading)
            Slider(value: $usbController.panSpeed, in: 5...60, step: 5) {}
                .frame(maxWidth: 200)
        }

        HStack(spacing: 8) {
            Picker("Tracking", selection: $usbController.trackingMode) {
                ForEach(ObsbotTrackingMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)
            .onChange(of: usbController.trackingMode) { _, newValue in
                Task { await usbController.setTrackingMode(newValue) }
            }

            Picker("FOV", selection: $usbController.fovMode) {
                ForEach(ObsbotFOVMode.allCases) { mode in
                    Text(shortFOVLabel(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .onChange(of: usbController.fovMode) { _, newValue in
                Task { await usbController.setFOV(newValue) }
            }

            Picker("NR", selection: $usbController.noiseCancellation) {
                ForEach(ObsbotNoiseCancellation.allCases) { mode in
                    Text(shortNRLabel(mode)).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 70)
            .onChange(of: usbController.noiseCancellation) { _, newValue in
                Task { await usbController.setNoiseCancellation(newValue) }
            }

            Toggle("HDR", isOn: Binding(
                get: { usbController.hdrEnabled },
                set: { newValue in
                    Task { await usbController.setHDR(newValue) }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }

        HStack {
            Button("Refresh") {
                Task { await usbController.refreshStatus() }
            }
            .font(.caption)
            .controlSize(.small)

            if let dump = usbController.statusDump {
                DisclosureGroup("Status") {
                    Text(dump)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }

            Spacer()

            if !usbController.commandLog.isEmpty {
                Text(usbController.commandLog)
                    .font(.caption2)
                    .foregroundStyle(usbController.commandLog.contains("Error") ? .red : .secondary)
                    .lineLimit(1)
            }

            Text("Pan \(String(format: "%.1f", usbController.panAngle))° Tilt \(String(format: "%.1f", usbController.tiltAngle))°")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var usbDirectionalPad: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                Spacer().frame(width: 28)
                PTZPressButtonV2(icon: "arrowtriangle.up.fill") {
                    usbController.startGimbalSpeed(panDegPerSec: 0, tiltDegPerSec: -usbController.panSpeed)
                } onRelease: {
                    usbController.stopGimbalSpeed()
                }
                .frame(width: 28, height: 28)
                .help("Tilt up")
                Spacer().frame(width: 28)
            }
            HStack(spacing: 2) {
                PTZPressButtonV2(icon: "arrowtriangle.left.fill") {
                    usbController.startGimbalSpeed(panDegPerSec: usbController.panSpeed, tiltDegPerSec: 0)
                } onRelease: {
                    usbController.stopGimbalSpeed()
                }
                .frame(width: 28, height: 28)
                .help("Pan left")

                Button {
                    Task { await usbController.recenterGimbal() }
                } label: {
                    Image(systemName: "smallcircle.filled.circle")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .help("Recenter gimbal")

                PTZPressButtonV2(icon: "arrowtriangle.right.fill") {
                    usbController.startGimbalSpeed(panDegPerSec: -usbController.panSpeed, tiltDegPerSec: 0)
                } onRelease: {
                    usbController.stopGimbalSpeed()
                }
                .frame(width: 28, height: 28)
                .help("Pan right")
            }
            HStack(spacing: 2) {
                Spacer().frame(width: 28)
                PTZPressButtonV2(icon: "arrowtriangle.down.fill") {
                    usbController.startGimbalSpeed(panDegPerSec: 0, tiltDegPerSec: usbController.panSpeed)
                } onRelease: {
                    usbController.stopGimbalSpeed()
                }
                .frame(width: 28, height: 28)
                .help("Tilt down")
                Spacer().frame(width: 28)
            }
        }
    }

    // MARK: - Helpers

    private func ptzIconButton(icon: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .frame(width: 28, height: 28)
    }

    private func shortFOVLabel(_ mode: ObsbotFOVMode) -> String {
        switch mode {
        case .wide:   return "Wide"
        case .normal: return "Normal"
        case .narrow: return "Narrow"
        }
    }

    private func shortNRLabel(_ mode: ObsbotNoiseCancellation) -> String {
        switch mode {
        case .off:    return "Off"
        case .low:    return "Low"
        case .medium: return "Med"
        case .high:   return "High"
        }
    }

    private func oscAIIndex(for mode: ObsbotTrackingMode) -> Int32 {
        switch mode {
        case .off:        return 0
        case .normal:     return 0
        case .upperBody:  return 1
        case .closeUp:    return 0
        case .headless:   return 0
        case .lowerBody:  return 0
        case .whiteboard: return 5
        case .hand:       return 4
        }
    }

    private func oscViewIndex(for mode: ObsbotFOVMode) -> Int32 {
        switch mode {
        case .wide:   return 0
        case .normal: return 1
        case .narrow: return 2
        }
    }
}

#Preview {
    ObsbotPTZView()
        .frame(width: 500, height: 260)
}
