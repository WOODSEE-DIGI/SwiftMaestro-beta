import SwiftUI

// MARK: - Business Verification Settings Tab

/// Imports Australian government bulk datasets for offline business verification.
/// All parsing happens on-device; raw identifiers are cached locally and never
/// sent to shared memory or remote services except for optional live lookups.
struct BusinessVerificationSettingsTab: View {
    @Environment(ThemeStore.self) private var theme
    @State private var abrExtractCount = ABNVerifierService.shared.bulkExtractCount
    @State private var asicExtractCount = ABNVerifierService.shared.asicExtractCount
    @State private var businessNameCount = ABNVerifierService.shared.businessNameExtractCount
    @State private var statusMessage: String?
    @State private var isImporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Business Verification")
                    .font(.title2.bold())

                Text("Import public datasets from data.gov.au to verify ABNs, ACNs and business names without sending them to third-party services.")
                    .foregroundStyle(.secondary)

                datasetSection(
                    title: "ABR Bulk Extract",
                    icon: "doc.text",
                    description: "Weekly ABN extract from the Australian Business Register. Contains ABN, entity name, status and GST registration date.",
                    url: "https://data.gov.au/data/dataset/abn-bulk-extract",
                    status: "\(abrExtractCount) records",
                    action: importABRExtract)

                datasetSection(
                    title: "ASIC Company Dataset",
                    icon: "building.2",
                    description: "Weekly company register extract from ASIC. Contains company name, ACN, ABN, status and registration dates.",
                    url: "https://data.gov.au/data/dataset/asic-companies",
                    status: "\(asicExtractCount) records",
                    action: importASICCompanies)

                datasetSection(
                    title: "ASIC Business Names Dataset",
                    icon: "signature",
                    description: "Monthly business names register extract from ASIC. Maps business names to ABN and status.",
                    url: "https://data.gov.au/data/dataset/asic-business-names",
                    status: "\(businessNameCount) records",
                    action: importASICBusinessNames)

                datasetSection(
                    title: "OSINT Industries",
                    icon: "binoculars",
                    description: "Optional background checks on CRM contacts using email, phone, username or name. Requires an API key from osint.industries/offerings/api-access. Add it in Settings → Secrets as \(OSINTIndustriesService.secretName).",
                    url: "https://www.osint.industries/offerings/api-access",
                    status: OSINTIndustriesService.shared.isConfigured ? "Configured" : "Not configured",
                    action: {})

                if let statusMessage {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(statusMessage)
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                }

                Spacer()
            }
            .padding()
        }
        .background(theme.chatBackground)
    }

    private func datasetSection(
        title: String,
        icon: String,
        description: String,
        url: String,
        status: String,
        action: @escaping () -> Void
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(theme.accent)
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Link("Open on data.gov.au", destination: URL(string: url)!)
                        .font(.callout)

                    Spacer()

                    Button {
                        action()
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(isImporting)
                }
            }
            .padding(4)
        }
    }

    private func importABRExtract() {
        presentImport { url in
            let imported = try await ABNVerifierService.shared.importBulkExtract(from: url)
            await MainActor.run {
                abrExtractCount = imported
                statusMessage = "Imported \(imported) ABN records."
            }
        }
    }

    private func importASICCompanies() {
        presentImport { url in
            let imported = try await ABNVerifierService.shared.importASICExtract(from: url)
            await MainActor.run {
                asicExtractCount = imported
                statusMessage = "Imported \(imported) ASIC company records."
            }
        }
    }

    private func importASICBusinessNames() {
        presentImport { url in
            let imported = try await ABNVerifierService.shared.importASICBusinessNames(from: url)
            await MainActor.run {
                businessNameCount = imported
                statusMessage = "Imported \(imported) business name records."
            }
        }
    }

    private func presentImport(importBlock: @escaping (_ url: URL) async throws -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .zip, .init(filenameExtension: "csv")!]
        panel.message = "Select a downloaded data.gov.au extract"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        statusMessage = "Importing…"
        Task {
            do {
                _ = try await importBlock(url)
            } catch {
                statusMessage = "Import failed: \(error.localizedDescription)"
            }
            isImporting = false
        }
    }
}
