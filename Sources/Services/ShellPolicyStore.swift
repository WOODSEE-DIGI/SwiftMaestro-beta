import Foundation

// MARK: - Shell Policy Store

/// Shared policy store for shell command classification.
@MainActor
public final class ShellPolicyStore: ObservableObject {

    public static let shared = ShellPolicyStore()

    private static let alwaysAllowKey = "settings.shell.alwaysAllow"
    private static let alwaysAskKey = "settings.shell.alwaysAsk"
    private static let neverAllowKey = "settings.shell.neverAllow"

    /// Whether the shell tool is enabled.
    @Published public var enabled: Bool = false

    // MARK: - Execution Settings
    @Published public var defaultTimeout: Int = 30 // seconds
    @Published public var outputCap: Int = 65536 // bytes
    @Published public var loginShell: Bool = true
    @Published public var maxConcurrent: Int = 2

    /// Policy rules for command classification.
    @Published public var policy: ShellPolicy

    /// Initialize with default policies and load persisted settings.
    public init() {
        self.policy = ShellPolicy()
        load()
    }

    /// Load settings from UserDefaults.
    public func load() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: "settings.shell.enabled")
        defaultTimeout = defaults.integer(forKey: "settings.shell.defaultTimeout")
        if defaultTimeout == 0 { defaultTimeout = 30 }
        outputCap = defaults.integer(forKey: "settings.shell.outputCap")
        if outputCap == 0 { outputCap = 65536 }
        loginShell = defaults.object(forKey: "settings.shell.loginShell") as? Bool ?? true
        maxConcurrent = defaults.integer(forKey: "settings.shell.maxConcurrent")
        if maxConcurrent == 0 { maxConcurrent = 2 }
    }

    /// Save settings to UserDefaults.
    public func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: "settings.shell.enabled")
        defaults.set(defaultTimeout, forKey: "settings.shell.defaultTimeout")
        defaults.set(outputCap, forKey: "settings.shell.outputCap")
        defaults.set(loginShell, forKey: "settings.shell.loginShell")
        defaults.set(maxConcurrent, forKey: "settings.shell.maxConcurrent")
    }

    /// Reset all settings to defaults (clears policy lists).
    public func resetToDefaults() {
        enabled = false
        defaultTimeout = 30
        outputCap = 65536
        loginShell = true
        maxConcurrent = 2
        policy = ShellPolicy()
        save()
    }

    /// Classify a command against the policy.
    public func classify(_ command: String) -> ShellClassification {
        return policy.classify(command)
    }

    /// Add a rule to the specified list.
    public func addRule(_ rule: ShellPolicyRule, to list: PolicyListType) {
        switch list {
        case .alwaysAllow:
            policy.alwaysAllow.append(rule)
        case .alwaysAsk:
            policy.alwaysAsk.append(rule)
        case .neverAllow:
            policy.neverAllow.append(rule)
        }
    }

    /// Remove a rule from the specified list.
    public func removeRule(at index: Int, from list: PolicyListType) {
        switch list {
        case .alwaysAllow:
            if policy.alwaysAllow.indices.contains(index) {
                policy.alwaysAllow.remove(at: index)
            }
        case .alwaysAsk:
            if policy.alwaysAsk.indices.contains(index) {
                policy.alwaysAsk.remove(at: index)
            }
        case .neverAllow:
            if policy.neverAllow.indices.contains(index) {
                policy.neverAllow.remove(at: index)
            }
        }
    }
}

/// Type of policy list for add/remove operations.
public enum PolicyListType {
    case alwaysAllow
    case alwaysAsk
    case neverAllow
}
