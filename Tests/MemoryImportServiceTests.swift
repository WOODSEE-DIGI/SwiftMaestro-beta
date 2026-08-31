import XCTest
@testable import SwiftMaestro

final class MemoryImportServiceTests: XCTestCase {

    private var tempMemoryRoot: URL!
    private var sourceFolder: URL!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        tempMemoryRoot = base.appendingPathComponent("memory", isDirectory: true)
        sourceFolder = base.appendingPathComponent("source", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: sourceFolder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: tempMemoryRoot.deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: - Folder import

    func testFolderImportPreservesStructureIntoShares() async throws {
        // Build a small tree: root/a.txt, root/nested/b.txt, plus ignored junk.
        try "alpha".write(
            to: sourceFolder.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8)
        let nested = sourceFolder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "beta".write(
            to: nested.appendingPathComponent("b.txt"),
            atomically: true, encoding: .utf8)
        try ".DS_Store".write(
            to: sourceFolder.appendingPathComponent(".DS_Store"),
            atomically: true, encoding: .utf8)
        try "lock".write(
            to: sourceFolder.appendingPathComponent("file.lock"),
            atomically: true, encoding: .utf8)

        let service = MemoryImportService(basePath: tempMemoryRoot)
        let written = try await service.importFolder(
            at: sourceFolder, destination: .knowledge)

        // Hidden + .lock files are skipped; only the two real files import.
        XCTAssertEqual(written, 2)

        let knowledgeBase = tempMemoryRoot.appendingPathComponent("knowledge/imports")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: knowledgeBase.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: knowledgeBase.appendingPathComponent("nested/b.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: knowledgeBase.appendingPathComponent(".DS_Store").path))
    }

    func testFolderImportSkipsHiddenAndLockFiles() async throws {
        try "content".write(
            to: sourceFolder.appendingPathComponent("doc.md"),
            atomically: true, encoding: .utf8)
        try "junk".write(
            to: sourceFolder.appendingPathComponent(".hidden"),
            atomically: true, encoding: .utf8)

        let service = MemoryImportService(basePath: tempMemoryRoot)
        let written = try await service.importFolder(
            at: sourceFolder, destination: .knowledge)

        XCTAssertEqual(written, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempMemoryRoot.appendingPathComponent("knowledge/imports/doc.md").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempMemoryRoot.appendingPathComponent("knowledge/imports/.hidden").path))
    }

    // MARK: - Single file & data import

    func testSingleFileImport() async throws {
        let fileURL = sourceFolder.appendingPathComponent("note.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let service = MemoryImportService(basePath: tempMemoryRoot)
        let written = try await service.importFile(
            at: fileURL, destination: .knowledge, subfolder: "chat/helper")

        XCTAssertEqual(written, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempMemoryRoot
                .appendingPathComponent("knowledge/imports/chat/helper/note.txt").path))
    }

    func testDataImportWritesBytes() async throws {
        let bytes = Data("payload".utf8)
        let service = MemoryImportService(basePath: tempMemoryRoot)
        let written = try await service.importData(
            bytes, filename: "image.png", destination: .knowledge)

        XCTAssertEqual(written, 1)
        let target = tempMemoryRoot.appendingPathComponent("knowledge/imports/image.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testProjectDestinationScopesUnderContext() async throws {
        try "note".write(
            to: sourceFolder.appendingPathComponent("n.txt"),
            atomically: true, encoding: .utf8)

        let service = MemoryImportService(basePath: tempMemoryRoot)
        _ = try await service.importFolder(
            at: sourceFolder, destination: .project("my-project"))

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempMemoryRoot
                .appendingPathComponent("context/imports/my-project/n.txt").path))
    }

    // MARK: - Counting

    func testCountFilesReflectsImport() async throws {
        try "x".write(
            to: sourceFolder.appendingPathComponent("one.txt"),
            atomically: true, encoding: .utf8)
        try "y".write(
            to: sourceFolder.appendingPathComponent("two.txt"),
            atomically: true, encoding: .utf8)

        let service = MemoryImportService(basePath: tempMemoryRoot)
        let countBefore = await service.countFiles(in: .knowledge)
        XCTAssertEqual(countBefore, 0)

        _ = try await service.importFolder(at: sourceFolder, destination: .knowledge)
        let countAfter = await service.countFiles(in: .knowledge)
        XCTAssertEqual(countAfter, 2)
    }

    // MARK: - Sanitization

    func testSanitizeComponentStripsSeparators() {
        XCTAssertEqual(MemoryImportService.sanitizeComponent("a/b:c\\d"), "a_b_c_d")
        XCTAssertEqual(MemoryImportService.sanitizeComponent("  x  "), "x")
        XCTAssertEqual(MemoryImportService.sanitizeComponent("   "), "import")
    }
}
