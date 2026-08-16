import Foundation
import Testing
@testable import SwiftMaestro

/// Round-trip coverage for ChatHistoryStore. Each test uses a random agent UUID
/// so the real chats directory is never polluted, and every test clears up
/// after itself. These tests exist because the store's `try?`-swallowed writes
/// once failed silently for weeks — see the `[PERSIST]` instrumentation.
struct ChatHistoryStoreTests {

    private func makeMessages() -> [Message] {
        [
            Message(role: .user, content: "Hello", timestamp: Date()),
            Message(
                role: .assistant,
                content: "Hi there — how can I help?",
                toolSteps: ["read_file"],
                reasoning: "thinking…",
                reasoningSeconds: 1.25,
                timestamp: Date(),
                modelName: "test-model"),
        ]
    }

    @Test func saveThenLoadRoundTrips() {
        let id = UUID()
        defer { ChatHistoryStore.clear(agentId: id) }

        let messages = makeMessages()
        ChatHistoryStore.save(messages, agentId: id)

        let loaded = ChatHistoryStore.load(agentId: id)
        #expect(loaded != nil)
        #expect(loaded?.count == 2)
        #expect(loaded?.first?.role == .user)
        #expect(loaded?.first?.content == "Hello")
        #expect(loaded?.last?.toolSteps == ["read_file"])
        #expect(loaded?.last?.reasoningSeconds == 1.25)
        #expect(loaded?.last?.modelName == "test-model")
    }

    @Test func saveOverwritesExistingHistory() {
        let id = UUID()
        defer { ChatHistoryStore.clear(agentId: id) }

        ChatHistoryStore.save(makeMessages(), agentId: id)
        ChatHistoryStore.save([Message(role: .user, content: "Only message")], agentId: id)

        let loaded = ChatHistoryStore.load(agentId: id)
        #expect(loaded?.count == 1)
        #expect(loaded?.first?.content == "Only message")
    }

    @Test func clearRemovesPersistedFile() {
        let id = UUID()
        ChatHistoryStore.save(makeMessages(), agentId: id)
        #expect(ChatHistoryStore.load(agentId: id) != nil)

        ChatHistoryStore.clear(agentId: id)
        #expect(ChatHistoryStore.load(agentId: id) == nil)
    }

    @Test func loadMissingAgentReturnsNil() {
        // No file has ever been written for this UUID — must be nil, not a
        // logged error or a crash.
        #expect(ChatHistoryStore.load(agentId: UUID()) == nil)
    }

    @Test func saveEmptyHistoryWritesFile() {
        let id = UUID()
        defer { ChatHistoryStore.clear(agentId: id) }

        ChatHistoryStore.save([], agentId: id)
        let loaded = ChatHistoryStore.load(agentId: id)
        #expect(loaded != nil)
        #expect(loaded?.isEmpty == true)
    }

    @Test func historyWithImageDataRoundTrips() {
        let id = UUID()
        defer { ChatHistoryStore.clear(agentId: id) }

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let messages = [
            Message(role: .user, content: "What is this?", imageData: [png], imagePaths: ["/tmp/x.png"])
        ]
        ChatHistoryStore.save(messages, agentId: id)

        let loaded = ChatHistoryStore.load(agentId: id)
        #expect(loaded?.first?.imageData?.first == png)
        #expect(loaded?.first?.imagePaths == ["/tmp/x.png"])
    }
}
