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
    /// Styles, Paragraph, Color, Insert, View groups for rich editable ones.
    /// Horizontally scrollable so narrow docked panels never lose groups.
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ribbonGroup("Clipboard") {
                    HStack(spacing: 4) {
                        ribbonButton("Paste", icon: "doc.on.clipboard") { viewModel.pasteFromClipboard() }
                        ribbonButton("Copy", icon: "doc.on.doc") { viewModel.copySelection() }
                        ribbonButton("Cut", icon: "scissors") { viewModel.cutSelection() }
                    }
                }
                ribbonSeparator
                ribbonGroup("Undo") {
                    HStack(spacing: 4) {
                        ribbonButton("Undo", icon: "arrow.uturn.backward") { viewModel.undo() }
                        ribbonButton("Redo", icon: "arrow.uturn.forward") { viewModel.redo() }
                    }
                }

                if viewModel.formattingAvailable {
                    ribbonSeparator
                    ribbonGroup("Font") {
                        HStack(spacing: 4) {
                            ribbonButton("Bold", icon: "bold") { viewModel.toggleBold() }
                                .keyboardShortcut("b", modifiers: .command)
                            ribbonButton("Italic", icon: "italic") { viewModel.toggleItalic() }
                                .keyboardShortcut("i", modifiers: .command)
                            ribbonButton("Underline", icon: "underline") { viewModel.toggleUnderline() }
                                .keyboardShortcut("u", modifiers: .command)
                            ribbonButton("Strikethrough", icon: "strikethrough") {
                                viewModel.toggleStrikethrough()
                            }
                        }
                        HStack(spacing: 4) {
                            ribbonButton("Larger", icon: "textformat.size") {
                                viewModel.changeFontSize(delta: 2)
                            }
                            ribbonButton("Smaller", icon: "textformat.size") {
                                viewModel.changeFontSize(delta: -2)
                            }
                            ribbonButton("Clear", icon: "eraser") {
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
                            Label("Styles", systemImage: "textformat.size")
                                .font(.system(size: 11))
                                .frame(height: 28)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 70)
                        .help("Paragraph style")
                    }
                    ribbonSeparator
                    ribbonGroup("Paragraph") {
                        HStack(spacing: 4) {
                            ribbonButton("Left", icon: "text.alignleft") {
                                viewModel.applyAlignment(.left)
                            }
                            ribbonButton("Center", icon: "text.aligncenter") {
                                viewModel.applyAlignment(.center)
                            }
                            ribbonButton("Right", icon: "text.alignright") {
                                viewModel.applyAlignment(.right)
                            }
                            ribbonButton("Justify", icon: "text.justify") {
                                viewModel.applyAlignment(.justified)
                            }
                        }
                        HStack(spacing: 4) {
                            ribbonButton("Bullets", icon: "list.bullet") {
                                viewModel.applyList(.disc)
                            }
                            ribbonButton("Numbers", icon: "list.number") {
                                viewModel.applyList(.decimal)
                            }
                            ribbonButton("Outdent", icon: "decrease.indent") {
                                viewModel.changeIndent(delta: -20)
                            }
                            ribbonButton("Indent", icon: "increase.indent") {
                                viewModel.changeIndent(delta: 20)
                            }
                        }
                    }
                    ribbonSeparator
                    ribbonGroup("Color") {
                        HStack(spacing: 8) {
                            ColorPicker("Text", selection: $pickedColor)
                                .labelsHidden()
                                .onChange(of: pickedColor) { _, newValue in
                                    viewModel.applyTextColor(NSColor(newValue))
                                }
                                .help("Text color")
                            ColorPicker("Highlight", selection: $pickedHighlight)
                                .labelsHidden()
                                .onChange(of: pickedHighlight) { _, newValue in
                                    viewModel.applyHighlight(NSColor(newValue))
                                }
                                .help("Highlight color")
                            ribbonButton("Clear", icon: "xmark.square") {
                                viewModel.applyHighlight(nil)
                            }
                        }
                    }
                    ribbonSeparator
                    ribbonGroup("Insert") {
                        HStack(spacing: 4) {
                            ribbonButton("Link", icon: "link") {
                                linkURLText = ""
                                showLinkSheet = true
                            }
                            ribbonButton("Page Break", icon: "doc.append") {
                                viewModel.insertPageBreak()
                            }
                        }
                    }
                    ribbonSeparator
                    ribbonGroup("View") {
                        HStack(spacing: 4) {
                            ribbonButton("Zoom−", icon: "minus.magnifyingglass") {
                                viewModel.zoomLevel = max(25, viewModel.zoomLevel - 10)
                            }
                            Text("\(Int(viewModel.zoomLevel))%")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 36)
                            ribbonButton("Zoom+", icon: "plus.magnifyingglass") {
                                viewModel.zoomLevel = min(400, viewModel.zoomLevel + 10)
                            }
                            ribbonButton("Fit", icon: "arrow.up.left.and.arrow.down.right") {
                                viewModel.zoomLevel = 100
                            }
                        }
                        HStack(spacing: 4) {
                            ribbonButton("1-Up", icon: "rectangle") {
                                viewModel.pageViewMode = .single
                            }
                            .opacity(viewModel.pageViewMode == .single ? 1 : 0.5)
                            ribbonButton("2-Up", icon: "rectangle.split.2x1") {
                                viewModel.pageViewMode = .twoUp
                            }
                            .opacity(viewModel.pageViewMode == .twoUp ? 1 : 0.5)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showLinkSheet) { linkSheet }
    }

    private var ribbonSeparator: some View {
        Divider()
            .frame(width: 1, height: 40)
            .padding(.horizontal, 6)
    }

    /// Office-style group: controls on top, caption beneath.
    private func ribbonGroup<Content: View>(
        _ caption: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 4) {
            content()
                .frame(minHeight: 32, alignment: .center)
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    /// Ribbon button: icon + optional label, hover highlight.
    private func ribbonButton(
        _ label: String, icon: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 28, height: 22)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 44, height: 38)
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
