import SwiftUI
import AppKit

struct MessageBubble: View {
    @Environment(ThemeStore.self) private var theme
    let message: Message
    /// True when this is the assistant message currently being streamed. Drives
    /// the live "Thinking…" label and the auto-expand-while-reasoning behavior.
    var isActive: Bool = false
    /// Called when the user taps the revert action on a user message.
    /// Typically used to place the message text back into the input field.
    var onRevert: (() -> Void)? = nil
    /// User's manual override of the reasoning disclosure; `nil` defers to the
    /// automatic expand-while-live / collapse-when-done behavior.
    @State private var userExpanded: Bool?
    /// User's manual override of compaction summary collapse. `nil` defers to
    /// the global default in Settings → Context.
    @State private var userCompactionCollapsed: Bool?
    private var isUser: Bool { message.role == .user }
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 60) }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                
                if let images = message.imageData, !images.isEmpty {
                    VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                            if let nsImage = NSImage(data: data) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 280, maxHeight: 280)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }

                if let reasoning = displayReasoning, !isUser {
                    DisclosureGroup(isExpanded: reasoningExpanded) {
                        Text(reasoning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    } label: {
                        Label(reasoningLabel, systemImage: "brain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                }

                if let steps = message.toolSteps, !steps.isEmpty, !isUser {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(groupedSteps.enumerated()), id: \.offset) { _, group in
                                Text(group.count > 1 ? "\(group.name) \u{00d7}\(group.count)" : group.name)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                    } label: {
                        Label("\(steps.count) tool step\(steps.count == 1 ? "" : "s")",
                              systemImage: "wrench.and.screwdriver")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                }

                if !displayAnswer.isEmpty {
                    if message.isCompaction == true {
                        collapsibleCompactionContent(displayAnswer)
                    } else if isUser {
                        Text(displayAnswer)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(bubbleColor, in: bubbleShape)
                            .foregroundStyle(theme.userBubbleText)
                    } else {
                        RichMarkdownView(text: displayAnswer, isUser: false, onRunCommand: { command in
                            Self.openTerminal(with: command)
                        })
                        .padding(.vertical, 4)
                    }
                }

                messageActions
            }
            .contextMenu {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyableText, forType: .string)
                } label: {
                    Label("Copy message text", systemImage: "doc.on.doc")
                }
            }
            
            if !isUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    /// Text to copy when the user chooses "Copy message text".
    /// For assistant messages this is the cleaned answer; for user messages it is the raw content.
    private var copyableText: String {
        if isUser { return message.content }
        return displayAnswer
    }
    
    /// Reasoning to show: the stream-split `reasoning` field for new messages, or
    /// the legacy in-`content` `<think>` parse for older persisted chats (whose
    /// `reasoning` is nil because they predate stream-time splitting).
    /// Strip any residual channel/thinking tags so the reasoning disclosure
    /// never leaks markers like `<channel>`.
    private var displayReasoning: String? {
        let raw: String
        if let r = message.reasoning { raw = r }
        else if let p = parsed.reasoning { raw = p }
        else { return nil }
        let cleaned = ThinkingTagStripper.strip(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Answer to show: the already-clean `content` for new messages (think split
    /// out at stream time), or the post-`</think>` slice for legacy messages.
    /// A final shared strip pass acts as a safety net for any channel/thinking
    /// tags that slipped through streaming-time stripping.
    private var displayAnswer: String {
        let raw = message.reasoning != nil ? message.content : parsed.answer
        return ThinkingTagStripper.strip(raw)
    }

    /// "Thinking…" while this message is live and still reasoning (no answer yet),
    /// otherwise "Thought for Ns" when a duration was recorded, else "Reasoning".
    private var reasoningLabel: String {
        if isActive && message.content.isEmpty { return "Thinking…" }
        if let s = message.reasoningSeconds, s >= 1 {
            return "Thought for \(Int(s.rounded()))s"
        }
        return "Reasoning"
    }

    /// Auto-expand while this message is the live, still-reasoning one (no answer
    /// yet); auto-collapse once the answer starts or streaming ends. A manual
    /// toggle (`userExpanded`) overrides the automatic behavior.
    private var reasoningExpanded: Binding<Bool> {
        Binding(
            get: { userExpanded ?? (isActive && message.content.isEmpty) },
            set: { userExpanded = $0 }
        )
    }

    /// Splits assistant content into optional chain-of-thought reasoning and the
    /// final answer, based on the model's `<think>…</think>` markers. Handles the
    /// common case where only the closing `</think>` is present (the opening tag
    /// lives in the prompt), and the streaming case where `</think>` hasn't
    /// arrived yet (treat everything as in-progress reasoning, no answer yet).
    private var parsed: (reasoning: String?, answer: String) {
        let content = message.content
        if let close = content.range(of: "</think>") {
            var reasoning = String(content[..<close.lowerBound])
            if let open = reasoning.range(of: "<think>") {
                reasoning = String(reasoning[open.upperBound...])
            }
            reasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = String(content[close.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (reasoning.isEmpty ? nil : reasoning, answer)
        }
        if let open = content.range(of: "<think>") {
            let reasoning = String(content[open.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (reasoning.isEmpty ? nil : reasoning, "")
        }
        return (nil, content)
    }

    /// Opens Terminal.app and executes the given shell command.
    /// Uses AppleScript to create a new Terminal window with the command.
    private static func openTerminal(with command: String) {
        // Escape special characters for AppleScript string literals
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error {
                NSLog("[MessageBubble] Failed to open Terminal: \(error)")
            }
        }
    }

    /// Collapse consecutive identical tool names into name + count for a compact
    /// activity list (e.g. `read_note ×7`).
    private var groupedSteps: [(name: String, count: Int)] {
        guard let steps = message.toolSteps else { return [] }
        var result: [(name: String, count: Int)] = []
        for step in steps {
            if var last = result.last, last.name == step {
                last.count += 1
                result[result.count - 1] = last
            } else {
                result.append((name: step, count: 1))
            }
        }
        return result
    }

    private var roleLabel: String {
        if message.isCompaction == true {
            return "Context"
        }
        switch message.role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .system: return "System"
        }
    }
    
    private var bubbleColor: Color {
        switch message.role {
        case .user: return theme.userBubble
        case .assistant: return Color(.windowBackgroundColor).opacity(0)
        case .system: return .secondary.opacity(0.15)
        }
    }
    
    private var bubbleShape: some Shape {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    /// Visible action bar beneath each message: timestamp/model metadata +
    /// copy + revert for user messages, metadata + copy for assistant messages.
    /// Matches the OpenCode-style affordance set.
    @ViewBuilder
    private var messageActions: some View {
        HStack(spacing: 10) {
            if isUser {
                Spacer()
                metadataText
                actionButton(label: "Copy", systemImage: "doc.on.doc", action: copyMessage)
                if let onRevert {
                    actionButton(label: "Revert", systemImage: "arrow.uturn.left", action: onRevert)
                }
            } else {
                metadataText
                actionButton(label: "Copy", systemImage: "doc.on.doc", action: copyMessage)
                Spacer()
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var metadataText: some View {
        let text = footerMetadata
        if !text.isEmpty {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var footerMetadata: String {
        var parts: [String] = []
        if !isUser, let modelName = message.modelName, !modelName.isEmpty {
            parts.append(modelName)
        }
        if let timestamp = message.timestamp {
            parts.append(Self.timestampFormatter.string(from: timestamp))
        }
        return parts.joined(separator: " · ")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyableText, forType: .string)
    }

    private func actionButton(
        label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(label)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("\(label) message")
    }

    /// Collapsible compaction summary with toggle buttons at both top and bottom.
    private func collapsibleCompactionContent(_ text: String) -> some View {
        let collapsed = userCompactionCollapsed
            ?? SwiftMaestroSettingsStore.loadCollapseCompactionSummaries()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "archivebox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Context compacted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        userCompactionCollapsed?.toggle()
                            ?? (SwiftMaestroSettingsStore.loadCollapseCompactionSummaries()
                                ? (userCompactionCollapsed = false)
                                : (userCompactionCollapsed = true))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        Text(collapsed ? "Show summary" : "Hide summary")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if !collapsed {
                RichMarkdownView(text: text, isUser: false, onRunCommand: { command in
                    Self.openTerminal(with: command)
                })
                .padding(.vertical, 2)

                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            userCompactionCollapsed?.toggle()
                                ?? (SwiftMaestroSettingsStore.loadCollapseCompactionSummaries()
                                    ? (userCompactionCollapsed = false)
                                    : (userCompactionCollapsed = true))
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.up")
                            Text("Hide summary")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: bubbleShape)
    }
}
