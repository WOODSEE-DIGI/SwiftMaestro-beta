import SwiftUI

/// Browse the plans visible to an agent. Personal plans belong to this agent;
/// project scopes show plans shared across a project (the Navigator can browse
/// any project's). Read-only viewer with delete; editing is done by the agent.
struct PlansSheet: View {
    @Environment(PlanStore.self) private var planStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let agentId: UUID
    /// Project names selectable as scopes (besides the personal scope).
    let projects: [String]
    /// When set, the initially-selected scope is this project (project agents).
    let defaultProjectName: String?

    @State private var selectedScopeKey: String = ""
    @State private var selectedPlanID: UUID?
    @State private var exporting = false

    private var scopes: [(label: String, scope: PlanScope)] {
        var out: [(String, PlanScope)] = [("Personal", .agent(agentId))]
        out += projects.map { ($0, .project($0)) }
        return out
    }

    private var selectedScope: PlanScope {
        scopes.first { $0.scope.key == selectedScopeKey }?.scope ?? .agent(agentId)
    }

    /// The plan currently selected in the list (for export).
    private var selectedPlan: Plan? {
        (planStore.plansByScope[selectedScope.key] ?? []).first { $0.id == selectedPlanID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                Text("Plans").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()

            if scopes.count > 1 {
                Picker("Scope", selection: $selectedScopeKey) {
                    ForEach(scopes, id: \.scope.key) { entry in
                        Text(entry.label).tag(entry.scope.key)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }

            let plans = planStore.plansByScope[selectedScope.key] ?? []
            if plans.isEmpty {
                Spacer()
                Text("No plans in this scope yet. Ask the agent to create one.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                HStack(spacing: 0) {
                    List(plans, selection: $selectedPlanID) { plan in
                        Text(plan.title).lineLimit(2).tag(plan.id)
                    }
                    .frame(width: 220)
                    Divider()
                    detail(for: plans)
                }
            }
        }
        .frame(width: 760, height: 560)
        .fileExporter(
            isPresented: $exporting,
            document: selectedPlan.map { MarkdownDocument(text: "# \($0.title)\n\n\($0.content)\n") },
            contentType: MarkdownDocument.markdown,
            defaultFilename: selectedPlan?.title
        ) { _ in }
        .task(id: selectedScopeKey) {
            _ = planStore.plans(in: selectedScope)
            if selectedPlanID == nil
                || !(planStore.plansByScope[selectedScope.key] ?? []).contains(where: { $0.id == selectedPlanID }) {
                selectedPlanID = planStore.plansByScope[selectedScope.key]?.first?.id
            }
        }
        .onAppear {
            if selectedScopeKey.isEmpty {
                selectedScopeKey = defaultProjectName.map { PlanScope.project($0).key }
                    ?? PlanScope.agent(agentId).key
            }
        }
    }

    @ViewBuilder
    private func detail(for plans: [Plan]) -> some View {
        if let plan = plans.first(where: { $0.id == selectedPlanID }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(plan.title).font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        openWindow(
                            id: "plan-window",
                            value: PlanWindowID(scopeKey: selectedScope.key, planID: plan.id))
                    } label: {
                        Image(systemName: "macwindow")
                    }
                    .buttonStyle(.plain)
                    .help("Open in a resizable window")
                    Button {
                        exporting = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .help("Export as Markdown")
                    Button(role: .destructive) {
                        let next = plans.first(where: { $0.id != plan.id })?.id
                        planStore.delete(id: plan.id, in: selectedScope)
                        selectedPlanID = next
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Delete this plan")
                }
                .padding(12)
                Divider()
                ScrollView {
                    Text(Self.rendered(plan.content))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        } else {
            VStack { Spacer(); Text("Select a plan").foregroundStyle(.secondary); Spacer() }
                .frame(maxWidth: .infinity)
        }
    }

    /// Render markdown preserving line breaks (inline styles only); falls back to
    /// plain text if parsing fails.
    private static func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}
