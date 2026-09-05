import SwiftUI

// MARK: - Pipeline Page

/// Sales pipeline and lead management for MaestroBooks. This is the front of
/// the business workflow: leads enter here, convert to clients, and are later
/// invoiced from the Clients and Invoices pages.
struct PipelinePage: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme

    @State private var selectedTab: PipelineTab = .pipeline
    @State private var selectedLead: BooksCRMLead?
    @State private var showLeadEditor = false
    @State private var activityContact: CRMActivityContact?

    private enum PipelineTab: String, CaseIterable, Identifiable {
        case pipeline = "Pipeline"
        case leads = "Leads"
        case activities = "Activities"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch selectedTab {
            case .pipeline:
                PipelineView(
                    viewModel: viewModel,
                    selectedLead: $selectedLead,
                    showEditor: $showLeadEditor)
            case .leads:
                LeadsView(
                    viewModel: viewModel,
                    selectedLead: $selectedLead,
                    showEditor: $showLeadEditor,
                    onActivity: { lead in
                        activityContact = CRMActivityContact(kind: "lead", contactID: lead.id ?? 0, name: lead.name)
                    })
            case .activities:
                CRMActivitiesView(viewModel: viewModel)
            }
        }
        .sheet(isPresented: $showLeadEditor) {
            CRMLeadEditor(
                viewModel: viewModel,
                lead: selectedLead ?? .blank,
                isPresented: $showLeadEditor)
        }
        .sheet(item: $activityContact) { contact in
            CRMActivityEditor(
                viewModel: viewModel,
                activity: BooksCRMActivity.blankFor(contactKind: contact.kind, contactID: contact.contactID),
                contactName: contact.name,
                isPresented: Binding(
                    get: { activityContact != nil },
                    set: { if !$0 { activityContact = nil } }
                )
            )
        }
    }

    private var header: some View {
        HStack {
            Picker("Pipeline", selection: $selectedTab) {
                ForEach(PipelineTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
            Button {
                switch selectedTab {
                case .pipeline:
                    selectedLead = .blank
                    showLeadEditor = true
                case .leads:
                    selectedLead = .blank
                    showLeadEditor = true
                case .activities:
                    break // Activities are created from a lead or client context.
                }
            } label: {
                Label("New", systemImage: "plus")
            }
            .disabled(selectedTab == .activities)
        }
        .padding()
        .background(theme.secondaryBackground)
    }
}

// MARK: - Pipeline

/// Columns for the lead-based pipeline board, ordered left-to-right.
private struct LeadStatusColumn: Identifiable, Hashable {
    let status: BooksCRMLead.LeadStatus
    var id: BooksCRMLead.LeadStatus { status }
    var title: String { status.displayName }
}

private struct PipelineView: View {
    @Bindable var viewModel: BooksViewModel
    @Binding var selectedLead: BooksCRMLead?
    @Binding var showEditor: Bool
    @Environment(ThemeStore.self) private var theme

    private let columns: [LeadStatusColumn] = [
        LeadStatusColumn(status: .new),
        LeadStatusColumn(status: .contacted),
        LeadStatusColumn(status: .qualified),
        LeadStatusColumn(status: .converted),
        LeadStatusColumn(status: .unqualified),
    ]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns) { column in
                    PipelineColumn(
                        column: column,
                        leads: viewModel.crmLeads.filter { $0.status == column.status },
                        theme: theme,
                        onSelect: { lead in
                            selectedLead = lead
                            showEditor = true
                        })
                }
            }
            .padding()
        }
        .background(theme.chatBackground)
    }
}

private struct PipelineColumn: View {
    let column: LeadStatusColumn
    let leads: [BooksCRMLead]
    let theme: ThemeStore
    let onSelect: (BooksCRMLead) -> Void

