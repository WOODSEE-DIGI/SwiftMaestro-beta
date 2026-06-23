import XCTest
@testable import SwiftMaestro

@MainActor
final class AgentMessageStoreTests: XCTestCase {

    private var store: AgentMessageStore!
    private var recipientId: UUID!
    private var senderId: UUID!

    override func setUp() {
        super.setUp()
        store = AgentMessageStore()
        recipientId = UUID()
        senderId = UUID()
        store.clear(for: recipientId)
    }

    override func tearDown() {
        store.clear(for: recipientId)
        super.tearDown()
    }

    // MARK: - Send

    func testSendMessage() {
        let msg = store.send(
            to: recipientId, fromName: "Navigator", fromAgentId: senderId.uuidString,
            subject: "Status check", body: "Please confirm you received this.")

        XCTAssertEqual(msg.fromName, "Navigator")
        XCTAssertEqual(msg.subject, "Status check")
        XCTAssertEqual(msg.body, "Please confirm you received this.")
        XCTAssertFalse(msg.read)
    }

    func testSendTrimsSubject() {
        let msg = store.send(
            to: recipientId, fromName: "Test", fromAgentId: nil,
            subject: "  Padded Subject  ", body: "body")

        XCTAssertEqual(msg.subject, "Padded Subject")
    }

    func testSendDefaultsSubjectWhenEmpty() {
        let msg = store.send(
            to: recipientId, fromName: "Test", fromAgentId: nil,
            subject: "", body: "body")

        // The store stores empty string as-is; the "(no subject)" default
        // is applied by MaestroTools.sendAgentMessage, not the store itself.
        XCTAssertEqual(msg.subject, "")
    }

    // MARK: - Inbox

    func testInboxReturnsMessages() {
        store.send(
            to: recipientId, fromName: "A", fromAgentId: nil,
            subject: "S1", body: "B1")
        store.send(
            to: recipientId, fromName: "B", fromAgentId: nil,
            subject: "S2", body: "B2")

        let inbox = store.inbox(for: recipientId)
        XCTAssertEqual(inbox.count, 2)
        XCTAssertEqual(inbox[0].fromName, "A")
        XCTAssertEqual(inbox[1].fromName, "B")
    }

    func testInboxEmpty() {
        let inbox = store.inbox(for: recipientId)
        XCTAssertTrue(inbox.isEmpty)
    }

    func testInboxOrdering() {
        store.send(to: recipientId, fromName: "First", fromAgentId: nil,
                   subject: "S", body: "B")
        store.send(to: recipientId, fromName: "Second", fromAgentId: nil,
                   subject: "S", body: "B")

        let inbox = store.inbox(for: recipientId)
        XCTAssertEqual(inbox[0].fromName, "First")
        XCTAssertEqual(inbox[1].fromName, "Second")
    }

    // MARK: - Unread Count

    func testUnreadCount() {
        XCTAssertEqual(store.unreadCount(for: recipientId), 0)

        store.send(to: recipientId, fromName: "A", fromAgentId: nil,
                   subject: "S", body: "B")
        XCTAssertEqual(store.unreadCount(for: recipientId), 1)

        store.send(to: recipientId, fromName: "B", fromAgentId: nil,
                   subject: "S", body: "B")
        XCTAssertEqual(store.unreadCount(for: recipientId), 2)
    }

    func testUnreadCountAfterMarkRead() {
        store.send(to: recipientId, fromName: "A", fromAgentId: nil,
                   subject: "S", body: "B")
        store.send(to: recipientId, fromName: "B", fromAgentId: nil,
                   subject: "S", body: "B")

        store.markAllRead(for: recipientId)
        XCTAssertEqual(store.unreadCount(for: recipientId), 0)
    }

    // MARK: - Mark All Read

    func testMarkAllRead() {
        store.send(to: recipientId, fromName: "A", fromAgentId: nil,
                   subject: "S", body: "B")
        store.send(to: recipientId, fromName: "B", fromAgentId: nil,
                   subject: "S", body: "B")

        store.markAllRead(for: recipientId)

        let inbox = store.inbox(for: recipientId)
        XCTAssertTrue(inbox.allSatisfy { $0.read })
    }

    func testMarkAllReadNoopWhenAllRead() {
        store.send(to: recipientId, fromName: "A", fromAgentId: nil,
                   subject: "S", body: "B")
        store.markAllRead(for: recipientId)

        // Should not throw or duplicate
        store.markAllRead(for: recipientId)
        let inbox = store.inbox(for: recipientId)
        XCTAssertEqual(inbox.count, 1)
    }

    // MARK: - Clear

    func testClearRemovesAll() {
        store.send(to: recipientId, fromName: "A", fromAgentId: nil,
                   subject: "S", body: "B")
        store.clear(for: recipientId)

        XCTAssertTrue(store.inbox(for: recipientId).isEmpty)
    }

    // MARK: - Agent isolation

    func testDifferentAgentsHaveSeparateInboxes() {
        let otherId = UUID()
        store.clear(for: otherId)

        store.send(to: recipientId, fromName: "For me", fromAgentId: nil,
                   subject: "S", body: "B")
        store.send(to: otherId, fromName: "For other", fromAgentId: nil,
                   subject: "S", body: "B")

        XCTAssertEqual(store.inbox(for: recipientId).count, 1)
        XCTAssertEqual(store.inbox(for: otherId).count, 1)
        XCTAssertEqual(store.inbox(for: recipientId)[0].fromName, "For me")
        XCTAssertEqual(store.inbox(for: otherId)[0].fromName, "For other")

        store.clear(for: otherId)
    }

    // MARK: - Persistence

    func testPersistenceAcrossInstances() {
        store.send(to: recipientId, fromName: "Persistent", fromAgentId: nil,
                   subject: "S", body: "B")

        let store2 = AgentMessageStore()
        let inbox = store2.inbox(for: recipientId)

        XCTAssertEqual(inbox.count, 1)
        XCTAssertEqual(inbox[0].fromName, "Persistent")
    }
}
