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
        // Seed defaults on first launch (no persisted rules yet)
        if policy.alwaysAsk.isEmpty && policy.neverAllow.isEmpty && policy.alwaysAllow.isEmpty {
            seedDefaultRules()
        }
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
        // Load persisted policy rules
        if let data = defaults.data(forKey: "settings.shell.policy"),
           let decoded = try? JSONDecoder().decode(ShellPolicy.self, from: data) {
            policy = decoded
        }
    }

    /// Save settings to UserDefaults.
    public func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: "settings.shell.enabled")
        defaults.set(defaultTimeout, forKey: "settings.shell.defaultTimeout")
        defaults.set(outputCap, forKey: "settings.shell.outputCap")
        defaults.set(loginShell, forKey: "settings.shell.loginShell")
        defaults.set(maxConcurrent, forKey: "settings.shell.maxConcurrent")
        if let data = try? JSONEncoder().encode(policy) {
            defaults.set(data, forKey: "settings.shell.policy")
        }
    }

    /// Reset all settings to defaults (clears policy lists).
    public func resetToDefaults() {
        enabled = false
        defaultTimeout = 30
        outputCap = 65536
        loginShell = true
        maxConcurrent = 2
        policy = ShellPolicy()
        seedDefaultRules()
        save()
    }

    // MARK: - Default Safety Rules

    /// Seed default always-ask rules for dangerous commands on first launch.
    private func seedDefaultRules() {
        // ── Destructive filesystem ──────────────────────────────
        let destructiveFS: [ShellPolicyRule] = [
            .literal("rm "),
            .literal("rm -rf /"),
            .literal("rm -r /"),
            .regex("(?i)rm\\s+(-[a-zA-Z]*r[a-zA-Z]*\\s+)?/(\\s|$)"),
            .literal("rm -rf ~"),
            .literal("rmdir"),
            .regex("(?i)find\\s+.*\\s+-delete"),
            .regex("(?i)find\\s+.*\\s+-exec\\s+rm"),
            .literal("chmod -R 777"),
            .literal("chown -R"),
            .literal("mkfs."),
            .regex("(?i)\\bsudo\\s+rm\\b"),
        ]
        policy.alwaysAsk.append(contentsOf: destructiveFS)

        // ── Network / system ───────────────────────────────────
        let networkSystem: [ShellPolicyRule] = [
            .regex("(?i)\\bcurl\\b.*\\|\\s*(bash|sh)"),
            .regex("(?i)\\bwget\\b.*\\|\\s*(bash|sh)"),
            .regex("(?i)\\bsudo\\b"),
            .regex("(?i)\\bsu\\s"),
            .literal("launchctl unload"),
            .literal("launchctl load /Library"),
            .regex("(?i)\\bnetworksetup\\b"),
            .regex("(?i)\\bifconfig\\b"),
            .regex("(?i)\\bpfctl\\b"),
            .regex("(?i)\\bcsrutil\\b"),
        ]
        policy.alwaysAsk.append(contentsOf: networkSystem)

        // ── Package management / system modification ────────────
        let pkgSystem: [ShellPolicyRule] = [
            .regex("(?i)\\bbrew\\s+uninstall"),
            .regex("(?i)\\bbrew\\s+remove"),
            .regex("(?i)\\bpip\\s+uninstall"),
            .regex("(?i)\\bpip\\s+install.*--force"),
            .regex("(?i)\\bnpm\\s+uninstall\\s+-g"),
            .regex("(?i)\\bkill\\s+-9\\s+1"),
            .regex("(?i)\\bkillall\\b"),
            .regex("(?i)\\bpkill\\b"),
        ]
        policy.alwaysAsk.append(contentsOf: pkgSystem)

        // ── Git destructive operations ─────────────────────────
        let gitDestructive: [ShellPolicyRule] = [
            .literal("git push --force"),
            .literal("git push -f"),
            .literal("git reset --hard"),
            .literal("git clean -fd"),
            .literal("git checkout -- ."),
            .regex("(?i)git\\s+branch\\s+-[dD]\\s"),
            .regex("(?i)git\\s+push\\s+.*\\s+--force"),
        ]
        policy.alwaysAsk.append(contentsOf: gitDestructive)

        // ── Database destructive ───────────────────────────────
        let dbDestructive: [ShellPolicyRule] = [
            .regex("(?i)\\bdrop\\s+database\\b"),
            .regex("(?i)\\bdrop\\s+table\\b"),
            .regex("(?i)\\bdelete\\s+from\\b"),
            .regex("(?i)\\btruncate\\s+table\\b"),
            .regex("(?i)\\bupdate\\b.*\\bset\\b"),
        ]
        policy.alwaysAsk.append(contentsOf: dbDestructive)

        // ── Always-allow safe read-only commands ────────────────
        let safeReadOnly: [ShellPolicyRule] = [
            .literal("ls"),
            .literal("pwd"),
            .literal("echo"),
            .literal("cat"),
            .literal("head"),
            .literal("tail"),
            .literal("wc"),
            .literal("grep"),
            .literal("find"),
            .literal("which"),
            .literal("whoami"),
            .literal("date"),
            .literal("df"),
            .literal("du"),
            .literal("file"),
            .literal("stat"),
            .literal("uname"),
            .literal("env"),
            .literal("printenv"),
            .literal("git status"),
            .literal("git log"),
            .literal("git diff"),
            .literal("git branch"),
            .literal("git remote"),
            .literal("git show"),
            .literal("git tag"),
        ]
        policy.alwaysAllow.append(contentsOf: safeReadOnly)

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
