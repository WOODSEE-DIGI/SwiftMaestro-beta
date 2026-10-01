import SwiftUI

/// Page Setup sheet for MaestroDocs: paper size, orientation, margins, and unit
/// preference. Measurements can be edited in inches, millimetres, or centimetres.
struct PageSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var settings: DocPageSettings
    let onSave: (DocPageSettings) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text")
                Text("Page Setup").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    onSave(settings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            Form {
                Picker("Paper Size", selection: $settings.paperSize) {
                    ForEach(DocPageSettings.PaperSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Orientation", selection: $settings.orientation) {
                    ForEach(DocPageSettings.Orientation.allCases) { orientation in
                        Text(orientation.displayName).tag(orientation)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Units", selection: $settings.displayUnit) {
                    ForEach(DocPageSettings.DisplayUnit.allCases) { unit in
                        Text(unit.displayName).tag(unit)
                    }
                }
                .pickerStyle(.segmented)

                Section("Margins (\(settings.displayUnit.shortLabel))") {
                    HStack(spacing: 12) {
                        marginField("Top", value: $settings.topMargin)
                        marginField("Bottom", value: $settings.bottomMargin)
                    }
                    HStack(spacing: 12) {
                        marginField("Left", value: $settings.leftMargin)
                        marginField("Right", value: $settings.rightMargin)
                    }
                }

                HStack(spacing: 4) {
                    Spacer()
                    Text(pageDimensionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .frame(width: 420)
    }

    private var pageDimensionLabel: String {
        let unit = settings.displayUnit
        let w = settings.value(fromPoints: settings.paperWidth)
        let h = settings.value(fromPoints: settings.paperHeight)
        let fmt: NumberFormatter = {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = unit.fractionDigits
            f.minimumFractionDigits = unit.fractionDigits
            return f
        }()
        let wStr = fmt.string(from: NSNumber(value: Double(w))) ?? "\(w)"
        let hStr = fmt.string(from: NSNumber(value: Double(h))) ?? "\(h)"
        return "Page: \(wStr) × \(hStr) \(unit.shortLabel) (\(Int(settings.paperWidth)) × \(Int(settings.paperHeight)) pt)"
    }

    private func marginField(_ label: String, value: Binding<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption)
            TextField(
                settings.displayUnit.shortLabel,
                value: Binding(
                    get: { Double(settings.value(fromPoints: value.wrappedValue)) },
                    set: { value.wrappedValue = settings.points(fromValue: CGFloat($0)) }
                ),
                format: .number.precision(.fractionLength(settings.displayUnit.fractionDigits))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
        }
    }
}
