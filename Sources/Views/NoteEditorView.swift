import SwiftUI

// MARK: - Note editor view

/// Split editor/preview for a single Markdown note. The layout can be switched
/// between Editor-only, Split, and Preview-only. Panes share the available
/// detail-column space equally; each pane clips its content so it cannot push
/// the split outside the window.
struct NoteEditorView: View {
    @Bindable var viewModel: NotesViewModel
    @Environment(ThemeStore.self) private var theme

    enum LayoutMode: String, CaseIterable, Identifiable {
        case editor = "Editor"
        case split = "Split"
        case preview = "Preview"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .editor: return "square.and.pencil"
            case .split: return "rectangle.split.1x2"
            case .preview: return "eye"
            }
        }
    }

    @State private var layoutMode: LayoutMode = .split
    @State private var editorController = MarkdownEditorController()
    @State private var editorFont: MarkdownEditorFont = MarkdownEditorFont.fromDefaults()

    var body: some View {
        VStack(spacing: 0) {
            if let warning = readOnlyWarning {
                readOnlyBanner(message: warning)
            }
            toolbar
            Divider()
            editorContent
        }
        .background(theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Non-nil when the selected note lives in the read-only AI Memory store.
    private var readOnlyWarning: String? {
        guard let item = viewModel.selectedItem, item.isReadOnly else { return nil }
        return "This file lives in AI Memory and is read-only in Notes. "
            + "The agent writes it automatically; back it up before editing."
    }

    private func readOnlyBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                if let item = viewModel.selectedItem {
                    try? FileManager.default.createDirectory(
                        at: item.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
            } label: {
                Label("Reveal & Back Up", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reveal this file in Finder so you can back it up before editing")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.secondaryBackground)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(viewModel.selectedItem?.title ?? "No note selected")
                .font(.headline)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer()

            Picker("Layout", selection: $layoutMode) {
                ForEach(LayoutMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.icon)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch between editor, split, and preview layouts")

            Toggle(isOn: $viewModel.autosaveEnabled) {
                Text("Autosave")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("Save automatically 1.5s after you stop typing")

            Button {
                Task { await viewModel.saveCurrentNote() }
            } label: {
                Label(
                    viewModel.isSaving ? "Saving…" : (viewModel.isDirty ? "Save" : "Saved"),
                    systemImage: viewModel.isSaving
                        ? "ellipsis.circle"
                        : (viewModel.isDirty ? "arrow.down.circle.fill" : "checkmark.circle")
                )
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!viewModel.isDirty || viewModel.isSaving)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.secondaryBackground)
    }

    // MARK: - Content

    private var editorContent: some View {
        HStack(spacing: 0) {
            if layoutMode != .preview {
                editorPane
            }

            if layoutMode == .split {
                Divider()
            }

            if layoutMode != .editor {
                previewPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            paneHeader(title: "Editor", icon: "square.and.pencil")
            Divider()
            MarkdownFormatToolbar(
                controller: editorController,
                editorFont: $editorFont,
                onCommand: { viewModel.markDirty() }
            )
            .background(theme.secondaryBackground.opacity(0.5))
            Divider()
            MarkdownTextEditor(
                text: $viewModel.editorText,
                font: editorFont.nsFont,
                controller: editorController,
                onChange: { viewModel.markDirty() }
            )
            .background(theme.background)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .clipped()
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            paneHeader(title: "Preview", icon: "eye")
            Divider()
            ScrollView {
                RichMarkdownView(
                    text: viewModel.editorText,
                    isUser: false,
                    // Clip notes reference assets/… beside the .md file —
                    // the note's directory is the base for local images.
                    baseURL: viewModel.selectedItem?.url.deletingLastPathComponent()
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(theme.secondaryBackground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.secondaryBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .clipped()
    }

    private func paneHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.secondaryBackground)
    }
}

// MARK: - Preview

#Preview {
    let vm = NotesViewModel()
    vm.editorText = "# Hello Notes\n\nThis is a **test** note.\n\n```swift\nprint(\"hi\")\n```"
    return NoteEditorView(viewModel: vm)
        .frame(width: 900, height: 500)
}
