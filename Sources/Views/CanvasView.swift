import SwiftUI
import AppKit
import PaperKit
import PencilKit

// MARK: - Fallback for older macOS

struct CanvasFallbackView: View {
    var body: some View {
        ContentUnavailableView(
            "Canvas Requires macOS 26",
            systemImage: "rectangle.3.group",
            description: Text("The native PaperKit canvas is only available on macOS 26 or later.")
        )
    }
}

// MARK: - Temporary placeholder

/// Temporary placeholder shown while PaperKit integration is paused.
/// To re-enable the live PaperKit canvas, swap the call in `canvasArea(board:)`
/// back to `PaperCanvasView(markup:)` and restore `loadMarkup(for:)` below.
struct PaperKitCanvasPlaceholderView: View {
    let boardName: String

    var body: some View {
        ContentUnavailableView(
            "Canvas Offline",
            systemImage: "rectangle.3.group",
            description: Text(
                "PaperKit canvas is temporarily disabled while its remote view embedding is investigated. Board: \(boardName)"
            )
        )
    }
}

// MARK: - Canvas view

@available(macOS 26.0, *)
struct CanvasView: View {
    @Environment(CanvasStore.self) private var store

    @State private var board: CanvasBoard?
    @State private var paperMarkup: PaperMarkup?
    @State private var showNewBoardSheet = false
    @State private var newBoardName = ""
    @State private var error: String?

    var body: some View {
        HStack(spacing: 0) {
            boardList
                .frame(width: 220)
            Divider()
            canvasDetail
        }
        .task {
            store.loadBoards()
        }
        .alert("Canvas Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Board list

    private var boardList: some View {
        List(selection: .init(
            get: { board?.id },
            set: { id in
                Task {
                    await persistCurrentMarkup()
                }
                board = store.boards.first { $0.id == id }
                loadMarkup(for: board)
            }
        )) {
            Section("Boards") {
                if store.boards.isEmpty {
                    Text("No boards yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.boards) { b in
                        Text(b.name)
                            .tag(b.id)
                            .lineLimit(1)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    deleteBoardItem(b)
                                }
                                Button("Duplicate") {
                                    let copy = store.duplicate(b)
                                    board = copy
                                    loadMarkup(for: copy)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Canvas")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewBoardSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewBoardSheet) {
            newBoardSheet
        }
    }

    private var newBoardSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Canvas Board").font(.title3.bold())
            TextField("Board name", text: $newBoardName)
            HStack {
                Spacer()
                Button("Cancel") {
                    showNewBoardSheet = false
                    newBoardName = ""
                }
                Button("Create") {
                    let name = newBoardName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    showNewBoardSheet = false
                    newBoardName = ""
                    let newBoard = store.createBoard(name: name)
                    board = newBoard
                    // Defer PaperKit view creation until after the sheet has fully
                    // dismissed to avoid first-responder / layout conflicts.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))
                        loadMarkup(for: newBoard)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newBoardName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 360, height: 160)
    }

    // MARK: - Canvas detail

    @ViewBuilder
    private var canvasDetail: some View {
        if let board {
            canvasArea(board: board)
                .id(board.id)
                .onDisappear {
                    Task {
                        await persistCurrentMarkup()
                    }
                }
        } else {
            ContentUnavailableView(
                "Select or Create a Board",
                systemImage: "rectangle.3.group",
                description: Text("Choose a board from the list or create a new one")
            )
        }
    }

    private func canvasArea(board: CanvasBoard) -> some View {
        // PLACEHOLDER: PaperKit view creation hangs on this macOS build (see
        // ai-context notes). To resume work, replace the placeholder with:
        //   PaperCanvasView(markup: paperMarkup ?? PaperMarkup(bounds: defaultCanvasBounds()))
        PaperKitCanvasPlaceholderView(boardName: board.name)
            .toolbar { canvasToolbar(board: board) }
    }

    private func canvasToolbar(board: CanvasBoard) -> some ToolbarContent {
        Group {
            ToolbarItem(placement: .principal) {
                Text(board.name)
                    .font(.headline)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    duplicateBoard(board)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Duplicate board")

                Button {
                    deleteBoard(board)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete board")
            }
        }
    }

    // MARK: - Markup lifecycle

    private func loadMarkup(for board: CanvasBoard?) {
        // PLACEHOLDER: PaperKit markup loading is disabled while the live view
        // embedding is investigated. Keep `paperMarkup` nil so the placeholder
        // stays visible and no PaperKit objects are instantiated.
        paperMarkup = nil
    }

    private func persistCurrentMarkup() async {
        guard var board, let markup = paperMarkup else { return }
        do {
            let data = try await markup.dataRepresentation()
            board.markupData = data
            try store.save(board)
        } catch {
            self.error = "Failed to save markup: \(error.localizedDescription)"
        }
    }

    private func defaultCanvasBounds() -> CGRect {
        // Use a fixed, reasonable page size. PaperKit renders the page at the
        // markup bounds, so a 10 000×10 000 rect would stress the renderer.
        CGRect(x: 0, y: 0, width: 1_600, height: 1_200)
    }

    // MARK: - Board actions

    private func duplicateBoard(_ board: CanvasBoard) {
        let copy = store.duplicate(board)
        self.board = copy
        loadMarkup(for: copy)
    }

    private func deleteBoard(_ board: CanvasBoard) {
        store.delete(board.id)
        if self.board?.id == board.id {
            self.board = nil
            self.paperMarkup = nil
        }
    }

    private func deleteBoardItem(_ board: CanvasBoard) {
        store.delete(board.id)
        if self.board?.id == board.id {
            self.board = nil
            self.paperMarkup = nil
        }
    }
}

// MARK: - PaperKit canvas wrapper

@available(macOS 26.0, *)
struct PaperCanvasView: NSViewControllerRepresentable {
    let markup: PaperMarkup

    func makeNSViewController(context: Context) -> PaperCanvasContainerViewController {
        let controller = PaperCanvasContainerViewController(markup: markup)
        return controller
    }

    func updateNSViewController(_ nsViewController: PaperCanvasContainerViewController, context: Context) {
        nsViewController.markup = markup
    }
}

@available(macOS 26.0, *)
final class PaperCanvasContainerViewController: NSViewController {
    var markup: PaperMarkup {
        didSet {
            paperViewController?.markup = markup
        }
    }

    private var paperViewController: PaperMarkupViewController?
    private var toolbarViewController: MarkupToolbarViewController?

    init(markup: PaperMarkup) {
        self.markup = markup
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let paperVC = PaperMarkupViewController(markup: markup, supportedFeatureSet: .latest)
        self.paperViewController = paperVC

        let toolbarVC = MarkupToolbarViewController(supportedFeatureSet: .latest)
        toolbarVC.delegate = paperVC
        self.toolbarViewController = toolbarVC

        addChild(paperVC)
        addChild(toolbarVC)
        view.addSubview(paperVC.view)
        view.addSubview(toolbarVC.view)

        paperVC.view.translatesAutoresizingMaskIntoConstraints = false
        toolbarVC.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            toolbarVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            toolbarVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            paperVC.view.topAnchor.constraint(equalTo: toolbarVC.view.bottomAnchor),
            paperVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paperVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paperVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

    }
}

#Preview {
    if #available(macOS 26.0, *) {
        CanvasView()
            .environment(CanvasStore())
    } else {
        CanvasFallbackView()
    }
}
