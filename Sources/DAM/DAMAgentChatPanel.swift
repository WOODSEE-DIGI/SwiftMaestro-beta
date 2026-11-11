import SwiftUI

/// An embedded mini-chat for MaestroDAM's bottom-left sidebar.
///
/// Unlike the previous compact prompt bar, this view keeps the conversation
/// inline in the sidebar. It reuses the dedicated MaestroDAM agent's cached
/// `ChatViewModel`, so the history survives switching workspaces and is the
/// same conversation the user sees if they later open the full agent window.
struct DAMAgentChatPanel: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(ModelCatalog.self) private var catalog

    let viewModel: DAMViewModel
    var panelHeight: Binding<CGFloat>?

    var body: some View {
        _DAMAgentChatPanelInner(viewModel: viewModel, workspace: workspace, externalHeight: panelHeight)
    }
}

/// Lightweight observable state that creates the cached `ChatViewModel` lazily
/// after the view has finished its initial layout. Creating the view model in
/// `init` blocked the main thread during workspace switches; loading it from
/// `.task` keeps the switch responsive.
@MainActor
private final class DAMAgentChatPanelState: ObservableObject {
    @Published var chatVM: ChatViewModel?

    func load(workspace: WorkspaceStore) {
        guard chatVM == nil else { return }
        let agent = DAMAgentHelper.ensureAgent(in: workspace)
        let projectName = workspace.projectName(for: agent)
        chatVM = ChatViewModelCache.shared.viewModel(
            for: agent,
            projectName: projectName
        )
    }
}

@MainActor
private struct _DAMAgentChatPanelInner: View {
    @Environment(MLXInferenceEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @Environment(ThemeStore.self) private var theme
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.openWindow) private var openWindow

    @StateObject private var state = DAMAgentChatPanelState()
    @FocusState private var isInputFocused: Bool
    @State private var draft = ""
    @State private var scrollToBottomTrigger = UUID()
    @State private var internalHeight: CGFloat = Constants.defaultPanelHeight

    let viewModel: DAMViewModel
    let externalHeight: Binding<CGFloat>?

    init(viewModel: DAMViewModel, workspace: WorkspaceStore, externalHeight: Binding<CGFloat>? = nil) {
        self.viewModel = viewModel
        self.externalHeight = externalHeight
    }

    private var height: CGFloat {
        get { externalHeight?.wrappedValue ?? internalHeight }
        nonmutating set {
            externalHeight?.wrappedValue = newValue
            internalHeight = newValue
        }
    }

    private var heightBinding: Binding<CGFloat> {
        Binding(
            get: { height },
            set: { height = $0 }
        )
    }

    var body: some View {
        Group {
            if let chatVM = state.chatVM {
                _DAMAgentChatPanelContent(
                    chatVM: chatVM,
                    viewModel: viewModel,
                    height: heightBinding
                )
            } else {
                loadingPlaceholder
            }
        }
        .onAppear {
            let saved = UserDefaults.standard.double(forKey: Constants.heightKey)
            if saved > 0 {
                height = clampHeight(CGFloat(saved))
            }
            state.load(workspace: workspace)
        }
    }

    private func clampHeight(_ value: CGFloat) -> CGFloat {
        min(max(value, Constants.minPanelHeight), Constants.maxPanelHeight)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text("Ask Maestro")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            Spacer()
            ProgressView()
                .controlSize(.small)
            Spacer()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .frame(height: height)
    }

    private enum Constants {
        static let defaultPanelHeight: CGFloat = 420
        static let minPanelHeight: CGFloat = 120
        static let maxPanelHeight: CGFloat = 600
        static let heightKey = "DAMAgentChatPanel.height.v2"
    }
}

@MainActor
private struct _DAMAgentChatPanelContent: View {
    @Environment(MLXInferenceEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @Environment(ThemeStore.self) private var theme
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.openWindow) private var openWindow

    @ObservedObject var chatVM: ChatViewModel
    let viewModel: DAMViewModel
    @Binding var height: CGFloat

