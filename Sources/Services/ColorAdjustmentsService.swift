import Foundation

/// Manages saved color-adjustment presets and generates FFmpeg filter strings.
@MainActor
final class ColorAdjustmentsService: ObservableObject {
    static let shared = ColorAdjustmentsService()

    @Published private(set) var presets: [ColorAdjustmentPreset] = []
    @Published var active: ColorAdjustmentSettings = ColorAdjustmentSettings()

    private var saveURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SwiftMaestro/ColorAdjustments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }

    private init() {
        loadPresets()
    }

    private func loadPresets() {
        guard let data = try? Data(contentsOf: saveURL),
              let saved = try? JSONDecoder().decode([ColorAdjustmentPreset].self, from: data) else {
            presets = [
                ColorAdjustmentPreset(id: UUID(), name: "Default", settings: ColorAdjustmentSettings()),
                ColorAdjustmentPreset(id: UUID(), name: "Warm", settings: ColorAdjustmentSettings(brightness: 0.05, contrast: 1.05, saturation: 1.1, gamma: 1.0, hue: 0, redBalance: 1.1, greenBalance: 1.0, blueBalance: 0.9)),
                ColorAdjustmentPreset(id: UUID(), name: "Cool", settings: ColorAdjustmentSettings(brightness: 0, contrast: 1.05, saturation: 0.95, gamma: 1.0, hue: 0, redBalance: 0.9, greenBalance: 1.0, blueBalance: 1.1))
            ]
            return
        }
        presets = saved
    }

    private func savePresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }

    func addPreset(_ preset: ColorAdjustmentPreset) {
        presets.append(preset)
        savePresets()
    }

    func updatePreset(_ preset: ColorAdjustmentPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        savePresets()
    }

    func removePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        savePresets()
    }

    func applyPreset(_ preset: ColorAdjustmentPreset) {
        active = preset.settings
    }

    func reset() {
        active = ColorAdjustmentSettings()
    }

    var ffmpegFilter: String {
        guard active.enabled else { return "" }
        return active.ffmpegFilter
    }
}