    private var total: Double {
        leads.compactMap { $0.estimatedValue }.reduce(0, +)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(column.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(leads.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(theme.secondaryBackground)

            Text(LocaleSettings.shared.defaultCurrency + " " + String(format: "%.0f", total))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(leads) { lead in
                        PipelineCard(lead: lead, theme: theme)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(lead) }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 220)
        .background(theme.secondaryBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PipelineCard: View {
    let lead: BooksCRMLead
    let theme: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lead.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.chatText)
                .lineLimit(2)
            if let company = lead.company, !company.isEmpty {
                Text(company)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let value = lead.estimatedValue {
                HStack {
                    Spacer()
                    Text(BooksMoney.format(value, currency: lead.currency))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.chatText)
                }
            }
        }
        .padding(10)
        .background(theme.chatBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Leads

private struct LeadsView: View {
    @Bindable var viewModel: BooksViewModel
    @Binding var selectedLead: BooksCRMLead?
    @Binding var showEditor: Bool
    let onActivity: (BooksCRMLead) -> Void
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        List(viewModel.crmLeads) { lead in
            LeadRow(lead: lead, theme: theme)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedLead = lead
                    showEditor = true
                }
                .contextMenu {
                    Button {
                        onActivity(lead)
                    } label: {
                        Label("Add Activity", systemImage: "note.text")
                    }
                    if lead.status != .converted {
                        Button {
                            Task { await viewModel.convertCRMLeadToClient(id: lead.id ?? 0) }
                        } label: {
                            Label("Convert to Client", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                    Button(role: .destructive) {
                        Task { await viewModel.deleteCRMLead(id: lead.id ?? 0) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.chatBackground)
    }
}

private struct LeadRow: View {
    let lead: BooksCRMLead
    let theme: ThemeStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lead.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.chatText)
                if let company = lead.company, !company.isEmpty {
                    Text(company)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if let email = lead.email, !email.isEmpty {
                        Label(email, systemImage: "envelope")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let phone = lead.phone, !phone.isEmpty {
                        Label(phone, systemImage: "phone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(lead.status.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .foregroundStyle(statusColor)
                    .clipShape(Capsule())
                if let value = lead.estimatedValue {
                    Text(BooksMoney.format(value, currency: lead.currency))
                        .font(.caption)
                        .foregroundStyle(theme.chatText)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch lead.status {
        case .new: return .blue
        case .contacted: return .orange
        case .qualified: return .green
        case .unqualified: return .red
        case .converted: return .purple
        }
    }
}

// MARK: - Activities

private struct CRMActivitiesView: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        let all = viewModel.crmActivities
            .map { activity -> (BooksCRMActivity, String) in
                let name = contactName(for: activity)
                return (activity, name)
            }
            .sorted { a, b in
                let da = a.0.completedDate ?? a.0.dueDate ?? a.0.createdAt
                let db = b.0.completedDate ?? b.0.dueDate ?? b.0.createdAt
                return da > db
            }

        List(all, id: \.0.id) { activity, name in
            ActivityRow(activity: activity, contactName: name, theme: theme)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.chatBackground)
    }

    private func contactName(for activity: BooksCRMActivity) -> String {
        if activity.contactKind == "lead",
           let lead = viewModel.crmLeads.first(where: { $0.id == activity.contactID }) {
            return lead.name
        }
        if activity.contactKind == "client",
           let client = viewModel.clients.first(where: { $0.id == activity.contactID }) {
            return client.name
        }
        if activity.contactKind == "opportunity",
           let opp = viewModel.crmOpportunities.first(where: { $0.id == activity.contactID }) {
            return opp.title
        }
        return activity.contactKind.capitalized
    }
}

private struct ActivityRow: View {
    let activity: BooksCRMActivity
    let contactName: String
    let theme: ThemeStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: activity.kind.icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.subject)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.chatText)
                Text(contactName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notes = activity.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let due = activity.dueDate, activity.completedDate == nil {
                    Text("Due \(due.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Activity blank helper

extension BooksCRMActivity {
    static func blankFor(contactKind: String, contactID: Int64) -> BooksCRMActivity {
        var activity = BooksCRMActivity.blank
        activity.contactKind = contactKind
        activity.contactID = contactID
        return activity
    }
}
