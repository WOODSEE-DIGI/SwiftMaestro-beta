import SwiftUI

// MARK: - P2P Blacklist Page

/// Dedicated MaestroBooks page for the peer-to-peer unpaid-invoice blacklist.
/// Combines a detailed explainer with the switches the user needs to control
/// participation, defaults, and pending reports.
struct P2PBlacklistPage: View {
    @State private var viewModel = BooksViewModel()

    // Master participation switch. Stored in UserDefaults and read by
    // LocaleSettings.p2pBlacklistEnabled throughout the app.
    @AppStorage("sm_p2p_blacklist_enabled")
    private var p2pEnabled = false

    // Default for newly-created clients.
    @AppStorage("sm_p2p_default_client_reportable")
    private var defaultClientReporting = true

    // Default for newly-created invoices (true = inherit from client).
    @AppStorage("sm_p2p_default_invoice_inherit")
    private var defaultInvoiceInherit = true

    @State private var clientSummary = ClientReportingSummary()
    @State private var pendingReports: [BlacklistReport] = []
    @State private var showWithdrawAlert = false
    @State private var reportToWithdraw: BlacklistReport?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection

                participationSection

                defaultRulesSection

                privacySection

                pendingReportsSection

                disputesSection

                legalNoteSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await refresh()
        }
        .alert("Withdraw report?", isPresented: $showWithdrawAlert, presenting: reportToWithdraw) { report in
            Button("Withdraw", role: .destructive) {
                withdraw(report)
            }
            Button("Cancel", role: .cancel) {}
        } message: { report in
            Text("This removes your local pending report for \(report.debtorName). If already published, a revocation must be sent from Settings → Privacy.")
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("P2P Blacklist Reporting")
                .font(.largeTitle.weight(.bold))
            Text("A voluntary, decentralised way for SwiftMaestro users to warn each other about businesses that repeatedly fail to pay invoices.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var participationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Participate in the network")
                            .font(.headline)
                        Text("When on, MaestroBooks can look up warnings from other users and publish reports you choose to share. This is off by default.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $p2pEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                statusBadge(
                    p2pEnabled
                        ? ("Active", "checkmark.shield.fill", .green)
                        : ("Disabled", "shield.slash", .orange)
                )

                if !p2pEnabled {
                    Label(
                        "No data leaves this Mac, and no warnings from other users are shown.",
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } label: {
            Label("Your participation", systemImage: "network")
                .font(.headline)
        }
    }

    private var defaultRulesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Allow reporting for new clients by default", isOn: $defaultClientReporting)
                    Text("You can still change this for each individual client. Existing clients are not affected by this switch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("New invoices inherit the client setting", isOn: $defaultInvoiceInherit)
                    Text("When on, a new invoice follows its client's allow/block choice. You can override any invoice before it becomes eligible for reporting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack(alignment: .top, spacing: 16) {
                    statCard(title: "Clients allowing reports", value: "\(clientSummary.allowing) / \(clientSummary.total)")
                    statCard(title: "Clients blocking reports", value: "\(clientSummary.blocking) / \(clientSummary.total)")
                    statCard(title: "Pending reports", value: "\(pendingReports.count)")
                }

                Text("To change an existing client, open the Clients tab and edit the client. To block a single invoice, open the invoice and set P2P Blacklist Reporting to Do not report this invoice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        } label: {
            Label("Reporting rules", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
    }

    private var privacySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                privacyRow(
                    icon: "person.crop.circle.badge.xmark",
                    title: "No raw PII is shared",
                    detail: "Business names, ABNs, addresses, and exact invoice amounts never leave your device. The network only sees a SHA-256 fingerprint, an amount band, currency, days overdue, and a timestamp."
                )

                privacyRow(
                    icon: "eye.slash",
                    title: "Private matching",
                    detail: "Other users compute fingerprints from their own contacts and check them locally. The network never learns which contacts they looked up."
                )

                privacyRow(
                    icon: "signature",
                    title: "Pseudonymous reporter identity",
                    detail: "Each opted-in device gets an Ed25519 key pair. The public-key fingerprint is published with a report so the same reporter can build reputation and revoke their own reports. Your name and email are never included."
                )

                privacyRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Evidence stays local",
                    detail: "Only a hash of the invoice PDF is published. The PDF itself remains on your Mac and can be used to resolve disputes privately."
                )

                privacyRow(
                    icon: "checkmark.shield",
                    title: "Optional verification",
                    detail: "For Australian businesses, MaestroBooks can verify the ABN against the ABR bulk extract or ABN Lookup before publishing. The network sees only 'ABN verified', not the ABN itself."
                )
            }
            .padding(8)
        } label: {
            Label("Privacy & what is shared", systemImage: "hand.raised")
                .font(.headline)
        }
    }

    private var pendingReportsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                if pendingReports.isEmpty {
                    Label("No pending reports", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Text("These reports are prepared but have not been published. Nothing leaves this Mac until you publish.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(pendingReports) { report in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(report.debtorName)
                                    .font(.body.weight(.medium))
                                Text("\(report.amountBand.rawValue) \(report.currency) · \(report.daysOverdueAtReport) days overdue · \(report.reportedAt, style: .date)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                reportToWithdraw = report
                                showWithdrawAlert = true
                            } label: {
                                Label("Withdraw", systemImage: "xmark")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }

                    Button {
                        // Publishing requires the p2p gossip/relay layer, which is
                        // not yet enabled in this build.
                    } label: {
                        Label("Publish pending reports", systemImage: "arrow.up.circle")
                    }
                    .disabled(true)
                    .help("Publishing to the P2P network is not yet enabled in this build.")
                }
            }
            .padding(8)
        } label: {
            Label("Pending reports", systemImage: "exclamationmark.triangle")
                .font(.headline)
        }
    }

    private var disputesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("If a debt is paid or disputed, you should withdraw the report. Once the P2P network is live, a debtor will also be able to publish a counter-attestation. Reports automatically expire after 7 years.")
                    .font(.body)

                Text("To withdraw a pending report now, use the Withdraw button above. To revoke a report that has already been published, go to Settings → Privacy once publishing is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        } label: {
            Label("Disputes & removal", systemImage: "arrow.uturn.backward.circle")
                .font(.headline)
        }
    }

    private var legalNoteSection: some View {
        GroupBox {
            Text("These reports are user-generated attestations, not verified by WOODSEE-DIGI or SwiftMaestro. They are intended as a reputation signal only. Use them alongside your own due diligence. Defamation, privacy, and consumer-law obligations in your jurisdiction remain your responsibility.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        } label: {
            Label("Important legal note", systemImage: "building.columns")
                .font(.headline)
        }
    }

    // MARK: - Helpers

    private func statusBadge(_ status: (String, String, Color)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: status.1)
                .foregroundStyle(status.2)
            Text(status.0)
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status.2.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
        }
        .frame(minWidth: 140, alignment: .leading)
        .padding(10)
        .background(.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func privacyRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Data

    private func refresh() async {
        await viewModel.reload()
        await refreshClientSummary()
        pendingReports = BlacklistReportStore.shared.reports().filter { $0.status == .pending }
    }

    private func refreshClientSummary() async {
        do {
            let clients = try BooksDatabase.shared.clients()
            let total = clients.count
            let allowing = clients.filter(\.reportToBlacklist).count
            clientSummary = ClientReportingSummary(total: total, allowing: allowing, blocking: total - allowing)
        } catch {
            clientSummary = ClientReportingSummary(total: 0, allowing: 0, blocking: 0)
        }
    }

    private func withdraw(_ report: BlacklistReport) {
        var updated = report
        updated.status = .withdrawn
        BlacklistReportStore.shared.save(updated)
        pendingReports = BlacklistReportStore.shared.reports().filter { $0.status == .pending }
    }
}

// MARK: - Client Reporting Summary

private struct ClientReportingSummary {
    var total = 0
    var allowing = 0
    var blocking = 0
}
