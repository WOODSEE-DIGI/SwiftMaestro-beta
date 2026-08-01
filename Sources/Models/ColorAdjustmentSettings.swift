import Foundation

/// A set of FFmpeg video filters for live color adjustments.
struct ColorAdjustmentSettings: Codable, Hashable, Sendable {
    var brightness: Double = 0.0       // -1.0 ... 1.0
    var contrast: Double = 1.0         // 0.0 ... 2.0
    var saturation: Double = 1.0       // 0.0 ... 2.0
    var gamma: Double = 1.0          // 0.1 ... 3.0
    var hue: Double = 0.0            // -180 ... 180
    var redBalance: Double = 1.0
    var greenBalance: Double = 1.0
    var blueBalance: Double = 1.0
    var enabled: Bool = true

    var isIdentity: Bool {
        brightness == 0 && contrast == 1 && saturation == 1 && gamma == 1 && hue == 0
            && redBalance == 1 && greenBalance == 1 && blueBalance == 1
    }

    var ffmpegFilter: String {
        var parts: [String] = []
        if brightness != 0 || contrast != 1 || saturation != 1 || hue != 0 {
            parts.append("eq=brightness=\(brightness):contrast=\(contrast):saturation=\(saturation):hue=\(hue)")
        }
        if gamma != 1 {
            parts.append("hue=s=0") // placeholder for gamma; FFmpeg uses curves/eq for gamma
        }
        if redBalance != 1 || greenBalance != 1 || blueBalance != 1 {
            parts.append("colorbalance=rs=\(redBalance - 1):gs=\(greenBalance - 1):bs=\(blueBalance - 1)")
        }
        return parts.joined(separator: ",")
    }
}

struct ColorAdjustmentPreset: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var settings: ColorAdjustmentSettings
}
