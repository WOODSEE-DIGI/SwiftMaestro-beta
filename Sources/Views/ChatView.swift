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
    @StateObject var vm: ChatViewModel
    @State private var layoutState = PanelLayoutState.shared
    @State private var showingPlans = false
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
        _vm = StateObject(wrappedValue: vm)
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

            // Only Maestro should receive audio input and external
            // voice commands. Register this chat as the active recipient if it
            // is the Maestro chat.
            let isNavigator = vm.agent.kind == .navigator
            AgentCommandCenter.shared.isNavigatorActive = isNavigator
            if isNavigator {
                AgentCommandCenter.shared.askAgentHandler = { [weak vm] question in
                    guard let vm else { return }
                    vm.inputText = question
                    vm.send(engine: engine, catalog: catalog, model: effectiveModelForAgent)
                }
            }

            // Observe external "start recording" commands (e.g. from Siri).
            let observer = NotificationCenter.default.addObserver(
                forName: .startWhisperRecording,
                object: nil,
                queue: .main
            ) { _ in
                guard isNavigator else { return }
                Task { @MainActor in
                    if !whisper.isRecording {
                        whisper.toggleRecording()
                    }
                }
            }

            // Keep the task alive; on cancellation (view removed or agent changed)
            // clear the handler and remove the observer.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            AgentCommandCenter.shared.isNavigatorActive = false
            if isNavigator {
                AgentCommandCenter.shared.askAgentHandler = nil
            }
            NotificationCenter.default.removeObserver(observer)
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
            NSLog("[DROP] onDrop fired: %d provider(s)", providers.count)
            let didHandle = handleProviders(providers)
            NSLog("[DROP] handleProviders returned %@", didHandle ? "true" : "FALSE — no provider matched image/fileURL")
            return didHandle
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            handleProviders(providers)
        }
        .onChange(of: whisper.pendingTranscription) { _, newValue in
            if let text = newValue, !text.isEmpty {
                vm.inputText = text
                if whisper.autoSendTranscription {
                    submitInput()
                }
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
    }

    /// Project names selectable as plan scopes in the Plans sheet: Maestro
    /// can browse every project's shared plans; a project agent sees its own.
    /// Also includes every project scope persisted on disk — a model can
    /// invent a scope that matches no workspace project, and hiding it would
    /// make those plans unreachable (the "where did my plan go?" bug).
    private var planScopeProjects: [String] {
        var names = vm.agent.kind == .navigator
            ? workspace.visibleProjects.map(\.name)
            : (vm.projectName.map { [$0] } ?? [])
        for extra in planStore.knownProjectNames()
        where !names.contains(where: { $0.caseInsensitiveCompare(extra) == .orderedSame }) {
            names.append(extra)
        }
        return names
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
            Image(systemName: "cpu").foregroundStyle(theme.chatSecondaryText)
            Text("This agent").foregroundStyle(theme.chatSecondaryText)
            Picker("", selection: agentModelBinding) {
                Label {
                    Text(defaultAgentModelLabel)
                } icon: {
                    // The Default entry carries the badge of the model it
                    // currently resolves to, so provenance is visible even
                    // when this agent follows the global default.
                    if let defaultModel = catalog.selectedModel {
                        Image(nsImage: Self.badgeDotImage(defaultModel.providerBadge.colorName))
                    }
                }
                .tag("")
                ForEach(catalog.models) { m in
                    Label {
                        Text(m.displayName)
                    } icon: {
                        Image(nsImage: Self.badgeDotImage(m.providerBadge.colorName))
                    }
                    .tag(m.id)
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
        .foregroundStyle(theme.chatSecondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var workingDirLabel: String {
        guard let wd = vm.workingDirectory else { return "Set working directory…" }
        return (wd as NSString).lastPathComponent
    }

    /// Map the model's badge color name to a Color (badge colors are plain
    /// names so MaestroModel stays platform-agnostic).
    static func badgeColor(_ name: String) -> Color {
        switch name {
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "orange": return .orange
        default: return .secondary
        }
    }

    /// Pre-rendered colored dot for Picker menus. SF Symbols in macOS menus
    /// render as theme-tinted monochrome templates, so the badge color needs
    /// a real bitmap; NSImage draws are shown in true color.
    private static var badgeDotCache: [String: NSImage] = [:]
    static func badgeDotImage(_ colorName: String, size: CGFloat = 10) -> NSImage {
        if let cached = badgeDotCache[colorName] { return cached }
        let nsColor: NSColor
        switch colorName {
        case "green": nsColor = .systemGreen
        case "blue": nsColor = .systemBlue
        case "purple": nsColor = .systemPurple
        case "orange": nsColor = .systemOrange
        default: nsColor = .secondaryLabelColor
        }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        badgeDotCache[colorName] = image
        return image
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
                let autoManaged = autoTools && category.isPanelLinked
                // Saved-on but not active = switched on, waiting for its panel
                // (Auto mode). Shown as a faint outline so the toggle has
                // visible feedback even while the panel is closed.
                let pending = !active && autoManaged && savedCategories.contains(category)
                Button {
                    categoryTapped(category)
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: category.icon)
                            .symbolVariant(active ? .fill : .none)
                            .foregroundStyle(active ? theme.accent : theme.chatSecondaryText)
                            .frame(height: 14)
                        Text(category.displayName)
                            .font(.system(size: 8, weight: active ? .semibold : .medium))
                            .foregroundStyle(active ? theme.accent : theme.chatSecondaryText)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 34)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(active ? theme.accent.opacity(0.12) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .opacity(pending ? 1 : 0)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    autoManaged
                        ? (active
                            ? "\(category.displayName): on — active while its panel is open (Auto). Tap to switch off."
                            : savedCategories.contains(category)
                                ? "\(category.displayName): on — will activate when its panel opens (Auto). Tap to switch off."
                                : "\(category.displayName): off. Tap to switch on — activates when its panel opens (Auto).")
                        : "\(category.displayName): \(active ? "on" : "off"). Tap to \(active ? "switch off" : "switch on").")
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
                            .foregroundStyle(theme.chatSecondaryText)
                            .frame(height: 14)
                        Text("Add")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(theme.chatSecondaryText)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 34)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(theme.chatSecondaryText.opacity(0.45), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .help("Add more tool categories")
            }

            Divider().frame(width: 1, height: 18)

            Button {
                workspace.setAutoToolCategories(!autoTools, for: vm.agent.id)
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolVariant(autoTools ? .fill : .none)
                        .foregroundStyle(autoTools ? theme.accent : theme.chatSecondaryText)
                        .frame(height: 14)
                    Text("Auto")
                        .font(.system(size: 8, weight: autoTools ? .semibold : .medium))
                        .foregroundStyle(autoTools ? theme.accent : theme.chatSecondaryText)
                        .lineLimit(1)
                }
                .frame(minWidth: 34)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(autoTools ? theme.accent.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                "Auto tools: \(autoTools ? "on" : "off"). When on, app tool categories "
                + "(Books, Database, Kanban, Notes, …) are advertised only while that "
                + "app's panel is open — core tools are unaffected. Turn off to manage "
                + "every category manually.")

            Button {
                workspace.setCompactToolMode(!compactToolMode, for: vm.agent.id)
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .symbolVariant(compactToolMode ? .fill : .none)
                        .foregroundStyle(compactToolMode ? theme.accent : theme.chatSecondaryText)
                        .frame(height: 14)
                    Text("Compact")
                        .font(.system(size: 8, weight: compactToolMode ? .semibold : .medium))
                        .foregroundStyle(compactToolMode ? theme.accent : theme.chatSecondaryText)
                        .lineLimit(1)
                }
                .frame(minWidth: 34)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(compactToolMode ? theme.accent.opacity(0.12) : Color.clear)
                )
                .overlay(
                    // Context usage glow: a neon border that thickens and
                    // brightens as the conversation approaches compaction.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            contextGlowColor,
                            style: StrokeStyle(
                                lineWidth: contextGlowWidth,
                                lineCap: .round, lineJoin: .round))
                        .opacity(contextGlowOpacity)
                        .animation(.easeInOut(duration: 0.5), value: vm.contextProgress)
                )
                .shadow(color: contextGlowColor.opacity(contextGlowOpacity * 0.6),
                        radius: contextGlowRadius, x: 0, y: 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                "Compact Tool Mode: \(compactToolMode ? "on" : "off"). Context \(Int(vm.contextProgress * 100))% full."
                + (compactToolMode ? " When on, categories hidden from prompt — reachable via search_tools/call_tool." : "")
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    /// Whether Compact Tool Mode is on for this agent.
    private var compactToolMode: Bool {
        workspace.compactToolMode(for: vm.agent.id)
    }

    // MARK: - Context glow properties

    /// Neon glow color: shifts from subtle blue → warning orange → hot red
    /// as context fills. At low usage it's barely visible; at 80%+ it pulses.
    private var contextGlowColor: Color {
        let p = vm.contextProgress
        if p < 0.5 {
            // Subtle cyan at low usage — just a hint of presence.
            return Color.cyan.opacity(0.4)
        } else if p < 0.75 {
            // Warm up through orange as context fills.
            let t = (p - 0.5) / 0.25  // 0→1 across this band
            return Color.lerp(.cyan, .orange, t)
        } else {
            // Red zone — approaching compaction.
            let t = (p - 0.75) / 0.25  // 0→1 across this band
            return Color.lerp(.orange, .red, t)
        }
    }

    /// Border width: starts invisible (0), reaches ~2pt at full.
    private var contextGlowWidth: CGFloat {
        let p = vm.contextProgress
        if p < 0.1 { return 0 }  // invisible when barely started
        return CGFloat(p) * 2.5
    }

    /// Glow opacity: fades in as context fills, full visibility at 50%+.
    private var contextGlowOpacity: Double {
        let p = vm.contextProgress
        if p < 0.1 { return 0 }
        return min(1.0, p * 1.5)
    }

    /// Shadow radius for the neon glow effect.
    private var contextGlowRadius: CGFloat {
        let p = vm.contextProgress
        if p < 0.3 { return 0 }
        return CGFloat(p) * 6
    }

    /// Whether panel-driven tool categories (Auto) is on for this agent.
    private var autoTools: Bool {
        workspace.autoToolCategories(for: vm.agent.id)
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

    /// The categories actually advertised to the model right now — under Auto
    /// this is the panel-derived effective set; otherwise the saved set.
    private var enabledCategories: Set<ToolCategory> {
        workspace.effectiveToolCategories(for: vm.agent.id)
    }

    /// The SAVED category set (what the user chose manually). Writes always go
    /// here so turning Auto off restores exactly what the user picked.
    private var savedCategories: Set<ToolCategory> {
        workspace.enabledToolCategories(for: vm.agent.id)
    }

    /// Tap behaviour: the switcher is a pure access toggle — tapping always
    /// flips the category in the saved set and NEVER opens a panel. (It used
    /// to open/focus the app panel under Auto mode, which conflated "manage
    /// access" with "navigate" — opening a panel is the user's job via the
    /// Apps sidebar or the agent's via open_panel.)
    private func categoryTapped(_ category: ToolCategory) {
        toggleCategory(category)
    }

    private func toggleCategory(_ category: ToolCategory) {
        // Always mutate the SAVED set, never the panel-derived effective set —
        // writing effective-as-saved under Auto would permanently strip
        // categories whose panels happen to be closed right now.
        var updated = savedCategories
        if updated.contains(category) {
            updated.remove(category)
        } else {
            updated.insert(category)
        }
        workspace.setEnabledToolCategories(updated, for: vm.agent.id)
    }

    private func enableCategory(_ category: ToolCategory) {
        var updated = savedCategories
        updated.insert(category)
        workspace.setEnabledToolCategories(updated, for: vm.agent.id)
    }

    /// Live per-agent model override binding ("" = use the global default),
    /// read from and written back to the workspace record.
    private var agentModelBinding: Binding<String> {
        Binding(
            get: { workspace.agent(id: vm.agent.id)?.modelID ?? "" },
            set: { newValue in
                workspace.setModel(newValue.isEmpty ? nil : newValue, for: vm.agent.id)
                vm.updateModelHuggingFaceID()
            }
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
                    .foregroundStyle(theme.plansPanelText)
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
                                    theme.plansCard,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Open \(entry.plan.title) in a window")
                        .contextMenu {
                            if vm.attachedPlan?.plan.id == entry.plan.id {
                                Button("Detach from Session") { vm.detachAttachedPlan() }
                            } else {
                                Button("Attach to Session") {
                                    vm.attach(plan: entry.plan, scope: entry.scope)
                                }
                            }
                            Divider()
                            Button("Open in Window") { openPlanWindow(entry) }
                            Button("Export as Markdown…") { startExport(entry.plan) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                planStore.delete(id: entry.plan.id, in: entry.scope)
                                if vm.attachedPlan?.plan.id == entry.plan.id { vm.detachAttachedPlan() }
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
            FeatureTipPopup(
                key: FeatureTip.memory,
                message: "I can remember things across sessions. Just ask naturally — \"remember that I prefer X\" or \"what did we discuss about Y?\" — and I'll store or recall context automatically.",
                icon: "brain.head.profile"
            ) {
                inputBar
            }
        }
        .background(theme.chatBackground)
    }

    /// Always-visible per-agent tool category toggles rendered inside the chat
    /// body instead of the title bar so they remain accessible and can wrap to
    /// multiple rows when the window is narrow or the panel is half-width.
    private var toolBar: some View {
        HStack(spacing: 0) {
            FeatureTipPopup(
                key: FeatureTip.toolPicker,
                message: "Toggle tool categories on or off. Fewer tools = faster responses and fewer accidental side-effects. Under Auto mode, tools activate when their panel opens.",
                icon: "wrench.and.screwdriver"
            ) {
                toolCategoryPicker
            }
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
                    .foregroundStyle(theme.tasksText.opacity(0.65))
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
                                .foregroundStyle(item.done ? .green : theme.tasksText.opacity(0.55))
                            Text(MaestroTools.sanitizeModelText(item.title))
                                .strikethrough(item.done, color: theme.tasksText.opacity(0.55))
                                .foregroundStyle(item.done ? theme.tasksText.opacity(0.55) : theme.tasksText)
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
                                ? { revertTarget = message }
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
            .alert(
                "Revert to this message?",
                isPresented: Binding(
                    get: { revertTarget != nil },
                    set: { if !$0 { revertTarget = nil } }
                ),
                presenting: revertTarget
            ) { target in
                Button("Revert", role: .destructive) {
                    vm.revertTo(messageID: target.id)
                    revertTarget = nil
                }
                Button("Cancel", role: .cancel) { revertTarget = nil }
            } message: { target in
                let idx = vm.messages.firstIndex(where: { $0.id == target.id }) ?? vm.messages.count
                let removed = vm.messages.count - idx
                Text("The message text moves back into the input, and \(removed) message(s) from that point on are deleted. This cannot be undone.")
            }
        }
    }

    /// The user message pending a revert confirmation (see Revert alert).
    @State private var revertTarget: Message?

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
                    .foregroundStyle(theme.chatSecondaryText)
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
    /// (terminal-style live status), so the user always sees progress even
    /// across many tool rounds. Reflects the live activity (e.g. "Running
    /// read_notes…").
    @ViewBuilder
    private var streamingStatus: some View {
        if vm.isStreaming {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(vm.currentActivity ?? "Thinking\u{2026}")
                    .font(.caption)
                    .foregroundStyle(theme.chatSecondaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// Thumbnails of images staged for the next message, each removable.
    @ViewBuilder
    private var attachmentStrip: some View {
        // Attached-plan chip: the plan the agent sees every turn until detached.
        if let attached = vm.attachedPlan {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                Text(attached.plan.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Button { vm.detachAttachedPlan() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(theme.plansCardText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(theme.plansCard, in: Capsule())
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Plan attached to this session — the agent sees its full content every turn. Click × to detach.")
        }
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

            // Microphone button — only shown for Maestro.
            if vm.agent.kind == .navigator {
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
                            .foregroundColor(whisper.modelState == .loaded ? .orange : theme.chatSecondaryText)
                    }
                }
                .buttonStyle(.plain)
                .help(whisper.isRecording ? "Stop recording" : "Record from microphone")
            }

            TextField(streamingPlaceholder, text: inputTextBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit { submitInput() }

            if vm.isStreaming {
                // Steer the running agent without cancelling it.
                Button { submitInput() } label: {
                    Image(systemName: "arrow.up.circle")
                        .foregroundColor(
                            vm.inputText.isEmpty && vm.pendingImages.isEmpty ? theme.chatSecondaryText : .blue)
                }
                .disabled(vm.inputText.isEmpty && vm.pendingImages.isEmpty)
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
                            vm.inputText.isEmpty && vm.pendingImages.isEmpty ? theme.chatSecondaryText : .blue)
                }
                .disabled(vm.inputText.isEmpty && vm.pendingImages.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .foregroundStyle(theme.chatText)
        .background(theme.secondaryBackground)
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
    /// otherwise start a normal send. If a drop/paste is still decoding its
    /// image, hold the submit until it lands so the image rides THIS message
    /// instead of being orphaned to the next one.
    private func submitInput() {
        guard vm.pendingImageLoads == 0 else {
            Task { @MainActor in
                await vm.waitForPendingImageLoads()
                submitInput()
            }
            return
        }
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
    /// Each in-flight decode is counted in `vm.pendingImageLoads` so a fast
    /// drop→submit can wait for it instead of losing the image.
    @discardableResult
    private func handleProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            let canImage = provider.canLoadObject(ofClass: NSImage.self)
            let hasFileURL = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            NSLog("[DROP] provider types=%@ canNSImage=%@ hasFileURL=%@",
                  provider.registeredTypeIdentifiers.joined(separator: ","),
                  canImage ? "YES" : "no", hasFileURL ? "YES" : "no")
            if canImage {
                handled = true
                vm.pendingImageLoads += 1
                _ = provider.loadObject(ofClass: NSImage.self) { object, error in
                    defer { Task { @MainActor in vm.pendingImageLoads -= 1 } }
                    if let error { NSLog("[DROP] NSImage load error: %@", error.localizedDescription) }
                    guard let image = object as? NSImage,
                          let data = Self.pngData(from: image) else {
                        NSLog("[DROP] NSImage cast/pngData failed (object=%@)", String(describing: type(of: object)))
                        return
                    }
                    Task { @MainActor in vm.pendingImages.append(data) }
                    NSLog("[DROP] image appended via NSImage path (%d bytes)", data.count)
                }
            } else if hasFileURL {
                handled = true
                vm.pendingImageLoads += 1
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    defer { Task { @MainActor in vm.pendingImageLoads -= 1 } }
                    if let error { NSLog("[DROP] fileURL load error: %@", error.localizedDescription) }
                    var url: URL?
                    if let u = item as? URL { url = u }
                    else if let d = item as? Data {
                        url = URL(dataRepresentation: d, relativeTo: nil)
                    }
                    guard let url, let data = Self.pngData(fromFileURL: url) else {
                        NSLog("[DROP] fileURL decode failed (item=%@)", String(describing: type(of: item)))
                        return
                    }
                    Task { @MainActor in
                        vm.pendingImages.append(data)
                        vm.pendingImagePaths.append(url.path)
                    }
                    NSLog("[DROP] image appended via fileURL path (%d bytes, %@)", data.count, url.lastPathComponent)
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

// MARK: - Color interpolation

private extension Color {
    /// Linearly interpolate between two colors. `t` ranges 0.0 → 1.0.
    static func lerp(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let t = Float(min(1, max(0, t)))
        var env = EnvironmentValues()
        let r1 = a.resolve(in: env)
        let r2 = b.resolve(in: env)
        let r = r1.red   + (r2.red   - r1.red)   * t
        let g = r1.green + (r2.green - r1.green) * t
        let bl = r1.blue  + (r2.blue  - r1.blue)  * t
        let al = r1.opacity + (r2.opacity - r1.opacity) * t
        return Color(.sRGB, red: Double(r), green: Double(g), blue: Double(bl), opacity: Double(al))
    }
}
