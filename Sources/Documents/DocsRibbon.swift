import AppKit
import SwiftUI

// MARK: - Shared Docs ribbon
//
// Office-style editing + formatting ribbon driven by a
// MaestroDocsViewModel. Extracted from MaestroDocsView so other apps can
// embed the same toolset — MaestroBooks uses it on the invoice-template
// designer page.
struct DocsRibbon: View {
    var viewModel: MaestroDocsViewModel

    @State private var pickedColor: Color = .primary
    @State private var pickedHighlight: Color = .yellow
    @State private var showLinkSheet = false
    @State private var linkURLText = ""

    /// Grouped ribbon: Clipboard + Undo for all editable documents; Font,
    /// Styles, Paragraph, Color, Insert groups for rich editable ones.
    /// Horizontally scrollable so narrow docked panels never lose groups.
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 2) {
                ribbonGroup("Clipboard") {
                    HStack(spacing: 2) {
                        ribbonIcon("Paste", icon: "doc.on.clipboard") { viewModel.pasteFromClipboard() }
                        ribbonIcon("Copy", icon: "doc.on.doc") { viewModel.copySelection() }
                        ribbonIcon("Cut", icon: "scissors") { viewModel.cutSelection() }
                    }
                }
                ribbonSeparator
                ribbonGroup("Undo") {
                    HStack(spacing: 2) {
                        ribbonIcon("Undo", icon: "arrow.uturn.backward") { viewModel.undo() }
                        ribbonIcon("Redo", icon: "arrow.uturn.forward") { viewModel.redo() }
                    }
                }

                if viewModel.formattingAvailable {
                    ribbonSeparator
                    ribbonGroup("Font") {
                        HStack(spacing: 2) {
                            ribbonIcon("Bold (⌘B)", icon: "bold") { viewModel.toggleBold() }
                                .keyboardShortcut("b", modifiers: .command)
                            ribbonIcon("Italic (⌘I)", icon: "italic") { viewModel.toggleItalic() }
                                .keyboardShortcut("i", modifiers: .command)
                            ribbonIcon("Underline (⌘U)", icon: "underline") { viewModel.toggleUnderline() }
                                .keyboardShortcut("u", modifiers: .command)
                            ribbonIcon("Strikethrough", icon: "strikethrough") {
                                viewModel.toggleStrikethrough()
                            }
                        }
                        HStack(spacing: 2) {
                            ribbonIcon("Bigger", icon: "textformat.size.bigger") {
                                viewModel.changeFontSize(delta: 1)
                            }
                            ribbonIcon("Smaller", icon: "textformat.size.smaller") {
                                viewModel.changeFontSize(delta: -1)
                            }
                            ribbonIcon("Clear formatting", icon: "eraser") {
                                viewModel.clearFormatting()
                            }
                        }
                    }
                    ribbonSeparator
                    ribbonGroup("Styles") {
                        Menu {
                            Button("Heading 1") { viewModel.applyHeading(size: 26, weight: .bold) }
                            Button("Heading 2") { viewModel.applyHeading(size: 20, weight: .bold) }
                            Button("Heading 3") { viewModel.applyHeading(size: 16, weight: .semibold) }
                            Divider()
                            Button("Body") { viewModel.applyHeading(size: 12, weight: .regular) }
                        } label: {
                            Image(systemName: "textformat.size.larger")
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .help("Paragraph style")
                    }
                    ribbonSeparator
                    ribbonGroup("Paragraph") {
                        HStack(spacing: 2) {
                            ribbonIcon("Align left", icon: "text.alignleft") {
                                viewModel.applyAlignment(.left)
                            }
                            ribbonIcon("Center", icon: "text.aligncenter") {
                                viewModel.applyAlignment(.center)
                            }
                            ribbonIcon("Align right", icon: "text.alignright") {
                                viewModel.applyAlignment(.right)
                            }
                            ribbonIcon("Justify", icon: "text.justify") {
                                viewModel.applyAlignment(.justified)
                            }
                        }
                        HStack(spacing: 2) {
                            ribbonIcon("Bulleted list", icon: "list.bullet") {
                                viewModel.applyList(.disc)
                            }
                            ribbonIcon("Numbered list", icon: "list.number") {
                                viewModel.applyList(.decimal)
                            }
                            ribbonIcon("Outdent", icon: "decrease.indent") {
                                viewModel.changeIndent(delta: -20)
                            }
                            ribbonIcon("Indent", icon: "increase.indent") {
                                viewModel.changeIndent(delta: 20)
                            }
                        }
                    }
                    ribbonSeparator
                    ribbonGroup("Color") {
                        HStack(spacing: 4) {
                            ColorPicker("Text", selection: $pickedColor)
                                .labelsHidden()
                                .onChange(of: pickedColor) { _, newValue in
                                    viewModel.applyTextColor(NSColor(newValue))
                                }
                                .frame(width: 36)
                                .help("Text color")
                            ColorPicker("Highlight", selection: $pickedHighlight)
                                .labelsHidden()
                                .onChange(of: pickedHighlight) { _, newValue in
                                    viewModel.applyHighlight(NSColor(newValue))
                                }
                                .frame(width: 36)
                                .help("Highlight color")
                            ribbonIcon("Clear highlight", icon: "xmark.square") {
                                viewModel.applyHighlight(nil)
                            }
                        }
                    }
                    ribbonSeparator
                    ribbonGroup("Insert") {
                        HStack(spacing: 2) {
                            ribbonIcon("Insert link", icon: "link") {
                                linkURLText = ""
                                showLinkSheet = true
                            }
                            ribbonIcon("Page break", icon: "text.append") {
                                viewModel.insertPageBreak()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showLinkSheet) { linkSheet }
    }

    private var ribbonSeparator: some View {
        Divider()
            .frame(height: 44)
    }

    /// Office-style group: controls on top, caption beneath, fixed control
    /// height so all captions align across single- and double-row groups.
    private func ribbonGroup<Content: View>(
        _ caption: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 3) {
            content()
                .frame(height: 51, alignment: .top)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5)
    }

    private func ribbonIcon(
        _ label: String, icon: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
    }

    /// Insert-link prompt: wraps bare hosts with https:// automatically.
    private var linkSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert Link")
                .font(.title3.weight(.bold))
            Text("Applies to the selected text, or inserts the URL itself "
                 + "when nothing is selected.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("https://example.com", text: $linkURLText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
            HStack {
                Spacer()
                Button("Cancel") { showLinkSheet = false }
                Button("Insert") {
                    var text = linkURLText.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty && !text.contains("://") { text = "https://" + text }
                    if let url = URL(string: text) { viewModel.applyLink(url) }
                    showLinkSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(linkURLText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}
