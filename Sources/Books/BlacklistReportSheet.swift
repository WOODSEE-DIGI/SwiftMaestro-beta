import SwiftUI

// MARK: - Blacklist Report Sheet

/// Lets the user review and prepare an unpaid-invoice report before it is ever
/// published. Shows exactly what will be shared and verifies the debtor first.
struct BlacklistReportSheet: View {
    let invoice: BooksInvoice
    let client: BooksClient
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var report: BlacklistReport?
    @State private var statusMessage: String?
    @State private var isPreparing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if isPreparing {
                        ProgressView("Preparing report…")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if let report {
                        reportReview(report)
                    } else {
                        notEligibleMessage
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                Spacer()
                if let report, report.status == .pending {
                    Button("Save Report") {
                        saveReport(report)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(theme.secondaryBackground)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420)
        .background(theme.chatBackground)
        .task {
            await prepare()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Prepare Blacklist Report")
                    .font(.headline)
                Text("Review what will be shared")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(theme.secondaryBackground)
    }

    private func reportReview(_ report: BlacklistReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Debtor") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.debtorName)
                        .font(.body.weight(.medium))
                    if let tax = report.debtorTaxNumber {
                        Text("\(LocaleSettings.shared.primaryBusinessTaxIdentifier.localizedLabel): \(tax)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Country: \(report.debtorCountry)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Verification") {
                HStack {
                    if let proof = report.verifierProof {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text("Verified via \(proof.kind)")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                        Text("Could not be verified against bulk extract or lookup.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            GroupBox("What will be shared") {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "Fingerprint", value: shortFingerprint(report.debtorFingerprint))
                    InfoRow(label: "Amount band", value: report.amountBand.rawValue)
                    InfoRow(label: "Currency", value: report.currency)
                    InfoRow(label: "Days overdue", value: "\(report.daysOverdueAtReport)")
                    if report.evidenceHash != nil {
                        InfoRow(label: "Evidence", value: "Hash attached")
                    }
                }
            }

            GroupBox("Privacy note") {
                Text("Your report will be saved locally in a pending state. No data leaves this Mac until you explicitly choose to publish via Settings → Privacy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notEligibleMessage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This invoice cannot be reported")
                .font(.title3.weight(.bold))
            Text("Invoices must be authorised, at least 60 days overdue, and not opted out of blacklist reporting by the client or invoice settings.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    private func prepare() async {
        isPreparing = true
        report = await BlacklistReportService.shared.prepareReport(invoice: invoice, client: client)
        isPreparing = false
    }

    private func saveReport(_ report: BlacklistReport) {
        BlacklistReportStore.shared.save(report)
        statusMessage = "Report saved. Publish from Settings → Privacy when ready."
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            dismiss()
        }
    }

    private func shortFingerprint(_ fingerprint: String) -> String {
        let prefix = fingerprint.prefix(8)
        let suffix = fingerprint.suffix(8)
        return "\(prefix)...\(suffix)"
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}
