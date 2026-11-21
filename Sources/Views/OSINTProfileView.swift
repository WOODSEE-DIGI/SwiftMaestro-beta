import SwiftUI

// MARK: - OSINT Profile View

/// Visual profile panel for OSINT investigations. Shows discovered entities as
/// cards the investigator can accept, reject, or mark unsure. The agent reads
/// these statuses back via `read_profile` to steer further searches.
struct OSINTProfileView: View {
    let agentId: UUID

    private let store = OSINTProfileStore.shared
    @Environment(ThemeStore.self) private var theme

    @State private var selectedFilterRaw: String = "all"
    @State private var selectedTypeRaw: String = "all"
    @State private var editingSubjectName = false
    @State private var subjectNameText = ""
    @State private var creatingProfile = false
    @State private var newProfileName = ""
    @State private var viewMode: OSINTProfileViewMode = .list

    private var profile: OSINTProfile {
        store.profile(for: agentId)
    }

    private var profiles: [OSINTProfile] {
        store.allProfiles(for: agentId)
    }

    private enum OSINTProfileViewMode: String, CaseIterable {
        case list = "List"
        case graph = "Graph"
    }

    private var selectedFilter: OSINTVerificationStatus? {
        OSINTVerificationStatus(rawValue: selectedFilterRaw)
    }

    private var selectedType: OSINTEntityType? {
        OSINTEntityType(rawValue: selectedTypeRaw)
    }

    private var filteredFindings: [OSINTProfileFinding] {
        profile.findings.filter { finding in
            if selectedFilterRaw != "all", finding.verificationStatus.rawValue != selectedFilterRaw { return false }
            if selectedTypeRaw != "all", finding.entityType.rawValue != selectedTypeRaw { return false }
            return true
        }
    }

