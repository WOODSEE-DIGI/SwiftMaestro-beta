import SwiftUI

struct ColorAdjustmentsView: View {
    @StateObject private var service = ColorAdjustmentsService.shared
    @State private var selectedPreset: ColorAdjustmentPreset?
    @State private var isEditingPresetName = false
    @State private var newPresetName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Color Adjustments")
                    .font(.title2.bold())
                Spacer()
                Toggle("Enabled", isOn: $service.active.enabled)
                Button {
                    service.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset to default")
            }
            .padding()

            Divider()

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    adjustmentSlider("Brightness", $service.active.brightness, range: -1...1)
                    adjustmentSlider("Contrast", $service.active.contrast, range: 0...2)
                    adjustmentSlider("Saturation", $service.active.saturation, range: 0...2)
                    adjustmentSlider("Gamma", $service.active.gamma, range: 0.1...3)
                    adjustmentSlider("Hue", $service.active.hue, range: -180...180)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    adjustmentSlider("Red Balance", $service.active.redBalance, range: 0...2)
                    adjustmentSlider("Green Balance", $service.active.greenBalance, range: 0...2)
                    adjustmentSlider("Blue Balance", $service.active.blueBalance, range: 0...2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Generated FFmpeg filter")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(service.ffmpegFilter.isEmpty ? "(identity — no filters)" : service.ffmpegFilter)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Presets")
                        .font(.headline)
                    Spacer()
                    Button {
                        newPresetName = "Preset \(service.presets.count + 1)"
                        isEditingPresetName = true
                    } label: {
                        Label("Save Preset", systemImage: "plus")
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                List(selection: $selectedPreset) {
                    ForEach(service.presets) { preset in
                        HStack {
                            Text(preset.name)
                            Spacer()
                            Button {
                                service.applyPreset(preset)
                            } label: {
                                Image(systemName: "checkmark.circle")
                            }
                            .buttonStyle(.plain)
                            Button {
                                service.removePreset(id: preset.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                        .tag(preset)
                    }
                }
                .listStyle(.plain)
            }
        }
        .alert("Save Preset", isPresented: $isEditingPresetName) {
            TextField("Name", text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                service.addPreset(ColorAdjustmentPreset(
                    id: UUID(),
                    name: newPresetName,
                    settings: service.active
                ))
            }
        } message: {
            Text("Save the current color settings as a preset.")
        }
    }

    private func adjustmentSlider(_ title: String, _ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

#Preview {
    ColorAdjustmentsView()
}