    @FocusState private var isInputFocused: Bool
    @State private var draft = ""
    @State private var scrollToBottomTrigger = UUID()

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            header
            Divider()
            messageList
            Divider()
            inputBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .frame(height: height)
        .task(id: viewModel.selection) {
            // Ensure the dedicated agent still has the DAM tool category
            // enabled after workspace changes.
            _ = DAMAgentHelper.ensureAgent(in: workspace)
        }
        .onChange(of: height) { _, newHeight in
            UserDefaults.standard.set(Double(newHeight), forKey: Constants.heightKey)
        }
    }

    private func clampHeight(_ value: CGFloat) -> CGFloat {
        min(max(value, Constants.minPanelHeight), Constants.maxPanelHeight)
    }

    private var resizeHandle: some View {
        DAMSidebarDivider { delta in
            // Dragging up produces a negative delta; increase height to expand upward.
            height = clampHeight(height - delta)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text("Ask Maestro")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Menu {
                Button {
                    chatVM.clearChat()
                } label: {
                    Label("Clear conversation", systemImage: "trash")
                }
                Button {
                    let agent = DAMAgentHelper.ensureAgent(in: workspace)
                    openWindow(id: "agent-chat-window", value: AgentChatWindowID(agentID: agent.id))
                } label: {
                    Label("Open in full window", systemImage: "arrow.up.forward")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(displayMessages) { message in
                        _DAMMiniMessageBubble(
                            message: message,
                            isActive: chatVM.isStreaming && message.id == chatVM.messages.last?.id
                        )
                        .id(message.id)
                    }
                    if chatVM.isStreaming, chatVM.messages.last?.role == .assistant,
                       chatVM.messages.last?.content.isEmpty ?? false {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(loadingText)
                                .font(.caption2)
                                .foregroundStyle(theme.chatSecondaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .id("loading-indicator")
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: chatVM.messages.count) {
                scrollToLatest(proxy: proxy)
            }
            .onChange(of: chatVM.messages.last?.content) {
                scrollToLatest(proxy: proxy)
            }
            .onChange(of: scrollToBottomTrigger) {
                scrollToLatest(proxy: proxy)
            }
            .onAppear {
                scrollToLatest(proxy: proxy)
            }
        }
    }

    private var displayMessages: [Message] {
        chatVM.messages.filter { $0.role != .system }
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        if let last = chatVM.messages.last {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var loadingText: String {
        switch engine.state {
        case .loading(let name): return "Loading \(name)…"
        case .generating:        return "Thinking…"
        default:                 return "Working…"
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Rename, OCR, cull…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .font(.caption)
                .focused($isInputFocused)
                .onSubmit { submit() }

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(canSend ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatVM.isStreaming
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chatVM.isStreaming else { return }

        let context = DAMAgentHelper.contextPrompt(from: viewModel)
        let fullPrompt = context + "User request: " + trimmed
        let model = catalog.effectiveModel(for: chatVM.agent) ?? catalog.selectedModel
        draft = ""
        chatVM.send(engine: engine, catalog: catalog, model: model, promptOverride: fullPrompt)
    }

    private enum Constants {
        static let defaultPanelHeight: CGFloat = 420
        static let minPanelHeight: CGFloat = 120
        static let maxPanelHeight: CGFloat = 600
        static let heightKey = "DAMAgentChatPanel.height.v2"
    }
}

// MARK: - Compact message bubble

@MainActor
private struct _DAMMiniMessageBubble: View {
    @Environment(ThemeStore.self) private var theme
    let message: Message
    var isActive: Bool = false

    private var isUser: Bool { message.role == .user }

    /// Strips the injected DAM context prefix so the user only sees their actual
    /// question in the sidebar conversation.
    private var displayText: String {
        let raw = message.reasoning != nil ? message.content : _stripLegacyThinking(message.content)
        let stripped = ThinkingTagStripper.strip(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if isUser, let marker = stripped.range(of: "User request: ") {
            return String(stripped[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stripped
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 24) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(theme.chatSecondaryText)
                    .padding(.horizontal, 4)

                if !displayText.isEmpty {
                    if isUser {
                        Text(displayText)
                            .font(.caption)
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(bubbleColor, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(theme.userBubbleText)
                    } else {
                        RichMarkdownView(
                            text: displayText,
                            isUser: false,
                            textColor: theme.chatText,
                            font: .caption,
                            onRunCommand: { command in
                                _DAMMiniMessageBubble.openTerminal(with: command)
                            }
                        )
                        .padding(.vertical, 2)
                    }
                }

                if isActive && displayText.isEmpty {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Thinking…")
                            .font(.caption2)
                            .foregroundStyle(theme.chatSecondaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }

            if !isUser { Spacer(minLength: 24) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(displayText, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    private var roleLabel: String {
        if isUser { return "You" }
        return message.modelName ?? "Maestro"
    }

    private var bubbleColor: Color {
        theme.userBubble
    }

    private static func openTerminal(with command: String) {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\""
        guard let appleScript = NSAppleScript(source: script) else { return }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        if let error = errorInfo {
            NSLog("[_DAMMiniMessageBubble] Failed to open Terminal: \(error)")
        }
    }
}

/// Strips `<think>…</think>` markers for the rare legacy message that was not
/// split at stream time. Returns the post-`</think>` slice when present.
private func _stripLegacyThinking(_ content: String) -> String {
    guard let close = content.range(of: "</think>") else { return content }
    return String(content[close.upperBound...])
}

#if DEBUG
#Preview {
    @Previewable @State var workspace = WorkspaceStore()
    DAMAgentChatPanel(viewModel: DAMViewModel())
        .environment(MLXInferenceEngine())
        .environment(ModelCatalog())
        .environment(workspace)
        .environment(ThemeStore())
        .frame(width: 220)
}
#endif
