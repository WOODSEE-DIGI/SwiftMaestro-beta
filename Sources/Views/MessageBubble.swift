import SwiftUI
import AppKit

struct MessageBubble: View {
    let message: Message
    /// True when this is the assistant message currently being streamed. Drives
    /// the live "Thinking…" label and the auto-expand-while-reasoning behavior.
    var isActive: Bool = false
    /// User's manual override of the reasoning disclosure; `nil` defers to the
    /// automatic expand-while-live / collapse-when-done behavior.
    @State private var userExpanded: Bool?
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
                    Text(displayAnswer)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubbleColor, in: bubbleShape)
                        .foregroundStyle(isUser ? Color.white : Color.primary)
                }
            }
            
            if !isUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
    
    /// Reasoning to show: the stream-split `reasoning` field for new messages, or
    /// the legacy in-`content` `<think>` parse for older persisted chats (whose
    /// `reasoning` is nil because they predate stream-time splitting).
    private var displayReasoning: String? {
        if let r = message.reasoning { return r.isEmpty ? nil : r }
        return parsed.reasoning
    }

    /// Answer to show: the already-clean `content` for new messages (think split
    /// out at stream time), or the post-`</think>` slice for legacy messages.
    private var displayAnswer: String {
        if message.reasoning != nil { return message.content }
        return parsed.answer
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
        switch message.role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .system: return "System"
        }
    }
    
    private var bubbleColor: Color {
        switch message.role {
        case .user: return .accentColor
        case .assistant: return Color(.windowBackgroundColor).opacity(0)
        case .system: return .secondary.opacity(0.15)
        }
    }
    
    private var bubbleShape: some Shape {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }
}
