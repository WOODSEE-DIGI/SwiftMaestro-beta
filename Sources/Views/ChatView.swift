import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(MLXInferenceEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @Environment(TodoStore.self) private var todoStore
    @Environment(PlanStore.self) private var planStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(AgentMessageStore.self) private var messageStore
    @Environment(ThemeStore.self) private var theme
    @Environment(WhisperKitService.self) private var whisper
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var vm: ChatViewModel
    @State private var layoutState = PanelLayoutState.shared
    @State private var showingPlans = false
    @State private var showingMessages = false
    @State private var showingClearChatConfirm = false
    // Markdown export driven from the Plans panel's context menu.
    @State private var exporting = false
    @State private var exportDocument: MarkdownDocument?
    @State private var exportName = "Plan"
    /// Monitor for Cmd+V image paste before the TextField consumes it.
    @State private var pasteMonitor: Any?
    /// Optional override for the window/tab title. Used when this chat is shown
    /// in a detached agent window so the title bar shows the agent name.
    let title: String?

    init(vm: ChatViewModel, title: String? = nil) {
        _vm = ObservedObject(wrappedValue: vm)
        self.title = title
    }

    var body: some View {
        ResizablePanelHost(panes: resizablePanes)
        .navigationTitle(title ?? "Chat")
        .task(id: vm.agent.id) {
            // Prime the per-agent todo + plan lists from disk (cache-fill) outside
            // of body evaluation so persisted items show after relaunch. Project
            // plan scopes are primed too so the top-bar Plans count is accurate.
            _ = todoStore.todos(for: vm.agent.id)
            _ = planStore.plans(in: .agent(vm.agent.id))
            for project in planScopeProjects { _ = planStore.plans(in: .project(project)) }
            _ = messageStore.inbox(for: vm.agent.id)
        }
        .onAppear {
            // Intercept Cmd+V before the TextField consumes it, so image pastes
            // go to pendingImages instead of being inserted as text.
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 9 && event.modifierFlags.contains(.command) {
                    let pb = NSPasteboard.general
                    // Check for file URLs first
                    if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
                        .urlReadingFileURLsOnly: true
                    ]) as? [URL] {
                        let imageURLs = urls.filter { url in
                            let ext = url.pathExtension.lowercased()
                            return ["png","jpg","jpeg","gif","bmp","tiff","webp","heic"].contains(ext)
                        }
                        if !imageURLs.isEmpty {
                            for url in imageURLs {
                                if let data = ChatView.pngData(fromFileURL: url) {
                                    vm.pendingImages.append(data)
                                    vm.pendingImagePaths.append(url.path)
                                }
                            }
                            return nil // consume the event
                        }
                    }
                    // Check for image data (e.g. screenshot paste)
                    if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
                       !images.isEmpty {
                        for img in images {
                            if let data = ChatView.pngData(from: img) {
                                vm.pendingImages.append(data)
                            }
                        }
                        return nil
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = pasteMonitor {
                NSEvent.removeMonitor(monitor)
                pasteMonitor = nil
            }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleProviders(providers)
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            handleProviders(providers)
        }
        .onChange(of: whisper.pendingTranscription) { _, newValue in
            if let text = newValue, !text.isEmpty {
                vm.inputText = text
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    openWindow(id: "agent-chat-window", value: AgentChatWindowID(agentID: vm.agent.id))
                } label: {
                    Label("Open in Window", systemImage: "macwindow.on.rectangle")
                }
                .help("Open this agent’s chat in a floating window")
            }
            ToolbarItem {
                Button { showingMessages = true } label: {
                    let unread = messageStore.unreadCount(for: vm.agent.id)
                    Image(systemName: unread > 0 ? "tray.full.fill" : "tray")
                        .overlay(alignment: .topTrailing) {
                            if unread > 0 {
                                Text("\(unread)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3).padding(.vertical, 1)
                                    .background(Capsule().fill(.red))
                                    .offset(x: 8, y: -7)
                            }
                        }
                }
                .help("Inbox")
            }
            ToolbarItem {
                Button(role: .destructive) { showingClearChatConfirm = true } label: {
                    Label("Clear Chat", systemImage: "trash")
                }
                .help("Clear this agent's conversation and start fresh")
            }
        }
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $showingClearChatConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Chat", role: .destructive) { vm.clearChat() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(vm.agent.name)'s chat history. Project memory, plans, and tasks are untouched.")
        }
        .sheet(isPresented: $showingPlans) {
            PlansSheet(
                agentId: vm.agent.id,
                projects: planScopeProjects,
                defaultProjectName: vm.agent.kind == .navigator ? nil : vm.projectName
            )
            .environment(planStore)
        }
        .sheet(isPresented: $showingMessages) {
            MessagesSheet(agentId: vm.agent.id, agentName: vm.agent.name)
                .environment(messageStore)
        }
    }

    /// Project names selectable as plan scopes in the Plans sheet: the Navigator
    /// can browse every project's shared plans; a project agent sees its own.
    private var planScopeProjects: [String] {
        if vm.agent.kind == .navigator { return workspace.projects.map(\.name) }
        return vm.projectName.map { [$0] } ?? []
    }

    /// Plans visible to this agent (personal + its project scopes), paired with
    /// their scope so each card can be opened/exported/deleted. Read from the
    /// primed cache so it doesn't mutate store state during body evaluation.
    private var visiblePlans: [(scope: PlanScope, plan: Plan)] {
        var out: [(PlanScope, Plan)] = []
        let personal = PlanScope.agent(vm.agent.id)
        out += (planStore.plansByScope[personal.key] ?? []).map { (personal, $0) }
        for project in planScopeProjects {
            let scope = PlanScope.project(project)
            out += (planStore.plansByScope[scope.key] ?? []).map { (scope, $0) }
        }
        return out
    }

    /// Always-visible base-directory control at the top-left of the chat. Opens a
    /// folder picker; the choice is injected into the agent's prompt + shell cwd.
    private var workingDirBar: some View {
        HStack(spacing: 6) {
            Button { pickWorkingDirectory() } label: {
                Image(systemName: "folder")
                Text(workingDirLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help(vm.workingDirectory ?? "Choose the agent's working directory")
            if vm.workingDirectory != nil {
                Button { vm.setWorkingDirectory(nil) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Clear working directory")
            }
            Spacer()
            // Per-agent model override. "" picks the global default; any other
            // tag pins this agent (and its delegations) to that model.
            Image(systemName: "cpu").foregroundStyle(.secondary)
            Text("This agent").foregroundStyle(.secondary)
            Picker("", selection: agentModelBinding) {
                Text(defaultAgentModelLabel).tag("")
                ForEach(catalog.models) { m in
                    Text(m.displayName).tag(m.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            .help("Model used by THIS agent. “Default” follows the toolbar’s Default picker.")
            if let effective = ChatViewModel.effectiveDelegateModelNames[vm.agent.id.uuidString] {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text("Running on \(effective)")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                .help("This delegation is actually running on \(effective) because the configured model was promoted or overridden.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var workingDirLabel: String {
        guard let wd = vm.workingDirectory else { return "Set working directory…" }
        return (wd as NSString).lastPathComponent
    }

    /// Per-agent tool category toggles. Each toggle shows an icon and a small
    /// text label so the user can tell what each tool group is without hovering.
    ///
    /// The default set for the agent kind is always shown; additional categories
    /// can be added with the "+" menu and will appear while they are enabled.
    ///
    /// The picker is rendered with a wrapping flow layout so it stays usable
    /// when the chat panel is narrow (e.g. half-screen or stacked panels).
    private var toolCategoryPicker: some View {
        FlowLayout(spacing: 8, rowSpacing: 6) {
            ForEach(toolbarCategories) { category in
                let active = enabledCategories.contains(category)
                Button {
                    toggleCategory(category)
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: category.icon)
                            .symbolVariant(active ? .fill : .none)
                            .foregroundStyle(active ? theme.accent : .secondary)
                            .frame(height: 14)
                        Text(category.displayName)
                            .font(.system(size: 8, weight: active ? .semibold : .medium))
                            .foregroundStyle(active ? theme.accent : .secondary)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 34)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(active ? theme.accent.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(category.displayName): \(active ? "enabled" : "disabled")")
            }

            if !addableCategories.isEmpty {
                Menu {
                    ForEach(addableCategories) { category in
                        Button {
                            enableCategory(category)
                        } label: {
                            Label(category.displayName, systemImage: category.icon)
                        }
                    }
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: "plus")
                            .foregroundStyle(.secondary)
                            .frame(height: 14)
                        Text("Add")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 34)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .help("Add more tool categories")
            }

            Divider().frame(width: 1, height: 18)

            Button {
                workspace.setCompactToolMode(!compactToolMode, for: vm.agent.id)
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .symbolVariant(compactToolMode ? .fill : .none)
                        .foregroundStyle(compactToolMode ? theme.accent : .secondary)
                        .frame(height: 14)
                    Text("Compact")
                        .font(.system(size: 8, weight: compactToolMode ? .semibold : .medium))
                        .foregroundStyle(compactToolMode ? theme.accent : .secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 34)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(compactToolMode ? theme.accent.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                "Compact Tool Mode: \(compactToolMode ? "on" : "off"). When on, "
                + "the enabled categories above (except Workspace/Memory/Rules/Time) are "
                + "hidden from the prompt and reachable instead via search_tools/call_tool "
                + "— saves prompt tokens once several categories are enabled."
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    /// Whether Compact Tool Mode is on for this agent.
    private var compactToolMode: Bool {
        workspace.compactToolMode(for: vm.agent.id)
    }

    /// Categories always shown for this agent kind.
    private var defaultVisibleCategories: [ToolCategory] {
        ToolCategory.visible(for: vm.agent.kind)
    }

    /// Categories rendered in the toolbar: the default visible set plus any
    /// additional categories the user has enabled.
    private var toolbarCategories: [ToolCategory] {
        let defaults = Set(defaultVisibleCategories)
        let extras = enabledCategories.subtracting(defaults)
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        return defaultVisibleCategories + extras
    }

    /// Additional categories the user can add (not in the default visible set).
    private var addableCategories: [ToolCategory] {
        let defaults = Set(defaultVisibleCategories)
        return ToolCategory.allCases
            .filter { !defaults.contains($0) }
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    /// Current enabled categories for this agent.
    private var enabledCategories: Set<ToolCategory> {
        workspace.enabledToolCategories(for: vm.agent.id)
    }

    private func toggleCategory(_ category: ToolCategory) {
        var updated = enabledCategories
        if updated.contains(category) {
            updated.remove(category)
        } else {
            updated.insert(category)
        }
        workspace.setEnabledToolCategories(updated, for: vm.agent.id)
    }

    private func enableCategory(_ category: ToolCategory) {
        var updated = enabledCategories
        updated.insert(category)
        workspace.setEnabledToolCategories(updated, for: vm.agent.id)
    }

    /// Live per-agent model override binding ("" = use the global default),
    /// read from and written back to the workspace record.
    private var agentModelBinding: Binding<String> {
        Binding(
            get: { workspace.agent(id: vm.agent.id)?.modelID ?? "" },
            set: { workspace.setModel($0.isEmpty ? nil : $0, for: vm.agent.id) }
        )
    }

    /// The model this agent will run, resolved from the LIVE workspace record
    /// (not the stale snapshot captured at view-model init).
    private var effectiveModelForAgent: MaestroModel? {
        let live = workspace.agent(id: vm.agent.id) ?? vm.agent
        return catalog.effectiveModel(for: live)
    }

    /// Label for the "use global default" option in the per-agent model picker,
    /// showing the currently selected default model name for clarity.
    private var defaultAgentModelLabel: String {
        if let defaultModel = catalog.selectedModel {
            return "Default — \(defaultModel.displayName)"
        }
        return "Default (global)"
    }

    /// This agent's plans, docked as a left-side panel that mirrors the Tasks
    /// panel. Each plan is an accent card; tapping (or "Open in Window") opens it
    /// in a standalone resizable window, and the context menu adds export and
    /// delete. Shown only when plans exist.
    /// Plans panel content (without its own header — PanelContainer provides it).
    @ViewBuilder
    private var plansSidePanelContent: some View {
        let items = visiblePlans
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                Text("\(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { showingPlans = true } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .buttonStyle(.plain)
                .help("Open the full plans browser")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items, id: \.plan.id) { entry in
                        Button {
                            openPlanWindow(entry)
                        } label: {
                            Text(entry.plan.title)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(theme.plansCardText)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    theme.accent,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Open \(entry.plan.title) in a window")
                        .contextMenu {
                            Button("Open in Window") { openPlanWindow(entry) }
                            Button("Export as Markdown…") { startExport(entry.plan) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                planStore.delete(id: entry.plan.id, in: entry.scope)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.plansPanel)
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: MarkdownDocument.markdown,
            defaultFilename: exportName
        ) { _ in }
    }

    /// Ordered list of visible panels from mainSlots, excluding floating and hidden ones.
    /// The chat panel is always included (it cannot float or be hidden).
    /// Plans are excluded when there are no plans to show.
    private var orderedPanels: [PanelType] {
        layoutState.mainSlots
            .filter { slot in
                if slot.type == .chat { return true }
                if slot.isFloating || layoutState.hiddenPanels.contains(slot.type) { return false }
                if slot.type == .plans && visiblePlans.isEmpty { return false }
                return true
            }
            .map(\.type)
    }

    /// The chat body — always rendered, expands to fill available space.
    private var chatBody: some View {
        VStack(spacing: 0) {
            workingDirBar
            toolBar
            Divider()
            ShellApprovalBanner()
            messageList
            Divider()
            errorBanner
            streamingStatus
            attachmentStrip
            inputBar
        }
        .background(theme.chatBackground)
    }

    /// Always-visible per-agent tool category toggles rendered inside the chat
    /// body instead of the title bar so they remain accessible and can wrap to
    /// multiple rows when the window is narrow or the panel is half-width.
    private var toolBar: some View {
        HStack(spacing: 0) {
            toolCategoryPicker
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.secondaryBackground)
        .overlay(Divider().frame(maxWidth: .infinity, maxHeight: 1), alignment: .bottom)
    }

    /// Builds the ordered pane list for `ResizablePanelHost`: fixed-width,
    /// drag-resizable side panels (their width persisted per-panel via
    /// `layoutState.widthBinding`) plus the flexible chat body, which always
    /// fills whatever space remains and is always last since `.chat` never
    /// leads `orderedPanels` reordering logic elsewhere assumes.
    private var resizablePanes: [ResizablePane] {
        orderedPanels.map { panel in
            if panel == .chat {
                return ResizablePane(id: panel, length: nil) {
                    chatBody
                }
            }
            return ResizablePane(
                id: panel,
                length: layoutState.widthBinding(for: panel),
                minLength: panel.minWidth,
                maxLength: panel.maxWidth
            ) {
                panelContent(for: panel)
                    .onDrop(of: [.text], delegate: PanelDropDelegate(target: panel, state: layoutState))
            }
        }
    }

    /// Returns the view content for a given panel type.
    @ViewBuilder
    private func panelContent(for panel: PanelType) -> some View {
        switch panel {
        case .plans:
            PanelContainer(panelType: .plans, agentId: vm.agent.id, content: {
                plansSidePanelContent
            }, onFloat: { type in
                openWindow(id: "floating-panel-window",
                           value: FloatingPanelWindowID(panelType: type.rawValue, agentID: vm.agent.id))
            })
        case .tasks:
            PanelContainer(panelType: .tasks, agentId: vm.agent.id, content: {
                todoSidePanelContent
            }, onFloat: { type in
                openWindow(id: "floating-panel-window",
                           value: FloatingPanelWindowID(panelType: type.rawValue, agentID: vm.agent.id))
            })
        case .chat:
            EmptyView()
        }
    }

    private func openPlanWindow(_ entry: (scope: PlanScope, plan: Plan)) {
        openWindow(
            id: "plan-window",
            value: PlanWindowID(scopeKey: entry.scope.key, planID: entry.plan.id))
    }

    private func startExport(_ plan: Plan) {
        exportDocument = MarkdownDocument(text: "# \(plan.title)\n\n\(plan.content)\n")
        exportName = plan.title
        exporting = true
    }

    /// Live task checklist content (without header — PanelContainer provides it).
    @ViewBuilder
    private var todoSidePanelContent: some View {
        let todos = todoStore.lists[vm.agent.id] ?? []
        let done = todos.filter { $0.done }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                Text("\(done)/\(todos.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { todoStore.clear(for: vm.agent.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Clear this task list")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(todos) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.done ? .green : .secondary)
                            Text(item.title)
                                .strikethrough(item.done, color: .secondary)
                                .foregroundStyle(item.done ? Color.secondary : theme.tasksText)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.tasksPanel)
    }

    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Working Directory"
        if let wd = vm.workingDirectory { panel.directoryURL = URL(fileURLWithPath: wd) }
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        vm.setWorkingDirectory(url.path)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.messages.filter { $0.role != .system }) { message in
                        MessageBubble(
                            message: message,
                            isActive: vm.isStreaming && message.id == vm.messages.last?.id,
                            onRevert: message.role == .user
                                ? { vm.inputText = message.content }
                                : nil
                        )
                        .id(message.id)
                    }
                    loadingIndicator
                        .id("loading-indicator")
                }
                .padding(.vertical, 12)
            }
            .onChange(of: vm.messages.last?.content) {
                if let lastID = vm.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            // Reasoning streams before any answer text, so follow it too —
            // otherwise the view wouldn't scroll while the model is thinking.
            .onChange(of: vm.messages.last?.reasoning) {
                if let lastID = vm.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: vm.isStreaming) {
                if vm.isStreaming {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("loading-indicator", anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Shows a spinner + engine state while a model is loading or the first
    /// token is pending (the assistant bubble is still empty). A large model's
    /// first load can take a while, so this signals progress instead of a hang.
    @ViewBuilder
    private var loadingIndicator: some View {
        if vm.isStreaming, (vm.messages.last?.content.isEmpty ?? false) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(loadingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var loadingText: String {
        switch engine.state {
        case .loading(let name): return "Loading \(name)… (first load can take a while)"
        case .downloading(let name): return "\(name) (download in progress)"
        case .generating:        return "Generating…"
        case .error(let msg):    return msg
        default:                 return "Working…"
        }
    }

    private var errorBanner: some View {
        Group {
            if let errMsg = vm.errorMessage {
                HStack {
                    Text(errMsg)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { vm.errorMessage = nil }
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
            }
        }
    }

    /// Persistent, compact "agent is working" line shown for the whole turn
    /// (Warp-style), so the user always sees progress even across many tool
    /// rounds. Reflects the live activity (e.g. "Running read_notes…").
    @ViewBuilder
    private var streamingStatus: some View {
        if vm.isStreaming {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(vm.currentActivity ?? "Thinking\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// Thumbnails of images staged for the next message, each removable.
    @ViewBuilder
    private var attachmentStrip: some View {
        if !vm.pendingImages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(vm.pendingImages.enumerated()), id: \.offset) { index, data in
                        if let nsImage = NSImage(data: data) {
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Button {
                                    vm.pendingImages.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .padding(2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button { pickImages() } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.plain)
            .help("Attach image")

            // Microphone button — tap to record, tap again to stop.
            Button { whisper.toggleRecording() } label: {
                if whisper.isRecording {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: whisper.isRecording)
                } else if whisper.modelState == .loading || whisper.modelState == .downloading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "mic.circle.fill")
                        .foregroundColor(whisper.modelState == .loaded ? .orange : .secondary)
                }
            }
            .buttonStyle(.plain)
            .help(whisper.isRecording ? "Stop recording" : "Record from microphone")

            TextField(streamingPlaceholder, text: inputTextBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit { submitInput() }

            if vm.isStreaming {
                // Steer the running agent without cancelling it.
                Button { vm.steer(text: vm.inputText) } label: {
                    Image(systemName: "arrow.up.circle")
                        .foregroundColor(vm.inputText.isEmpty ? .secondary : .blue)
                }
                .disabled(vm.inputText.isEmpty)
                .help("Steer the running agent (sends without stopping)")
                Button { vm.cancel(engine: engine) } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.red)
                }
                .help("Stop generating")
            } else {
                Button { submitInput() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(
                            vm.inputText.isEmpty && vm.pendingImages.isEmpty ? .secondary : .blue)
                }
                .disabled(vm.inputText.isEmpty && vm.pendingImages.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background)
    }

    /// Placeholder hint: while streaming, the field steers the running agent.
    private var streamingPlaceholder: String {
        vm.isStreaming ? "Steer the agent\u{2026}" : "Message..."
    }

    /// While recording, show live transcription; otherwise normal input text.
    private var inputTextBinding: Binding<String> {
        Binding(
            get: {
                if whisper.isRecording {
                    // Prefer the longest text source to avoid duplication
                    let candidates = [whisper.confirmedText, whisper.unconfirmedText, whisper.liveTranscription]
                        .filter { !$0.isEmpty && $0 != "Waiting for speech..." }
                    let live = candidates.max(by: { $0.count < $1.count }) ?? ""
                    return live.isEmpty ? "Listening\u{2026}" : live
                }
                return vm.inputText
            },
            set: { newValue in
                if !whisper.isRecording {
                    vm.inputText = newValue
                }
            }
        )
    }

    /// Route the field's submit/send action: steer while streaming (don't cancel),
    /// otherwise start a normal send.
    private func submitInput() {
        if vm.isStreaming {
            vm.steer(text: vm.inputText)
        } else {
            vm.send(engine: engine, catalog: catalog, model: effectiveModelForAgent)
        }
    }

    // MARK: - Image attachment intake

    /// Open a file picker for one or more images.
    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let data = Self.pngData(fromFileURL: url) { vm.pendingImages.append(data) }
        }
    }

    /// Load images from dropped/pasted item providers (NSImage or file URL).
    @discardableResult
    private func handleProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage,
                          let data = Self.pngData(from: image) else { return }
                    Task { @MainActor in vm.pendingImages.append(data) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    var url: URL?
                    if let u = item as? URL { url = u }
                    else if let d = item as? Data {
                        url = URL(dataRepresentation: d, relativeTo: nil)
                    }
                    guard let url, let data = Self.pngData(fromFileURL: url) else { return }
                    Task { @MainActor in vm.pendingImages.append(data) }
                }
            }
        }
        return handled
    }

    /// Normalize an NSImage to PNG bytes so the data URI's declared type is honest.
    /// `nonisolated`: pure data transformation touching no actor-isolated state,
    /// so it's genuinely safe to call from the background contexts it's
    /// actually invoked from (the NSEvent paste monitor and NSItemProvider's
    /// asynchronous load completion handlers, neither of which is MainActor).
    private static nonisolated func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }

    /// Load a file URL as PNG bytes (re-encoding via NSImage), falling back to raw.
    private static nonisolated func pngData(fromFileURL url: URL) -> Data? {
        if let image = NSImage(contentsOf: url), let png = pngData(from: image) {
            return png
        }
        return try? Data(contentsOf: url)
    }
}

// MARK: - Panel Drop Delegate

/// Handles drag-and-drop reordering of panels within the right column.
struct PanelDropDelegate: DropDelegate {
    let target: PanelType
    let state: PanelLayoutState

    func performDrop(info: DropInfo) -> Bool {
        guard let item = info.itemProviders(for: [.text]).first else { return false }
        // `loadObject`'s completion runs asynchronously (potentially off the
        // main thread), so the actual move must happen inside it — this
        // method can't wait for that result. Returning `true` here just tells
        // SwiftUI "yes, a compatible item was present and we're handling it,"
        // which is the correct/only honest thing to report synchronously.
        // (A previous version mutated a captured `var` from the completion
        // handler and returned it immediately, which the Swift 6 compiler
        // correctly flags as a data race — that var was read here before the
        // async handler could ever have set it.)
        _ = item.loadObject(ofClass: NSString.self) { item, _ in
            guard let panelID = item as? String,
                  let draggedType = PanelType(rawValue: panelID) else { return }
            DispatchQueue.main.async {
                state.movePanel(draggedType, to: state.mainSlots.firstIndex(where: { $0.type == target }) ?? 0)
            }
        }
        return true
    }

    func dropUpdated(info: DropInfo, proposal: DropProposal) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
