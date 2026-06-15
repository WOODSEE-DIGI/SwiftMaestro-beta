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
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var vm: ChatViewModel
    @State private var showingPlans = false
    @State private var showingMessages = false
    // Markdown export driven from the Plans panel's context menu.
    @State private var exporting = false
    @State private var exportDocument: MarkdownDocument?
    @State private var exportName = "Plan"

    init(vm: ChatViewModel) {
        _vm = ObservedObject(wrappedValue: vm)
    }

    var body: some View {
        HStack(spacing: 0) {
            if !visiblePlans.isEmpty {
                plansSidePanel
                Divider()
            }
            VStack(spacing: 0) {
                workingDirBar
                Divider()
                messageList
                Divider()
                errorBanner
                streamingStatus
                attachmentStrip
                inputBar
            }
            .background(theme.chatBackground)
            if !(todoStore.lists[vm.agent.id] ?? []).isEmpty {
                Divider()
                todoSidePanel
            }
        }
        .navigationTitle("Chat")
        .task(id: vm.agent.id) {
            // Prime the per-agent todo + plan lists from disk (cache-fill) outside
            // of body evaluation so persisted items show after relaunch. Project
            // plan scopes are primed too so the top-bar Plans count is accurate.
            _ = todoStore.todos(for: vm.agent.id)
            _ = planStore.plans(in: .agent(vm.agent.id))
            for project in planScopeProjects { _ = planStore.plans(in: .project(project)) }
            _ = messageStore.inbox(for: vm.agent.id)
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleProviders(providers)
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            _ = handleProviders(providers)
        }
        .toolbar {
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
                Text("Default (global)").tag("")
                ForEach(catalog.models) { m in
                    Text(m.displayName).tag(m.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
            .help("Model used by THIS agent. “Default (global)” follows the toolbar’s Default picker.")
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

    /// This agent's plans, docked as a left-side panel that mirrors the Tasks
    /// panel. Each plan is an accent card; tapping (or "Open in Window") opens it
    /// in a standalone resizable window, and the context menu adds export and
    /// delete. Shown only when plans exist.
    @ViewBuilder
    private var plansSidePanel: some View {
        let items = visiblePlans
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                Text("Plans").font(.headline)
                Spacer()
                Text("\(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { showingPlans = true } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .buttonStyle(.plain)
                .help("Open the full plans browser (scopes, delete)")
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
                        .help("Open “\(entry.plan.title)” in a window")
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
        .frame(width: 280)
        .background(theme.plansPanel)
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: MarkdownDocument.markdown,
            defaultFilename: exportName
        ) { _ in }
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

    /// Live task checklist the agent maintains for this chat via the todo tools,
    /// docked as a right-side panel. Shown only when the agent has tasks.
    @ViewBuilder
    private var todoSidePanel: some View {
        let todos = todoStore.lists[vm.agent.id] ?? []
        let done = todos.filter { $0.done }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                Text("Tasks").font(.headline)
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
        .frame(width: 280)
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
                            isActive: vm.isStreaming && message.id == vm.messages.last?.id
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

            TextField(streamingPlaceholder, text: $vm.inputText, axis: .vertical)
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
    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }

    /// Load a file URL as PNG bytes (re-encoding via NSImage), falling back to raw.
    private static func pngData(fromFileURL url: URL) -> Data? {
        if let image = NSImage(contentsOf: url), let png = pngData(from: image) {
            return png
        }
        return try? Data(contentsOf: url)
    }
}
