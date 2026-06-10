import SwiftUI

/// Browse the plans an agent has authored (via the create_plan / edit_plan
/// tools). Read-only viewer with delete; editing is done by the agent.
struct PlansSheet: View {
    @Environment(PlanStore.self) private var planStore
    @Environment(\.dismiss) private var dismiss
    let agentId: UUID
    @State private var selectedID: UUID?

    var body: some View {
        let plans = planStore.plans[agentId] ?? []
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                Text("Plans").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()

            if plans.isEmpty {
                Spacer()
                Text("No plans yet. Ask the agent to create one.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                HStack(spacing: 0) {
                    List(plans, selection: $selectedID) { plan in
                        Text(plan.title).lineLimit(2).tag(plan.id)
                    }
                    .frame(width: 220)
                    Divider()
                    detail(for: plans)
                }
            }
        }
        .frame(width: 760, height: 540)
        .task {
            // Load persisted plans from disk if not already cached this session.
            _ = planStore.plans(for: agentId)
            if selectedID == nil { selectedID = planStore.plans[agentId]?.first?.id }
        }
    }

    @ViewBuilder
    private func detail(for plans: [Plan]) -> some View {
        if let plan = plans.first(where: { $0.id == selectedID }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(plan.title).font(.title3.weight(.semibold))
                    Spacer()
                    Button(role: .destructive) {
                        let next = plans.first(where: { $0.id != plan.id })?.id
                        planStore.delete(id: plan.id, for: agentId)
                        selectedID = next
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
