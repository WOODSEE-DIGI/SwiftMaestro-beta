import SwiftUI

// MARK: - Diagnostic Report Sheet
//
// The user-facing half of DiagnosticReportService: describe the problem,
// choose which evidence sections to include, read the EXACT redacted JSON
// payload, then — and only then — press Send. Every report is its own
// explicit act of consent; there is no standing opt-in and nothing ever
// sends automatically.

struct DiagnosticReportView: View {
    /// Prefill from the agent flow (Mechanic can open this sheet with a
    /// description and media path — but only the user presses Send).
    var initialDescription: String = ""
    var initialMediaPath: String = ""

    @Environment(\.dismiss) private var dismiss

    @State private var description: String = ""
    @State private var contactEmail: String = ""
    @State private var includeCrashes = true
    @State private var includeSelfHealing = true
    @State private var includeMedia = false
    @State private var mediaPath: String = ""

    @State private var previewText: String = ""
    @State private var sending = false
    @State private var referenceID: String?
    @State private var sendError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send Diagnostic Report")
                .font(.title3.bold())

            Text("For problems that need a code fix. This report is **anonymous**, sent **only when you click Send**, and shown in full below before it leaves your Mac. Nothing is ever collected automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("What happened?")
                .font(.headline)
            TextEditor(text: $description)
                .font(.body)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))

            HStack {
                Text("Contact email")
                    .foregroundStyle(.secondary)
                TextField("optional — only if you want a reply", text: $contactEmail)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Include recent crash reports (newest 3, last 7 days)", isOn: $includeCrashes)
                Toggle("Include self-healing log (tool failure history)", isOn: $includeSelfHealing)
                Toggle("Include media file diagnosis", isOn: $includeMedia)
                if includeMedia {
                    TextField("Path to the media file (e.g. ~/Movies/clip.mkv)", text: $mediaPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                }
            }
            .controlSize(.small)

            Text("Exact payload (already redacted — read it before sending):")
                .font(.headline)
            ScrollView {
                Text(previewText)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 160, maxHeight: 240)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))

            if let sendError {
                Text(sendError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let referenceID {
                Text("Sent — reference \(referenceID). Thank you.")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task { await send() }
                } label: {
                    if sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Send Anonymously")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || referenceID != nil)
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear {
            description = initialDescription
            mediaPath = initialMediaPath
            includeMedia = !initialMediaPath.isEmpty
            Task { await refreshPreview() }
        }
        .onChange(of: description) { Task { await refreshPreview() } }
        .onChange(of: contactEmail) { Task { await refreshPreview() } }
        .onChange(of: includeCrashes) { Task { await refreshPreview() } }
        .onChange(of: includeSelfHealing) { Task { await refreshPreview() } }
        .onChange(of: includeMedia) { Task { await refreshPreview() } }
        .onChange(of: mediaPath) { Task { await refreshPreview() } }
    }

    private func refreshPreview() async {
        let report = await DiagnosticReportService.shared.buildReport(
            description: description,
            contactEmail: contactEmail,
            includeCrashes: includeCrashes,
            includeSelfHealing: includeSelfHealing,
            mediaPath: includeMedia ? mediaPath : nil
        )
        if let data = try? DiagnosticReportService.shared.redactedJSON(for: report) {
            previewText = String(decoding: data, as: UTF8.self)
        }
    }

    private func send() async {
        sending = true
        sendError = nil
        let report = await DiagnosticReportService.shared.buildReport(
            description: description,
            contactEmail: contactEmail,
            includeCrashes: includeCrashes,
            includeSelfHealing: includeSelfHealing,
            mediaPath: includeMedia ? mediaPath : nil
        )
        do {
            referenceID = try await DiagnosticReportService.shared.send(report: report)
        } catch {
            sendError = error.localizedDescription
        }
        sending = false
    }
}