    private var countsByStatus: [OSINTVerificationStatus: Int] {
        Dictionary(grouping: profile.findings, by: \.verificationStatus)
            .mapValues(\.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            HStack {
                viewModePicker
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if viewMode == .graph {
                OSINTGraphView(profiles: profiles)
            } else {
                filterBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
                if filteredFindings.isEmpty {
                    emptyState
                } else {
                    findingsList
                }
            }
        }
        .background(theme.background)
    }

    private var viewModePicker: some View {
        Picker("View", selection: $viewMode) {
            ForEach(OSINTProfileViewMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 140)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.rectangle.stack")
                    .foregroundStyle(theme.accent)
                if editingSubjectName {
                    TextField("Subject name", text: $subjectNameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { updateSubjectName() }
                    Button("Save") { updateSubjectName() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Cancel") {
                        editingSubjectName = false
                        subjectNameText = profile.subjectName ?? ""
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                } else if creatingProfile {
                    TextField("New profile name", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { createProfile() }
                    Button("Create") { createProfile() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Cancel") {
                        creatingProfile = false
                        newProfileName = ""
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                } else {
                    Text(profile.subjectName?.isEmpty == false ? profile.subjectName! : "OSINT Profile")
                        .font(.headline)
                        .lineLimit(1)
                    Button {
                        editingSubjectName = true
                        subjectNameText = profile.subjectName ?? ""
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Edit subject name")
                    profileMenu
                }
                Spacer()
                let accepted = profile.findings.filter { $0.verificationStatus == .accepted }.count
                Text("\(accepted)/\(profile.findings.count) accepted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                StatusBadge(status: .accepted, color: .green, count: countsByStatus[.accepted] ?? 0)
                StatusBadge(status: .unverified, color: .yellow, count: countsByStatus[.unverified] ?? 0)
                StatusBadge(status: .unsure, color: .orange, count: countsByStatus[.unsure] ?? 0)
                StatusBadge(status: .rejected, color: .red, count: countsByStatus[.rejected] ?? 0)
                Spacer()
            }
        }
    }

    // MARK: - Filter Bar

    /// Adapts to the panel width. Wide panels get segmented status tabs; the
    /// default 380 pt panel (and anything narrower) gets compact menus so the
    /// Clear button never overlaps the status control.
    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            wideFilterBar
            narrowFilterBar
        }
    }

    private var wideFilterBar: some View {
        HStack(spacing: 8) {
            statusSegmentedPicker
            typePicker
            Spacer(minLength: 0)
            clearLabelButton
        }
    }

    private var narrowFilterBar: some View {
        HStack(spacing: 8) {
            statusMenuPicker
            typePicker
            Spacer(minLength: 0)
            clearIconButton
        }
    }

    private var statusSegmentedPicker: some View {
        Picker("Status", selection: $selectedFilterRaw) {
            Text("All").tag("all")
            ForEach(OSINTVerificationStatus.allCases, id: \.rawValue) { status in
                Text(status.displayName).tag(status.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .frame(idealWidth: 260, maxWidth: 260)
    }

    private var statusMenuPicker: some View {
        Picker("Status", selection: $selectedFilterRaw) {
            Text("All statuses").tag("all")
            ForEach(OSINTVerificationStatus.allCases, id: \.rawValue) { status in
                Text(status.displayName).tag(status.rawValue)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 140)
    }

    private var typePicker: some View {
        Picker("Type", selection: $selectedTypeRaw) {
            Text("All types").tag("all")
            ForEach(OSINTEntityType.allCases, id: \.rawValue) { type in
                Text(type.displayName).tag(type.rawValue)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 140)
    }

    private var clearLabelButton: some View {
        Button {
            store.clear(for: agentId)
        } label: {
            Label("Clear", systemImage: "trash")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .help("Clear all profile findings")
    }

    private var clearIconButton: some View {
        Button {
            store.clear(for: agentId)
        } label: {
            Image(systemName: "trash")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .help("Clear all profile findings")
    }

    // MARK: - Findings List

    private var findingsList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(filteredFindings) { finding in
                    FindingCard(
                        finding: finding,
                        onAccept: { store.updateFinding(id: finding.id, verificationStatus: .accepted, for: agentId) },
                        onReject: { store.updateFinding(id: finding.id, verificationStatus: .rejected, for: agentId) },
                        onUnsure: { store.updateFinding(id: finding.id, verificationStatus: .unsure, for: agentId) },
                        onDelete: { store.removeFinding(id: finding.id, for: agentId) }
                    )
                }
            }
            .padding(12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("No profile findings yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("The OSINT agent will record discoveries here as cards for you to review.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateSubjectName() {
        var updated = profile
        updated.subjectName = subjectNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setProfile(updated, for: agentId)
        editingSubjectName = false
    }

    // MARK: - Profile Menu

    private var profileMenu: some View {
        Menu {
            Section("Profiles") {
                ForEach(profiles) { p in
                    Button {
                        store.switchProfile(id: p.id, for: agentId)
                    } label: {
                        HStack {
                            let name = p.subjectName?.isEmpty == false ? p.subjectName! : "Untitled profile"
                            Text(name)
                            Spacer()
                            if p.id == profile.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    creatingProfile = true
                } label: {
                    Label("New profile", systemImage: "plus")
                }
            }
            if profiles.count > 1 {
                Section {
                    Button(role: .destructive) {
                        store.deleteProfile(id: profile.id, for: agentId)
                    } label: {
                        Label("Delete active profile", systemImage: "trash")
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down.circle")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .help("Switch, create, or delete profiles")
    }

    private func createProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        store.createProfile(name: name.isEmpty ? nil : name, for: agentId)
        creatingProfile = false
        newProfileName = ""
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: OSINTVerificationStatus
    let color: Color
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(status.displayName)
                .font(.caption)
            Text("\(count)")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.primary.opacity(count == 0 ? 0.5 : 1.0))
    }
}

// MARK: - Finding Card

private struct FindingCard: View {
    let finding: OSINTProfileFinding
    let onAccept: () -> Void
    let onReject: () -> Void
    let onUnsure: () -> Void
    let onDelete: () -> Void

    @Environment(ThemeStore.self) private var theme

    private var statusColor: Color {
        switch finding.verificationStatus {
        case .accepted: return .green
        case .rejected: return .red
        case .unsure: return .orange
        case .unverified: return .yellow
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader
            cardValue
            cardSource
            if let notes = finding.notes, !notes.isEmpty {
                cardNotes(notes)
            }
            cardActions
        }
        .padding(12)
        .background(theme.secondaryBackground.opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(statusColor.opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(8)
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: finding.entityType.icon)
                .foregroundStyle(theme.accent)
            Text(finding.entityType.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            StatusPill(status: finding.verificationStatus, color: statusColor)
        }
    }

    private var cardValue: some View {
        Text(finding.value)
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
    }

    private var cardSource: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.caption2)
            Text(finding.source)
                .font(.caption2)
                .lineLimit(1)
            if let urlString = finding.sourceURL, let url = URL(string: urlString) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                }
            }
            Spacer()
            Text(finding.confidence.rawValue.capitalized)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
    }

    private func cardNotes(_ notes: String) -> some View {
        Text(notes)
            .font(.caption)
            .foregroundStyle(.primary.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(theme.secondaryBackground)
            .cornerRadius(6)
    }

    private var cardActions: some View {
        HStack(spacing: 6) {
            VerificationButton(title: "Accept", icon: "checkmark", color: .green, isActive: finding.verificationStatus == .accepted, action: onAccept)
            VerificationButton(title: "Unsure", icon: "questionmark", color: .orange, isActive: finding.verificationStatus == .unsure, action: onUnsure)
            VerificationButton(title: "Reject", icon: "xmark", color: .red, isActive: finding.verificationStatus == .rejected, action: onReject)
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete finding")
        }
    }
}

// MARK: - Status Pill

private struct StatusPill: View {
    let status: OSINTVerificationStatus
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(status.displayName)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .cornerRadius(4)
    }
}

// MARK: - Verification Button

private struct VerificationButton: View {
    let title: String
    let icon: String
    let color: Color
    let isActive: Bool
    let action: () -> Void

    private var imageName: String {
        isActive ? "\(icon).circle.fill" : "\(icon).circle"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: imageName)
                    .font(.caption)
                Text(title)
                    .font(.caption.weight(isActive ? .semibold : .regular))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isActive ? color.opacity(0.15) : Color.clear)
            .foregroundStyle(isActive ? color : .secondary)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isActive ? color.opacity(0.5) : Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}
