import XCTest
@testable import SwiftMaestro

/// Runtime smoke tests for the GRDB SQLite FTS5 `MemorySearchEngine`.
///
/// The first four tests exercise the engine against a small synthetic memory
/// tree with a temporary index database, so they are fast, deterministic and
/// side-effect free. The final test validates the engine end-to-end against the
/// *real* resolved AI Memory root (read-only on the source, ephemeral index),
/// which is the exact code path the `memory_search` tool uses at runtime.
final class MemorySearchEngineTests: XCTestCase {

    private var tempRoot: URL!
    private var tempIndex: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSE-memory-\(UUID().uuidString)", isDirectory: true)
        tempIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSE-index-\(UUID().uuidString).sqlite")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        try? FileManager.default.removeItem(at: tempIndex)
        super.tearDown()
    }

    private func write(_ content: String, relativePath: String) throws {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: url)
    }

    private func makeEngine() throws -> MemorySearchEngine {
        try MemorySearchEngine(memoryRoot: tempRoot, indexURL: tempIndex)
    }

    // MARK: - Indexing

    func testIndexesFilesAndSkipsBinary() throws {
        try write("The swift fox jumps over the lazy dog.", relativePath: "knowledge/animals.md")
        try write("Swift concurrency notes.", relativePath: "knowledge/swift.notes.md")
        try write("Deep context about the project.", relativePath: "context/session.md")
        try write("A tiny conversation log.", relativePath: "conversations/today.txt")
        try write("A skill for the agent.", relativePath: "skills/demo.md")
        try write("binary payload", relativePath: "knowledge/asset.dat") // must be skipped

        let engine = try makeEngine()
        try engine.reindex()

        XCTAssertEqual(engine.indexedCount, 5, "should index 5 text files and skip the .dat")
    }

    // MARK: - Search (FTS path)

    func testFTSSearchFindsMatchesAndProducesSnippet() throws {
        try write(
            "The team investigated swift networking over the weekend and logged every step.",
            relativePath: "knowledge/networking.md")
        try write(
            "Unrelated note about gardening.",
            relativePath: "knowledge/garden.md")

        let engine = try makeEngine()
        let results = engine.searchWithReindex("networking", limit: 10)

        XCTAssertFalse(results.isEmpty, "FTS should find the networking note")
        guard let hit = results.first(where: { $0.path == "knowledge/networking.md" }) else {
            return XCTFail("expected knowledge/networking.md in results")
        }
        XCTAssertEqual(hit.kind, "knowledge")
        XCTAssertTrue(
            hit.snippet.lowercased().contains("networking"),
            "snippet should wrap the matched term, got: \(hit.snippet)")
    }

    func testSearchKindsMatchTopLevelFolder() throws {
        try write("A conversation about memes.", relativePath: "conversations/daily.txt")
        try write("A skill about memory.", relativePath: "skills/memory.md")

        let engine = try makeEngine()
        try engine.reindex()

        let conv = try engine.search("memes", limit: 5).first
        XCTAssertEqual(conv?.path, "conversations/daily.txt")
        XCTAssertEqual(conv?.kind, "conversations")

        let skill = try engine.search("memory", limit: 5).first
        XCTAssertEqual(skill?.path, "skills/memory.md")
        XCTAssertEqual(skill?.kind, "skills")
    }

    // MARK: - Query safety

    func testReindexIsIncremental() throws {
        try write("alpha beta", relativePath: "knowledge/one.md")
        let engine = try makeEngine()
        try engine.reindex()
        XCTAssertEqual(engine.indexedCount, 1)

        try write("alpha beta gamma delta", relativePath: "knowledge/one.md")
        try write("brand new", relativePath: "knowledge/two.md")
        try engine.reindex()
        XCTAssertEqual(engine.indexedCount, 2, "second pass should wake up the new file")
        XCTAssertNotNil(try engine.search("gamma", limit: 5).first)
    }

    func testEmptyAndWhitespaceQueryReturnsNothing() throws {
        try write("alpha beta", relativePath: "knowledge/one.md")
        let engine = try makeEngine()
        let results = try engine.search("   ")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Real store smoke test (read-only source, ephemeral index)

    /// End-to-end validation against the actual resolved AI Memory root: the
    /// engine must open, reindex (incremental, source untouched), and return a
    /// match + snippet for a term we know exists in the shared memory store.
    ///
    /// Because the index is written to a temp URL, this never mutates the real
    /// `memory-index.sqlite` nor the memory source files.
    func testEndToEndAgainstRealMemoryStore() throws {
        guard let memoryRoot = MemorySearchEngine.resolveMemoryRootOpt() else {
            throw XCTSkip("resolved AI Memory root does not exist on this machine")
        }
        let realIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSE-realmem-\(UUID().uuidString).sqlite")

        let engine = try MemorySearchEngine(memoryRoot: memoryRoot, indexURL: realIndex)
        let count = engine.indexedCount
        XCTAssertGreaterThanOrEqual(count, 0)

        // Bring the index up to date against the real store (read-only on the
        // source; index is ephemeral). Confirm the walk actually found files.
        try engine.reindex()
        let indexed = engine.indexedCount
        XCTAssertGreaterThan(indexed, 0, "real store reindex should index files, got \(indexed)")

        // Search for a very common term that is certain to appear somewhere in
        // the shared memory store (project name + the term "memory").
        let results = engine.searchWithReindex("memory", limit: 10)
        XCTAssertFalse(results.isEmpty, "real store must contain at least one 'memory' hit")
        print("[MemorySearchEngine] real store indexed=\(indexed), 'memory' hits=\(results.count)")
        for r in results.prefix(3) {
            print("  - \(r.kind): \(r.path) :: \(r.snippet.prefix(80))")
        }

        try? FileManager.default.removeItem(at: realIndex)
    }

    // MARK: - MemorySearchService (cooldown/warm path)

    private func makeService(engine: MemorySearchEngine) -> MemorySearchService {
        MemorySearchService(engine: engine)
    }

    func testServiceReturnsNilWhileIndexCold() async throws {
        // New (unindexed) engine over a fresh temp tree => cold index.
        try write("the swift fox", relativePath: "knowledge/one.md")
        let engine = try makeEngine()
        let service = makeService(engine: engine)

        let results = await service.search("swift", limit: 10)
        XCTAssertNil(results, "a cold index must signal 'not ready' (nil) so the caller falls back")
    }

    func testServiceReturnsHitsOnceWarm() async throws {
        try write("the swift fox leaps quickly", relativePath: "knowledge/one.md")
        try write("gardening is calm", relativePath: "knowledge/two.md")

        let engine = try makeEngine()
        try engine.reindex() // warm the index synchronously
        let service = makeService(engine: engine)

        let results = await service.search("swift", limit: 10)
        XCTAssertNotNil(results, "a warm index should return matches")
        XCTAssertEqual(results?.first?.path, "knowledge/one.md")
        XCTAssertEqual(results?.first?.kind, "knowledge")
    }
}

private extension MemorySearchEngine {
    /// Returns the resolved memory root only if the folder actually exists
    /// (the app's own resolution uses `url(forUbiquityContainerIdentifier:)`,
    /// which may return nil in a headless/CI context).
    static func resolveMemoryRootOpt() -> URL? {
        let root = resolveMemoryRoot()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return root
    }
}
