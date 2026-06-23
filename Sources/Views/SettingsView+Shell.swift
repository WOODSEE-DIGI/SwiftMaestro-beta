import SwiftUI

// MARK: - Shell Settings Tab

struct ShellSettingsTab: View {
    @ObservedObject private var policyStore = ShellPolicyStore.shared
    @State private var newAlwaysAllow: String = ""
    @State private var newAlwaysAsk: String = ""
    @State private var newNeverAllow: String = ""
    @State private var saveMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Master toggle
                GroupBox("Shell Tool") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable shell_exec tool", isOn: $policyStore.enabled)
                            .toggleStyle(.switch)
                        Text("When enabled, the agent can execute shell commands with safety controls.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                // Always Allow list
                GroupBox("Always Allow (no approval needed)") {
                    policyListView(
                        title: "Always Allow",
                        items: $policyStore.policy.alwaysAllow,
                        newItem: $newAlwaysAllow,
                        color: .green,
                        icon: "checkmark.circle"
                    )
                }

                // Always Ask list
                GroupBox("Always Ask (requires approval)") {
                    policyListView(
                        title: "Always Ask",
                        items: $policyStore.policy.alwaysAsk,
                        newItem: $newAlwaysAsk,
                        color: .orange,
                        icon: "questionmark.circle"
                    )
                }

                // Never Allow list
                GroupBox("Never Allow (hard deny)") {
                    policyListView(
                        title: "Never Allow",
                        items: $policyStore.policy.neverAllow,
                        newItem: $newNeverAllow,
                        color: .red,
                        icon: "xmark.circle"
                    )
                }

                // Execution settings
                GroupBox("Execution Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        // Default timeout
                        HStack {
                            Text("Default timeout: \(policyStore.defaultTimeout)s")
                                .font(.body)
                            Spacer()
                        }
                        Slider(value: Binding(
                            get: { Double(policyStore.defaultTimeout) },
                            set: { policyStore.defaultTimeout = Int($0) }
                        ), in: 5...300, step: 5)

                        // Output cap
                        HStack {
                            Text("Output cap: \(formatBytes(policyStore.outputCap))")
                                .font(.body)
                            Spacer()
                        }
                        Slider(value: Binding(
                            get: { Double(policyStore.outputCap) },
                            set: { policyStore.outputCap = Int($0) }
                        ), in: 8192...262144, step: 8192)

                        // Login shell toggle
                        Toggle("Use login shell (zsh -lic)", isOn: $policyStore.loginShell)
                            .toggleStyle(.switch)

                        // Max concurrent
                        HStack {
                            Text("Max concurrent calls: \(policyStore.maxConcurrent)")
                                .font(.body)
                            Spacer()
                            Stepper("", value: $policyStore.maxConcurrent, in: 1...10)
                                .labelsHidden()
                        }
                    }
                    .padding(8)
                }

                // Actions
                HStack {
                    Button("Reset to Defaults") {
                        policyStore.resetToDefaults()
                        saveMessage = "Reset to defaults"
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Save") {
                        policyStore.save()
                        saveMessage = "Settings saved"
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let message = saveMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding()
        }
        .onChange(of: policyStore.enabled) { _, _ in policyStore.save() }
        .onChange(of: policyStore.defaultTimeout) { _, _ in policyStore.save() }
        .onChange(of: policyStore.outputCap) { _, _ in policyStore.save() }
        .onChange(of: policyStore.loginShell) { _, _ in policyStore.save() }
        .onChange(of: policyStore.maxConcurrent) { _, _ in policyStore.save() }
    }

    @ViewBuilder
    private func policyListView(
        title: String,
        items: Binding<[ShellPolicyRule]>,
        newItem: Binding<String>,
        color: Color,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Add new item
            HStack(spacing: 8) {
                TextField("Add \(title.lowercased())...", text: newItem)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addRule(newItem, to: items, color: color)
                    }

                Button("Add") {
                    addRule(newItem, to: items, color: color)
                }
                .disabled(newItem.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // List of rules
            if items.wrappedValue.isEmpty {
                Text("No \(title.lowercased()) rules")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.wrappedValue.enumerated()), id: \.offset) { index, rule in
                    HStack {
                        Image(systemName: icon)
                            .foregroundStyle(color)
                        Text(ruleDescription(rule))
                            .font(.caption)
                        Spacer()
                        Button(role: .destructive) {
                            removeRule(rule, from: items)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(8)
    }

    private func addRule(_ binding: Binding<String>, to items: Binding<[ShellPolicyRule]>, color: Color) {
        let trimmed = binding.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let rule: ShellPolicyRule
        if trimmed.contains("*") {
            // Convert * to regex
            let pattern = trimmed.replacingOccurrences(of: "*", with: ".*")
            rule = .regex(pattern)
        } else {
            rule = .literal(trimmed)
        }

        items.wrappedValue.append(rule)
        binding.wrappedValue = ""
        policyStore.save()
    }

    private func removeRule(_ rule: ShellPolicyRule, from items: Binding<[ShellPolicyRule]>) {
        items.wrappedValue.removeAll { $0 == rule }
        policyStore.save()
    }

    private func ruleDescription(_ rule: ShellPolicyRule) -> String {
        switch rule {
        case .literal(let prefix):
            return prefix
        case .regex(let pattern):
            return "/\(pattern)/"
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return "\(bytes / (1024 * 1024)) MB"
        } else if bytes >= 1024 {
            return "\(bytes / 1024) KB"
        }
        return "\(bytes) B"
    }
}

// MARK: - Preview

#Preview {
    ShellSettingsTab()
}
