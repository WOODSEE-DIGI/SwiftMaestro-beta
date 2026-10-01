import SwiftUI

/// Manage plan project scopes: archive/unarchive, bulk-delete, and auto-archive
/// scopes that haven't been updated in 60 days.
struct ScopeManagementSheet: View {
    @Environment(PlanStore.self) private var planStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingDeleteConfirmation = false
    @State private var scopeNameToDelete: String?
    @State private var archivedCount = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text("Manage Scopes")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        archivedCount = planStore.archiveInactiveProjectScopes().count
                    } label: {
                        Label("Archive inactive (60 days)", systemImage: "archivebox")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if archivedCount > 0 {
                        Text("Archived \(archivedCount) scope(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Text("Archived scopes are hidden from the New Plan picker but their plans stay on disk. Delete permanently removes a scope and all its plans.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            List {
                Section("Active Scopes") {
                    ForEach(planStore.activeProjectNames(), id: \.self) { name in
                        scopeRow(name: name, isArchived: false)
                    }
                }

                Section("Archived Scopes") {
                    ForEach(planStore.archivedProjectNames(), id: \.self) { name in
                        scopeRow(name: name, isArchived: true)
                    }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .alert("Delete Scope?", isPresented: $showingDeleteConfirmation, presenting: scopeNameToDelete) { name in
            Button("Delete All Plans", role: .destructive) {
                let scope = PlanScope.project(name)
                planStore.clear(in: scope)
                planStore.unarchive(scope)
                scopeNameToDelete = nil
            }
            Button("Cancel", role: .cancel) { scopeNameToDelete = nil }
        } message: { name in
            Text("Permanently delete all plans in '\(name)'? This cannot be undone.")
        }
    }

    private func scopeRow(name: String, isArchived: Bool) -> some View {
        let scope = PlanScope.project(name)
        let plans = planStore.plans(in: scope)
        let lastUpdate = plans.map(\.updatedAt).max()

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.weight(isArchived ? .regular : .medium))
                Text(plans.isEmpty ? "No plans" : "\(plans.count) plan(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let lastUpdate {
                Text("Updated \(PlanMetadataFormatter.relativeString(lastUpdate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isArchived {
                Button {
                    planStore.unarchive(scope)
                } label: {
                    Text("Unarchive")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    planStore.archive(scope)
                } label: {
                    Text("Archive")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button(role: .destructive) {
                scopeNameToDelete = name
                showingDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
