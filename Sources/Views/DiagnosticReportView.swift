import SwiftUI
import AppKit

// MARK: - Diagnostic Report Sheet
//
// The user-facing half of DiagnosticReportService: describe the problem,
// choose which evidence sections to include, read the EXACT redacted JSON
// payload, then — and only then — press Send. Every report is its own
// explicit act of consent; there is no standing opt-in and nothing ever
// sends automatically.
//
// Attachments are security-scanned on the user's Mac before they are included,
// and images are OCR'd so the developers can read any error text visible in
// screenshots.

struct DiagnosticReportView: View {
    /// Prefill from the agent flow (Swift Helper can open this sheet with a
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
    @State private var includeOCR = true

    @State private var previewText: String = ""
    @State private var sending = false
    @State private var referenceID: String?
    @State private var sendError: String?
    @State private var scanResult: SecurityScanResult?
    @State private var scanning = false

    private var mediaSecurityPassed: Bool {
        guard includeMedia, !mediaPath.isEmpty else { return true }
        guard let scan = scanResult else { return false }
        return scan.passed
    }

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
                    HStack {
                        TextField("Path to the media file (e.g. ~/Desktop/screenshot.png)", text: $mediaPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                        Button("Choose…") { chooseMediaFile() }
                            .controlSize(.small)
                    }

                    Toggle("Run OCR on images (extract visible error text)", isOn: $includeOCR)
                        .controlSize(.small)

                    if scanning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Running security scan…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let scan = scanResult {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: scan.passed ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                    .foregroundStyle(scan.passed ? .green : .red)
                                Text(scan.passed ? "Security scan passed" : "Security scan failed")
                                    .font(.caption.bold())
                                    .foregroundStyle(scan.passed ? .green : .red)
                            }
                            if !scan.recommendations.isEmpty {
                                ForEach(scan.recommendations, id: \.self) { rec in
                                    Text("• \(rec)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Text("Type: \(scan.fileType)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if !scan.clamAV.available {
                                Text("ClamAV not installed. Run `brew install clamav && freshclam` for deeper malware scanning.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
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
                .disabled(
                    description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || sending
                    || referenceID != nil
                    || (includeMedia && !mediaPath.isEmpty && !mediaSecurityPassed)
                )
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
        .onChange(of: includeMedia) { Task { await scanAndRefresh() } }
        .onChange(of: includeOCR) { Task { await refreshPreview() } }
        .onChange(of: mediaPath) { Task { await scanAndRefresh() } }
    }

    private func chooseMediaFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            mediaPath = url.path
        }
    }

    private func scanAndRefresh() async {
        scanning = true
        scanResult = nil
        defer { scanning = false }
        if includeMedia, !mediaPath.isEmpty {
            scanResult = await SecurityScanService.shared.scanFile(at: mediaPath)
        }
        await refreshPreview()
    }

    private func refreshPreview() async {
        let report = await DiagnosticReportService.shared.buildReport(
            description: description,
            contactEmail: contactEmail,
            includeCrashes: includeCrashes,
            includeSelfHealing: includeSelfHealing,
            mediaPath: includeMedia ? mediaPath : nil,
            includeOCR: includeOCR
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
            mediaPath: includeMedia ? mediaPath : nil,
            includeOCR: includeOCR
        )
        do {
            referenceID = try await DiagnosticReportService.shared.send(report: report)
        } catch {
            sendError = error.localizedDescription
        }
        sending = false
    }
}
