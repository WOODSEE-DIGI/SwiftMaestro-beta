import SwiftUI

struct MessageBubble: View {
    let message: Message
    private var isUser: Bool { message.role == .user }
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 60) }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                
                if let reasoning = parsed.reasoning, !isUser {
                    DisclosureGroup {
                        Text(reasoning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    } label: {
                        Label("Reasoning", systemImage: "brain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                }

                if !parsed.answer.isEmpty {
                    Text(parsed.answer)
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
