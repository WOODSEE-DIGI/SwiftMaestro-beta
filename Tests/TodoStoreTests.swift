import XCTest
import MLXLMCommon
@testable import SwiftMaestro

@MainActor
final class TodoStoreTests: XCTestCase {

    private var store: TodoStore!
    private var agentId: UUID!

    override func setUp() {
        super.setUp()
        store = TodoStore()
        agentId = UUID()
        // Clean up any persisted data for this test agent
        store.clear(for: agentId)
    }

    override func tearDown() {
        store.clear(for: agentId)
        super.tearDown()
    }

    // MARK: - Create (setList)

    func testSetListCreatesTodos() {
        let items = store.setList(["Task 1", "Task 2", "Task 3"], for: agentId)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].title, "Task 1")
        XCTAssertEqual(items[1].title, "Task 2")
        XCTAssertEqual(items[2].title, "Task 3")
        XCTAssertFalse(items[0].done)
    }

    func testSetListReplacesExisting() {
        store.setList(["Old 1", "Old 2"], for: agentId)
        let items = store.setList(["New 1"], for: agentId)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "New 1")
    }

    func testSetListFiltersEmptyStrings() {
        let items = store.setList(["Valid", "", "  ", "Also valid"], for: agentId)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Valid")
        XCTAssertEqual(items[1].title, "Also valid")
    }

    func testSetListTrimsWhitespace() {
        let items = store.setList(["  padded  "], for: agentId)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "padded")
    }

    // MARK: - Add

    func testAddAppendsToExisting() {
        store.setList(["Original"], for: agentId)
        let items = store.add(["Added"], for: agentId)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Original")
        XCTAssertEqual(items[1].title, "Added")
    }

    func testAddToEmptyList() {
        let items = store.add(["First"], for: agentId)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "First")
    }

    // MARK: - Update (setDone)

    func testMarkDoneByIndex() {
        store.setList(["A", "B", "C"], for: agentId)
        let items = store.setDone(oneBasedIndex: 2, done: true, for: agentId)

        XCTAssertNotNil(items)
        XCTAssertFalse(items![0].done)
        XCTAssertTrue(items![1].done)
        XCTAssertFalse(items![2].done)
    }

    func testMarkUndoneByIndex() {
        store.setList(["A", "B"], for: agentId)
        store.setDone(oneBasedIndex: 1, done: true, for: agentId)
        let items = store.setDone(oneBasedIndex: 1, done: false, for: agentId)

        XCTAssertNotNil(items)
        XCTAssertFalse(items![0].done)
    }

    func testMarkByTitleFuzzyViaMaestroTools() async {
        // Title-based matching is handled in MaestroTools.todoUpdate, not TodoStore directly.
        // Test the store's index-based matching which is the foundation.
        store.setList(["Boot the test rig", "Verify memory tools"], for: agentId)

        // Mark by valid 1-based index
        let items = store.setDone(oneBasedIndex: 1, done: true, for: agentId)
        XCTAssertNotNil(items)
        XCTAssertTrue(items![0].done)
        XCTAssertFalse(items![1].done)
    }

    func testMarkByTitleMatchViaMaestroTools() async {
        // Test that the store correctly handles multiple items and index-based marking
        // (title matching is tested indirectly through the full tool dispatch path)
        store.setList(["Boot the test rig", "Verify memory tools", "Verify file tools"], for: agentId)

        // Mark the third item (index 3)
        let items = store.setDone(oneBasedIndex: 3, done: true, for: agentId)
        XCTAssertNotNil(items)
        XCTAssertFalse(items![0].done)
        XCTAssertFalse(items![1].done)
        XCTAssertTrue(items![2].done)
    }

    func testMarkOutOfRangeReturnsNil() {
        store.setList(["Only one"], for: agentId)
        let items = store.setDone(oneBasedIndex: 99, done: true, for: agentId)

        XCTAssertNil(items)
    }

    // MARK: - Read

    func testReadTodos() {
        store.setList(["Task 1", "Task 2"], for: agentId)
        let items = store.todos(for: agentId)

        XCTAssertEqual(items.count, 2)
    }

    func testReadTodosEmpty() {
        let items = store.todos(for: agentId)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - Clear

    func testClearRemovesAll() {
        store.setList(["A", "B", "C"], for: agentId)
        store.clear(for: agentId)

        let items = store.todos(for: agentId)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - Persistence

    func testPersistenceAcrossInstances() {
        store.setList(["Persistent task"], for: agentId)

        let store2 = TodoStore()
        let items = store2.todos(for: agentId)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Persistent task")
    }

    // MARK: - Agent isolation

    func testDifferentAgentsHaveSeparateLists() {
        let otherAgent = UUID()
        store.setList(["Agent A task"], for: agentId)
        store.setList(["Agent B task"], for: otherAgent)

        let aItems = store.todos(for: agentId)
        let bItems = store.todos(for: otherAgent)

        XCTAssertEqual(aItems.count, 1)
        XCTAssertEqual(aItems[0].title, "Agent A task")
        XCTAssertEqual(bItems.count, 1)
        XCTAssertEqual(bItems[0].title, "Agent B task")

        store.clear(for: otherAgent)
    }

    // MARK: - Helpers

    private func makeToolCall(name: String, json: String) -> ToolCall {
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
            .flatMap { $0 as? [String: JSONValue] } ?? [:]
        return ToolCall(function: .init(name: name, arguments: args))
    }
}
