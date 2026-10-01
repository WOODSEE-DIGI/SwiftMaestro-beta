import Foundation

/// Page layout settings for MaestroDocs rich-text/plain-text documents.
/// Stored as points internally; the UI can present margins in inches,
/// millimetres, or centimetres.
struct DocPageSettings: Codable, Equatable, Hashable {
    enum PaperSize: String, Codable, CaseIterable, Identifiable {
        case a4, usLetter, legal, tabloid

        var id: Self { self }

        var displayName: String {
            switch self {
            case .a4: return "A4"
            case .usLetter: return "US Letter"
            case .legal: return "Legal"
            case .tabloid: return "Tabloid"
            }
        }

        /// Portrait width in points (1pt = 1/72 inch).
        var width: CGFloat {
            switch self {
            case .a4: return 595
            case .usLetter: return 612
            case .legal: return 612
            case .tabloid: return 792
            }
        }

        /// Portrait height in points.
        var height: CGFloat {
            switch self {
            case .a4: return 842
            case .usLetter: return 792
            case .legal: return 1008
            case .tabloid: return 1224
            }
        }
    }

    enum Orientation: String, Codable, CaseIterable, Identifiable {
        case portrait, landscape
        var id: Self { self }
        var displayName: String { rawValue.capitalized }
    }

    enum DisplayUnit: String, Codable, CaseIterable, Identifiable {
        case inches, millimetres, centimetres

        var id: Self { self }

        var displayName: String {
            switch self {
            case .inches: return "Inches"
            case .millimetres: return "Millimetres"
            case .centimetres: return "Centimetres"
            }
        }

        var shortLabel: String {
            switch self {
            case .inches: return "in"
            case .millimetres: return "mm"
            case .centimetres: return "cm"
            }
        }

        var fractionDigits: Int {
            switch self {
            case .inches: return 2
            case .millimetres: return 0
            case .centimetres: return 2
            }
        }
    }

    var paperSize: PaperSize
    var orientation: Orientation
    var displayUnit: DisplayUnit

    /// Margins in points. Defaults to 1 inch (72pt) on all sides.
    var topMargin: CGFloat
    var bottomMargin: CGFloat
    var leftMargin: CGFloat
    var rightMargin: CGFloat

    init(
        paperSize: PaperSize = .a4,
        orientation: Orientation = .portrait,
        displayUnit: DisplayUnit? = nil,
        topMargin: CGFloat = 72,
        bottomMargin: CGFloat = 72,
        leftMargin: CGFloat = 72,
        rightMargin: CGFloat = 72
    ) {
        self.paperSize = paperSize
        self.orientation = orientation
        self.displayUnit = displayUnit ?? Self.localeDefaultUnit()
        self.topMargin = topMargin
        self.bottomMargin = bottomMargin
        self.leftMargin = leftMargin
        self.rightMargin = rightMargin
    }

    var paperWidth: CGFloat {
        orientation == .portrait ? paperSize.width : paperSize.height
    }

    var paperHeight: CGFloat {
        orientation == .portrait ? paperSize.height : paperSize.width
    }

    /// Width available for content after horizontal margins.
    var contentWidth: CGFloat {
        max(100, paperWidth - leftMargin - rightMargin)
    }

    /// Height available for content after vertical margins.
    var contentHeight: CGFloat {
        max(100, paperHeight - topMargin - bottomMargin)
    }

    // MARK: - Unit conversion

    static func localeDefaultUnit() -> DisplayUnit {
        if #available(macOS 13.0, *) {
            let system = Locale.current.measurementSystem
            return system == .metric ? .millimetres : .inches
        } else {
            // Fallback for older systems: Australia/UK/EU use metric; US uses imperial.
            let code = Locale.current.region?.identifier ?? Locale.current.identifier
            let metricRegions = Set([
                "AU", "NZ", "GB", "IE", "ZA", "CA", // Canada officially metric
                "DE", "FR", "IT", "ES", "NL", "BE", "AT", "SE", "NO", "DK", "FI",
                "PL", "CZ", "HU", "CH", "PT", "GR", "TR", "IN", "JP", "KR", "CN",
                "BR", "AR", "MX", "RU"
            ])
            return metricRegions.contains(code.uppercased()) ? .millimetres : .inches
        }
    }

    func value(fromPoints points: CGFloat) -> CGFloat {
        switch displayUnit {
        case .inches: return points / 72
        case .millimetres: return points / 72 * 25.4
        case .centimetres: return points / 72 * 2.54
        }
    }

    func points(fromValue value: CGFloat) -> CGFloat {
        switch displayUnit {
        case .inches: return max(0, value * 72)
        case .millimetres: return max(0, value / 25.4 * 72)
        case .centimetres: return max(0, value / 2.54 * 72)
        }
    }

    // MARK: - Persistence

    static let defaultsKey = "maestrodocs.pageSettings"

    static func loadDefaults() -> DocPageSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(DocPageSettings.self, from: data)
        else { return DocPageSettings() }
        return settings
    }

    func saveDefaults() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Codable fallback for displayUnit

    private enum CodingKeys: String, CodingKey {
        case paperSize, orientation, displayUnit, topMargin, bottomMargin, leftMargin, rightMargin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.paperSize = try container.decode(PaperSize.self, forKey: .paperSize)
        self.orientation = try container.decode(Orientation.self, forKey: .orientation)
        self.displayUnit = try container.decodeIfPresent(DisplayUnit.self, forKey: .displayUnit)
            ?? Self.localeDefaultUnit()
        self.topMargin = try container.decode(CGFloat.self, forKey: .topMargin)
        self.bottomMargin = try container.decode(CGFloat.self, forKey: .bottomMargin)
        self.leftMargin = try container.decode(CGFloat.self, forKey: .leftMargin)
        self.rightMargin = try container.decode(CGFloat.self, forKey: .rightMargin)
    }
}
