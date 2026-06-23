import XCTest
@testable import SwiftMaestro

@MainActor
final class WorkspaceStoreTests: XCTestCase {

    private var store: WorkspaceStore!
    private var createdProjectIds: [UUID] = []
    private var createdAgentIds: [UUID] = []

    override func setUp() {
        super.setUp()
        store = WorkspaceStore()
        createdProjectIds = []
        createdAgentIds = []
    }

    override func tearDown() {
        // Clean up created agents and projects
        for agentId in createdAgentIds {
            store.archiveAgent(id: agentId)
        }
        // Projects are auto-pruned when last agent is archived;
        // any remaining test projects will be cleaned up on next workspace.json load.
        super.tearDown()
    }

    // MARK: - Navigator

    func testNavigatorAlwaysExists() {
        let nav = store.navigator
        XCTAssertEqual(nav.kind, .navigator)
        XCTAssertEqual(nav.name, "Navigator")
    }

    // MARK: - Ensure Project

    func testEnsureProjectCreatesNew() {
        let project = store.ensureProject(named: "TestLab")
        createdProjectIds.append(project.id)

        XCTAssertEqual(project.name, "TestLab")
        XCTAssertTrue(store.projects.contains { $0.name == "TestLab" })
    }

    func testEnsureProjectReturnsExisting() {
        let p1 = store.ensureProject(named: "Existing")
        createdProjectIds.append(p1.id)
        let p2 = store.ensureProject(named: "Existing")

        XCTAssertEqual(p1.id, p2.id)
        // Should not create a duplicate
        XCTAssertEqual(store.projects.filter { $0.name == "Existing" }.count, 1)
    }

    // MARK: - Create Agent

    func testCreateProjectAgent() {
        let project = store.ensureProject(named: "AgentTest")
        createdProjectIds.append(project.id)

        let agent = store.createAgent(name: "Scribe", in: project)
        createdAgentIds.append(agent.id)

        XCTAssertEqual(agent.name, "Scribe")
        XCTAssertEqual(agent.kind, .project)
        XCTAssertEqual(agent.projectId, project.id)
    }

    func testCreateProjectAgentViaConvenience() {
        let agent = store.createProjectAgent(projectName: "ConvenienceTest", agentName: "Inspector")
        createdAgentIds.append(agent.id)

        XCTAssertEqual(agent.name, "Inspector")
        XCTAssertTrue(store.projects.contains { $0.name == "ConvenienceTest" })
    }

    func testCreateProjectAgentReturnsExistingIfSameName() {
        let agent1 = store.createProjectAgent(projectName: "Dedup", agentName: "Scribe")
        let agent2 = store.createProjectAgent(projectName: "Dedup", agentName: "Scribe")
        createdAgentIds.append(agent1.id)

        XCTAssertEqual(agent1.id, agent2.id)
    }

    // MARK: - Query Agents

    func testProjectAgents() {
        let project = store.ensureProject(named: "QueryTest")
        createdProjectIds.append(project.id)

        let a1 = store.createAgent(name: "Alpha", in: project)
        let a2 = store.createAgent(name: "Beta", in: project)
        createdAgentIds.append(contentsOf: [a1.id, a2.id])

        let agents = store.projectAgents(in: project.id)
        XCTAssertEqual(agents.count, 2)
        XCTAssertTrue(agents.contains { $0.name == "Alpha" })
        XCTAssertTrue(agents.contains { $0.name == "Beta" })
    }

    func testProjectNameForAgent() {
        let project = store.ensureProject(named: "NameTest")
        createdProjectIds.append(project.id)

        let agent = store.createAgent(name: "Named", in: project)
        createdAgentIds.append(agent.id)

        XCTAssertEqual(store.projectName(for: agent), "NameTest")
    }

    func testProjectNameForNavigator() {
        let nav = store.navigator
        XCTAssertNil(store.projectName(for: nav))
    }

    func testFindAgentByName() {
        let project = store.ensureProject(named: "FindTest")
        createdProjectIds.append(project.id)

        let agent = store.createAgent(name: "Findable", in: project)
        createdAgentIds.append(agent.id)

        let found = store.findAgent(projectName: "FindTest", agentName: "Findable")
        XCTAssertNotNil(found)
        XCTAssertEqual(found!.id, agent.id)
    }

    func testFindAgentCaseInsensitive() {
        let project = store.ensureProject(named: "CaseTest")
        createdProjectIds.append(project.id)

        let agent = store.createAgent(name: "CaseAgent", in: project)
        createdAgentIds.append(agent.id)

        let found = store.findAgent(projectName: "CaseTest", agentName: "caseagent")
        XCTAssertNotNil(found)
    }

    func testFindAgentReturnsNilForMissing() {
        let found = store.findAgent(projectName: "NoProject", agentName: "NoAgent")
        XCTAssertNil(found)
    }

    // MARK: - Archive Agent

    func testArchiveAgent() {
        let project = store.ensureProject(named: "ArchiveTest")
        createdProjectIds.append(project.id)

        let agent = store.createAgent(name: "Archivable", in: project)
        store.archiveAgent(id: agent.id)

        XCTAssertNil(store.agent(id: agent.id))
    }

    func testArchivePrunesEmptyProject() {
        let project = store.ensureProject(named: "PruneTest")
        let agent = store.createAgent(name: "Only", in: project)

        store.archiveAgent(id: agent.id)

        // Project should be pruned since it has no agents
        XCTAssertFalse(store.projects.contains { $0.name == "PruneTest" })
    }

    func testArchiveKeepsNonEmptyProject() {
        let project = store.ensureProject(named: "KeepTest")
        createdProjectIds.append(project.id)

        let a1 = store.createAgent(name: "Keep", in: project)
        let a2 = store.createAgent(name: "Also", in: project)
        createdAgentIds.append(a2.id)

        store.archiveAgent(id: a1.id)

        // Project should still exist
        XCTAssertTrue(store.projects.contains { $0.name == "KeepTest" })
    }

    // MARK: - Rename

    func testRenameProject() {
        let project = store.ensureProject(named: "OldName")
        createdProjectIds.append(project.id)

        store.renameProject(id: project.id, to: "NewName")

        XCTAssertEqual(store.projects.first { $0.id == project.id }?.name, "NewName")
    }

    func testRenameAgent() {
        let project = store.ensureProject(named: "RenameTest")
        createdProjectIds.append(project.id)

        let agent = store.createAgent(name: "OldAgent", in: project)
        createdAgentIds.append(agent.id)

        store.renameAgent(id: agent.id, to: "NewAgent")

        XCTAssertEqual(store.agent(id: agent.id)?.name, "NewAgent")
    }

    // MARK: - Set Model

    func testSetModel() {
        let project = store.ensureProject(named: "ModelTest")
        createdProjectIds.append(project.id)

        let agent = store.createAgent(name: "ModelAgent", in: project)
        createdAgentIds.append(agent.id)

        store.setModel("local-qwen3.5-122b", for: agent.id)
        XCTAssertEqual(store.agent(id: agent.id)?.modelID, "local-qwen3.5-122b")
    }

    func testClearModel() {
        let project = store.ensureProject(named: "ClearModelTest")
        createdProjectIds.append(project.id)

        let agent = store.createAgent(name: "ClearModel", in: project)
        createdAgentIds.append(agent.id)

        store.setModel("some-model", for: agent.id)
        store.setModel(nil, for: agent.id)
        XCTAssertNil(store.agent(id: agent.id)?.modelID)
    }
}
