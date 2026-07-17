import XCTest
@testable import SwiftMaestro

@MainActor
final class KanbanStoreTests: XCTestCase {

    private var store: KanbanStore!
    private let testBoardName = "Test Board"

    override func setUp() {
        super.setUp()
        store = KanbanStore()
        // Start each test with no boards.
        for board in store.boards {
            store.delete(board.id)
        }
    }

    override func tearDown() {
        for board in store.boards {
            store.delete(board.id)
        }
        store = nil
        super.tearDown()
    }

    // MARK: - Board CRUD

    func testCreateBoardAddsDefaultColumns() {
        let board = store.createBoard(name: testBoardName)

        XCTAssertEqual(board.name, testBoardName)
        XCTAssertEqual(board.columns.count, 4)
        XCTAssertEqual(board.columns[0].title, "Backlog")
        XCTAssertEqual(board.columns[1].title, "To Do")
        XCTAssertEqual(board.columns[2].title, "In Progress")
        XCTAssertEqual(board.columns[3].title, "Done")
    }

    func testCreateBoardPersists() {
        let board = store.createBoard(name: testBoardName)

        let freshStore = KanbanStore()
        XCTAssertTrue(freshStore.boards.contains { $0.id == board.id && $0.name == testBoardName })
    }

    func testDeleteBoard() {
        let board = store.createBoard(name: testBoardName)
        store.delete(board.id)

        XCTAssertFalse(store.boards.contains { $0.id == board.id })
    }

    func testDuplicateBoard() {
        let board = store.createBoard(name: testBoardName)
        let copy = store.duplicate(board)

        XCTAssertEqual(copy.name, "\(testBoardName) Copy")
        XCTAssertNotEqual(copy.id, board.id)
        XCTAssertEqual(copy.columns.count, board.columns.count)
    }

    // MARK: - Column helpers

    func testAddColumn() {
        let board = store.createBoard(name: testBoardName)
        store.addColumn(to: board.id, title: "Review")

        let updated = store.boards.first { $0.id == board.id }
        XCTAssertEqual(updated?.columns.count, 5)
        XCTAssertTrue(updated?.columns.contains { $0.title == "Review" } ?? false)
    }

    func testDeleteColumn() {
        let board = store.createBoard(name: testBoardName)
        let firstColumnId = board.columns[0].id
        store.deleteColumn(firstColumnId, from: board.id)

        let updated = store.boards.first { $0.id == board.id }
        XCTAssertEqual(updated?.columns.count, 3)
        XCTAssertFalse(updated?.columns.contains { $0.id == firstColumnId } ?? true)
    }

    // MARK: - Card helpers

    func testAddCard() {
        let board = store.createBoard(name: testBoardName)
        let columnId = board.columns[0].id
        let card = KanbanCard(title: "Task A", priority: .high)
        store.addCard(card, toColumn: columnId, in: board.id)

        let updated = store.boards.first { $0.id == board.id }
        XCTAssertEqual(updated?.columns[0].cards.count, 1)
        XCTAssertEqual(updated?.columns[0].cards.first?.title, "Task A")
        XCTAssertEqual(updated?.columns[0].cards.first?.priority, .high)
    }

    func testUpdateCard() {
        let board = store.createBoard(name: testBoardName)
        let columnId = board.columns[0].id
        let card = KanbanCard(title: "Task A")
        store.addCard(card, toColumn: columnId, in: board.id)

        var updatedCard = card
        updatedCard.title = "Task A Updated"
        updatedCard.priority = .urgent
        store.updateCard(updatedCard, in: board.id)

        let updated = store.boards.first { $0.id == board.id }
        XCTAssertEqual(updated?.columns[0].cards.first?.title, "Task A Updated")
        XCTAssertEqual(updated?.columns[0].cards.first?.priority, .urgent)
    }

    func testDeleteCard() {
        let board = store.createBoard(name: testBoardName)
        let columnId = board.columns[0].id
        let card = KanbanCard(title: "Task A")
        store.addCard(card, toColumn: columnId, in: board.id)
        store.deleteCard(card.id, from: board.id)

        let updated = store.boards.first { $0.id == board.id }
        XCTAssertTrue(updated?.columns[0].cards.isEmpty ?? false)
    }

    func testMoveCardBetweenColumns() {
        let board = store.createBoard(name: testBoardName)
        let sourceColumnId = board.columns[0].id
        let targetColumnId = board.columns[1].id
        let card = KanbanCard(title: "Move Me")
        store.addCard(card, toColumn: sourceColumnId, in: board.id)

        store.moveCard(card.id, toColumn: targetColumnId, toIndex: 0, in: board.id)

        let updated = store.boards.first { $0.id == board.id }
        XCTAssertTrue(updated?.columns[0].cards.isEmpty ?? false)
        XCTAssertEqual(updated?.columns[1].cards.count, 1)
        XCTAssertEqual(updated?.columns[1].cards.first?.title, "Move Me")
    }

    func testMoveCardPreservesSourceWhenTargetUnknown() {
        let board = store.createBoard(name: testBoardName)
        let sourceColumnId = board.columns[0].id
        let card = KanbanCard(title: "Stay")
        store.addCard(card, toColumn: sourceColumnId, in: board.id)

        store.moveCard(UUID(), toColumn: sourceColumnId, toIndex: 0, in: board.id)

        let updated = store.boards.first { $0.id == board.id }
        XCTAssertEqual(updated?.columns[0].cards.count, 1)
    }
}
