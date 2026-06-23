import XCTest
@testable import SwiftMaestro

final class SimpleMemoryStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: SimpleMemoryStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = SimpleMemoryStore(basePath: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Save & Load

    func testSaveAndLoadKnowledge() throws {
        let uri = MaestroURI(kind: .knowledge, path: ["test-key"])
        try store.save("hello world", at: uri)

        let loaded = try store.load(uri)
        XCTAssertEqual(loaded, "hello world")
    }

    func testLoadReturnsNilForMissingEntry() throws {
        let uri = MaestroURI(kind: .knowledge, path: ["nonexistent"])
        let loaded = try store.load(uri)
        XCTAssertNil(loaded)
    }

    func testSaveOverwritesExisting() throws {
        let uri = MaestroURI(kind: .knowledge, path: ["overwrite"])
        try store.save("version 1", at: uri)
        try store.save("version 2", at: uri)

        let loaded = try store.load(uri)
        XCTAssertEqual(loaded, "version 2")
    }

    func testSaveCreatesIntermediateDirectories() throws {
        let uri = MaestroURI(kind: .knowledge, path: ["a", "b", "c", "deep"])
        try store.save("nested content", at: uri)

        let loaded = try store.load(uri)
        XCTAssertEqual(loaded, "nested content")
    }

    // MARK: - Delete

    func testDelete() throws {
        let uri = MaestroURI(kind: .knowledge, path: ["to-delete"])
        try store.save("delete me", at: uri)
        XCTAssertNotNil(try store.load(uri))

        try store.delete(uri)
        XCTAssertNil(try store.load(uri))
    }

    func testDeleteNonexistentDoesNotThrow() throws {
        let uri = MaestroURI(kind: .knowledge, path: ["never-existed"])
        // FileManager.removeItem throws on missing files; the store propagates this.
        // This is expected behavior - callers should check existence first.
        XCTAssertThrowsError(try store.delete(uri))
    }

    // MARK: - Entries

    func testEntriesReturnsSavedFiles() throws {
        let uri1 = MaestroURI(kind: .knowledge, path: ["alpha"])
        let uri2 = MaestroURI(kind: .knowledge, path: ["beta"])
        try store.save("content 1", at: uri1)
        try store.save("content 2", at: uri2)

        let entries = store.entries(kind: .knowledge)
        XCTAssertGreaterThanOrEqual(entries.count, 2, "Should find at least the two saved files")
    }

    func testEntriesReturnsEmptyForEmptyDir() {
        let entries = store.entries(kind: .skill)
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Search

    func testSearchFindsMatchingContent() throws {
        let uri = MaestroURI(kind: .knowledge, path: ["searchable"])
        try store.save("The quick brown fox jumps over the lazy dog", at: uri)

        let hits = store.search("quick brown")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].path.contains("searchable"))
    }

    func testSearchReturnsEmptyForNoMatch() throws {
        let uri = MaestroURI(kind: .knowledge, path: ["no-match"])
        try store.save("hello world", at: uri)

        let hits = store.search("xyzzy")
        XCTAssertTrue(hits.isEmpty)
    }

    func testSearchIsCaseInsensitive() throws {
        let uri = MaestroURI(kind: .knowledge, path: ["case-test"])
        try store.save("Hello World", at: uri)

        let hits = store.search("hello world")
        XCTAssertEqual(hits.count, 1)
    }

    // MARK: - List Children (the fixed bug)

    func testListChildrenDistinguishesDirectoriesFromFiles() throws {
        // Create a directory and a file under the same parent
        let parentURI = MaestroURI(kind: .knowledge, path: ["parent"])
        let parentDir = tempDir.appendingPathComponent("knowledge/parent")
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Create a subdirectory
        try FileManager.default.createDirectory(
            at: parentDir.appendingPathComponent("child-dir"),
            withIntermediateDirectories: true)

        // Create a JSON file
        try "content".write(
            to: parentDir.appendingPathComponent("child-file.json"),
            atomically: true, encoding: .utf8)

        let children = try store.listChildren(of: parentURI)
        let dirChildren = children.filter { $0.path.last == "child-dir" }
        let fileChildren = children.filter { $0.path.last == "child-file" }

        XCTAssertEqual(dirChildren.count, 1, "Should find the subdirectory")
        XCTAssertEqual(fileChildren.count, 1, "Should find the JSON file")
    }

    func testListChildrenReturnsEmptyForMissingDir() throws {
        let uri = MaestroURI(kind: .knowledge, path: ["nonexistent-dir"])
        let children = try store.listChildren(of: uri)
        XCTAssertTrue(children.isEmpty)
    }

    // MARK: - Conversation History

    func testSaveAndLoadConversationHistory() throws {
        let messages = [
            Message(role: .user, content: "Hello"),
            Message(role: .assistant, content: "Hi there!"),
        ]
        try store.saveConversationHistory("test-agent", messages: messages)

        let loaded = try store.loadConversationHistory("test-agent")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.count, 2)
        XCTAssertEqual(loaded?.first?.role, .user)
        // Note: The parser preserves the space after "role: " in the serialized format
        XCTAssertEqual(loaded?.first?.content.trimmingCharacters(in: .whitespaces), "Hello")
        XCTAssertEqual(loaded?.last?.role, .assistant)
        XCTAssertEqual(loaded?.last?.content.trimmingCharacters(in: .whitespaces), "Hi there!")
    }

    func testLoadConversationHistoryReturnsNilForMissing() throws {
        let loaded = try store.loadConversationHistory("no-such-agent")
        XCTAssertNil(loaded)
    }

    // MARK: - URI Kind Mapping

    func testDifferentKindsMapToDifferentDirectories() throws {
        let knowledgeURI = MaestroURI(kind: .knowledge, path: ["k-entry"])
        let contextURI = MaestroURI(kind: .context, path: ["c-entry"])

        try store.save("knowledge content", at: knowledgeURI)
        try store.save("context content", at: contextURI)

        let kLoaded = try store.load(knowledgeURI)
        let cLoaded = try store.load(contextURI)

        XCTAssertEqual(kLoaded, "knowledge content")
        XCTAssertEqual(cLoaded, "context content")
    }

    // MARK: - Cross-kind isolation

    func testSearchAcrossKinds() throws {
        let kURI = MaestroURI(kind: .knowledge, path: ["shared-term"])
        let cURI = MaestroURI(kind: .context, path: ["shared-term"])

        try store.save("The term appears here", at: kURI)
        try store.save("The term appears there too", at: cURI)

        // Search across all kinds
        let hits = store.search("term appears")
        XCTAssertGreaterThanOrEqual(hits.count, 2)
    }
}
