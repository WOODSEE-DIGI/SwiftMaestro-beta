import XCTest
@testable import SwiftMaestro

@MainActor
final class PlanStoreTests: XCTestCase {

    private var store: PlanStore!
    private var agentId: UUID!

    override func setUp() {
        super.setUp()
        store = PlanStore()
        agentId = UUID()
        store.clear(in: .agent(agentId))
    }

    override func tearDown() {
        store.clear(in: .agent(agentId))
        store.clear(in: .project("TestProject"))
        super.tearDown()
    }

    // MARK: - Create

    func testCreatePlan() {
        let plan = store.create(title: "Test Plan", content: "# Goals\n- Test everything", in: .agent(agentId))

        XCTAssertEqual(plan.title, "Test Plan")
        XCTAssertEqual(plan.content, "# Goals\n- Test everything")
        XCTAssertFalse(plan.title.isEmpty)
    }

    func testCreatePlanAppearsInList() {
        _ = store.create(title: "Visible Plan", content: "body", in: .agent(agentId))
        let plans = store.plans(in: .agent(agentId))

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].title, "Visible Plan")
    }

    func testCreateProjectScopedPlan() {
        let plan = store.create(title: "Project Plan", content: "content", in: .project("TestProject"))

        XCTAssertEqual(plan.title, "Project Plan")
        let plans = store.plans(in: .project("TestProject"))
        XCTAssertEqual(plans.count, 1)
    }

    func testCreatePlanTrimsTitle() {
        let plan = store.create(title: "  Padded Title  ", content: "body", in: .agent(agentId))
        XCTAssertEqual(plan.title, "Padded Title")
    }

    // MARK: - Edit (append, replace, rename)

    func testAppendToPlan() {
        let plan = store.create(title: "Append Test", content: "Original", in: .agent(agentId))
        let updated = store.update(
            id: plan.id, title: nil, content: "Appended text",
            append: true, in: .agent(agentId))

        XCTAssertNotNil(updated)
        XCTAssertEqual(updated!.content, "Original\nAppended text")
    }

    func testReplacePlanContent() {
        let plan = store.create(title: "Replace Test", content: "Old content", in: .agent(agentId))
        let updated = store.update(
            id: plan.id, title: nil, content: "New content",
            append: false, in: .agent(agentId))

        XCTAssertNotNil(updated)
        XCTAssertEqual(updated!.content, "New content")
    }

    func testRenamePlan() {
        let plan = store.create(title: "Old Title", content: "body", in: .agent(agentId))
        let updated = store.update(
            id: plan.id, title: "New Title", content: nil,
            append: false, in: .agent(agentId))

        XCTAssertNotNil(updated)
        XCTAssertEqual(updated!.title, "New Title")
        XCTAssertEqual(updated!.content, "body")
    }

    func testAppendToEmptyContent() {
        let plan = store.create(title: "Empty Plan", content: "", in: .agent(agentId))
        let updated = store.update(
            id: plan.id, title: nil, content: "First content",
            append: true, in: .agent(agentId))

        XCTAssertNotNil(updated)
        XCTAssertEqual(updated!.content, "First content")
    }

    // MARK: - Find

    func testFindById() {
        let plan = store.create(title: "Findable", content: "content", in: .agent(agentId))
        let found = store.find(idOrTitle: plan.id.uuidString, in: .agent(agentId))

        XCTAssertNotNil(found)
        XCTAssertEqual(found!.id, plan.id)
    }

    func testFindByTitle() {
        _ = store.create(title: "My Special Plan", content: "content", in: .agent(agentId))
        let found = store.find(idOrTitle: "Special", in: .agent(agentId))

        XCTAssertNotNil(found)
        XCTAssertEqual(found!.title, "My Special Plan")
    }

    func testFindByTitleIsCaseInsensitive() {
        _ = store.create(title: "Case Test", content: "content", in: .agent(agentId))
        let found = store.find(idOrTitle: "case test", in: .agent(agentId))

        XCTAssertNotNil(found)
    }

    func testFindReturnsNilForNonexistent() {
        let found = store.find(idOrTitle: "no-such-plan", in: .agent(agentId))
        XCTAssertNil(found)
    }

    // MARK: - Delete

    func testDeletePlan() {
        let plan = store.create(title: "To Delete", content: "bye", in: .agent(agentId))
        let deleted = store.delete(id: plan.id, in: .agent(agentId))

        XCTAssertTrue(deleted)
        XCTAssertTrue(store.plans(in: .agent(agentId)).isEmpty)
    }

    func testDeleteNonexistentReturnsFalse() {
        let deleted = store.delete(id: UUID(), in: .agent(agentId))
        XCTAssertFalse(deleted)
    }

    // MARK: - Clear

    func testClearRemovesAll() {
        _ = store.create(title: "A", content: "a", in: .agent(agentId))
        _ = store.create(title: "B", content: "b", in: .agent(agentId))
        store.clear(in: .agent(agentId))

        XCTAssertTrue(store.plans(in: .agent(agentId)).isEmpty)
    }

    // MARK: - Markdown mirror

    func testMarkdownMirrorExists() {
        let plan = store.create(title: "Mirror Test", content: "body", in: .agent(agentId))
        let plansDir = WorkspaceStore.appSupportDir()
            .appendingPathComponent("plans", isDirectory: true)
        let scopeDir = plansDir.appendingPathComponent(agentId.uuidString, isDirectory: true)
        let mdFile = scopeDir.appendingPathComponent("\(plan.id.uuidString).md")

        XCTAssertTrue(FileManager.default.fileExists(atPath: mdFile.path))
    }

    // MARK: - Scope isolation

    func testAgentAndProjectScopesAreIsolated() {
        _ = store.create(title: "Agent Plan", content: "a", in: .agent(agentId))
        _ = store.create(title: "Project Plan", content: "p", in: .project("TestProject"))

        XCTAssertEqual(store.plans(in: .agent(agentId)).count, 1)
        XCTAssertEqual(store.plans(in: .project("TestProject")).count, 1)

        XCTAssertEqual(store.plans(in: .agent(agentId))[0].title, "Agent Plan")
        XCTAssertEqual(store.plans(in: .project("TestProject"))[0].title, "Project Plan")
    }

    // MARK: - Persistence

    func testPersistenceAcrossInstances() {
        let plan = store.create(title: "Persistent", content: "content", in: .agent(agentId))

        let store2 = PlanStore()
        let plans = store2.plans(in: .agent(agentId))

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].title, "Persistent")
        XCTAssertEqual(plans[0].id, plan.id)
    }
}
