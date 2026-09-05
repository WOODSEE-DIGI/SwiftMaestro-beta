import SwiftUI

// MARK: - CRM Lead Editor

struct CRMLeadEditor: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme
    @Binding var isPresented: Bool

    @State private var lead: BooksCRMLead
    private let isNew: Bool

    init(viewModel: BooksViewModel, lead: BooksCRMLead, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        self._isPresented = isPresented
        self._lead = State(initialValue: lead)
        self.isNew = lead.id == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Lead" : "Edit Lead")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.borderless)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(lead.name.isEmpty)
            }
            .padding()
            .background(theme.secondaryBackground)

            let flag = RiskFlagService.shared.flag(for: lead.name, taxID: lead.taxNumber, country: lead.country)
            if let flag {
                RiskFlagBanner(flag: flag)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            Form {
                TextField("Name", text: $lead.name)
                TextField("Company", text: binding(for: $lead.company))
                TextField("Email", text: binding(for: $lead.email))
                TextField("Phone", text: binding(for: $lead.phone))
                TextField(LocaleSettings.shared.primaryBusinessTaxIdentifier.localizedLabel, text: binding(for: $lead.taxNumber))
                TextField("Country", text: binding(for: $lead.country))
                Picker("Status", selection: $lead.status) {
                    ForEach(BooksCRMLead.LeadStatus.allCases, id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                }
                TextField("Source", text: binding(for: $lead.source))
                TextField("Estimated value", value: $lead.estimatedValue, format: .number)
                TextField("Currency", text: $lead.currency)
                TextField("Assigned to", text: binding(for: $lead.assignedTo))
                TextField("Notes", text: binding(for: $lead.notes))
            }
            .padding()
            .frame(minWidth: 380, idealWidth: 520)

            Spacer()
        }
        .background(theme.chatBackground)
    }

    private func binding(for optional: Binding<String?>) -> Binding<String> {
        Binding(get: { optional.wrappedValue ?? "" }, set: { optional.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func save() {
        Task {
            var mutable = lead
            await viewModel.saveCRMLead(&mutable)
            isPresented = false
        }
    }
}

// MARK: - CRM Opportunity Editor

struct CRMOpportunityEditor: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme
    @Binding var isPresented: Bool

    @State private var opportunity: BooksCRMOpportunity
    @State private var linkToClient: Bool
    private let isNew: Bool

    init(viewModel: BooksViewModel, opportunity: BooksCRMOpportunity, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        self._isPresented = isPresented
        self._opportunity = State(initialValue: opportunity)
        self.isNew = opportunity.id == nil
        self._linkToClient = State(initialValue: opportunity.clientID != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Opportunity" : "Edit Opportunity")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.borderless)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(opportunity.title.isEmpty)
            }
            .padding()
            .background(theme.secondaryBackground)

            Form {
                TextField("Title", text: $opportunity.title)

                Picker("Linked to", selection: $linkToClient) {
                    Text("Lead").tag(false)
                    Text("Client").tag(true)
                }
                .pickerStyle(.segmented)

                if linkToClient {
                    Picker("Client", selection: Binding(
                        get: { opportunity.clientID ?? 0 },
                        set: { opportunity.clientID = $0 == 0 ? nil : $0; opportunity.leadID = nil }
                    )) {
                        Text("Select client").tag(Int64(0))
                        ForEach(viewModel.clients) { client in
                            Text(client.name).tag(client.id ?? Int64(0))
                        }
                    }
                } else {
                    Picker("Lead", selection: Binding(
                        get: { opportunity.leadID ?? 0 },
                        set: { opportunity.leadID = $0 == 0 ? nil : $0; opportunity.clientID = nil }
                    )) {
                        Text("Select lead").tag(Int64(0))
                        ForEach(viewModel.crmLeads) { lead in
                            Text(lead.name).tag(lead.id ?? Int64(0))
                        }
                    }
                }

                Picker("Stage", selection: $opportunity.stage) {
                    ForEach(BooksCRMOpportunity.OpportunityStage.allCases, id: \.self) { stage in
                        Text(stage.displayName).tag(stage)
                    }
                }

                TextField("Value", value: $opportunity.value, format: .number)
                TextField("Currency", text: $opportunity.currency)
                Slider(value: Binding(
                    get: { Double(opportunity.probability) },
                    set: { opportunity.probability = Int($0) }
                ), in: 0...100, step: 5) {
                    Text("Probability: \(opportunity.probability)%")
                }
                DatePicker("Expected close", selection: binding(for: $opportunity.expectedCloseDate), in: Date()..., displayedComponents: .date)
                TextField("Notes", text: binding(for: $opportunity.notes))
            }
            .padding()
            .frame(minWidth: 380, idealWidth: 520)

            Spacer()
        }
        .background(theme.chatBackground)
    }

    private func binding(for optional: Binding<Date?>) -> Binding<Date> {
        Binding(get: { optional.wrappedValue ?? Date() }, set: { optional.wrappedValue = $0 })
    }

    private func binding(for optional: Binding<String?>) -> Binding<String> {
        Binding(get: { optional.wrappedValue ?? "" }, set: { optional.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func save() {
        Task {
            var mutable = opportunity
            await viewModel.saveCRMOpportunity(&mutable)
            isPresented = false
        }
    }
}

// MARK: - CRM Activity Editor

/// Lightweight, identifiable wrapper so `.sheet(item:)` can drive the activity
/// editor. Using an item sheet guarantees the editor only presents when a
/// contact is available, avoiding the empty-sheet crash that happened when
/// `isPresented` and the contact state updated in the same action.
struct CRMActivityContact: Identifiable {
    let id = UUID()
    let kind: String
    let contactID: Int64
    let name: String
}

struct CRMActivityEditor: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme
    @Binding var isPresented: Bool

    @State private var activity: BooksCRMActivity
    let contactName: String

    init(viewModel: BooksViewModel, activity: BooksCRMActivity, contactName: String, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        self._isPresented = isPresented
        self._activity = State(initialValue: activity)
        self.contactName = contactName
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.borderless)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(activity.subject.isEmpty)
            }
            .padding()
            .background(theme.secondaryBackground)

            Form {
                Text("For: \(contactName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Kind", selection: $activity.kind) {
                    ForEach(BooksCRMActivity.Kind.allCases, id: \.self) { kind in
                        Label(kind.rawValue.capitalized, systemImage: kind.icon).tag(kind)
                    }
                }
                TextField("Subject", text: $activity.subject)
                TextField("Notes", text: binding(for: $activity.notes))
                DatePicker("Due", selection: binding(for: $activity.dueDate), displayedComponents: .date)
                Toggle("Completed", isOn: Binding(
                    get: { activity.completedDate != nil },
                    set: { activity.completedDate = $0 ? Date() : nil }
                ))
            }
            .padding()
            .frame(minWidth: 320, idealWidth: 420)

            Spacer()
        }
        .background(theme.chatBackground)
    }

    private func binding(for optional: Binding<String?>) -> Binding<String> {
        Binding(get: { optional.wrappedValue ?? "" }, set: { optional.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func binding(for optional: Binding<Date?>) -> Binding<Date> {
        Binding(get: { optional.wrappedValue ?? Date() }, set: { optional.wrappedValue = $0 })
    }

    private func save() {
        Task {
            var mutable = activity
            await viewModel.saveCRMActivity(&mutable)
            isPresented = false
        }
    }
}
