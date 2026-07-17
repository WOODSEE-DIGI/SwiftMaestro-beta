import Foundation
import Testing
@testable import SwiftMaestro

@Suite("ChatCompaction")
struct ChatCompactionTests {

    // MARK: - Turn-aware split

    @Test("split never starts the recent tail mid-turn")
    func splitStaysOnTurnBoundaries() {
        // 5 turns, each a user message followed by an assistant reply.
        var messages: [Message] = []
        for i in 0..<5 {
            messages.append(Message(role: .user, content: "user turn \(i) " + String(repeating: "x", count: 200)))
            messages.append(Message(role: .assistant, content: "assistant reply \(i) " + String(repeating: "y", count: 200)))
        }

        guard let result = ChatCompaction.split(messages: messages, keepTokens: 150) else {
            Issue.record("expected a split result")
            return
        }

        // The recent tail must start at a user message, never at an assistant one.
        #expect(messages[result.recentStartIndex].role == .user)
        // There must be something left to summarize.
        #expect(!result.head.isEmpty)
        // The tail must not be the entire conversation (there should be a head).
        #expect(result.recentStartIndex > 0)
    }

    @Test("split keeps at least one whole turn even if it exceeds the budget")
    func splitKeepsAtLeastOneTurn() {
        let messages = [
            Message(role: .user, content: String(repeating: "a", count: 5_000)),
            Message(role: .assistant, content: String(repeating: "b", count: 5_000)),
        ]
        // Budget far smaller than a single turn's size.
        let result = ChatCompaction.split(messages: messages, keepTokens: 10)
        // With only one turn total, there's nothing before it to summarize, so
        // split should report no meaningful head (nil) rather than fragmenting
        // the only turn there is.
        #expect(result == nil)
    }

    @Test("split with multiple turns keeps the most recent whole turns within budget")
    func splitKeepsRecentTurnsWithinBudget() {
        var messages: [Message] = []
        for i in 0..<4 {
            messages.append(Message(role: .user, content: "u\(i)"))
            messages.append(Message(role: .assistant, content: "a\(i)"))
        }
        // Tiny budget: only the very last turn should remain as "recent".
        guard let result = ChatCompaction.split(messages: messages, keepTokens: 1) else {
            Issue.record("expected a split result")
            return
        }
        #expect(result.recentStartIndex == messages.count - 2)
        #expect(messages[result.recentStartIndex].role == .user)
    }

    // MARK: - Per-message content cap

    @Test("serialize truncates oversized message content")
    func serializeCapsLargeContent() {
        let huge = String(repeating: "z", count: ChatCompaction.perMessageMaxChars + 500)
        let message = Message(role: .assistant, content: huge)
        let serialized = ChatCompaction.serialize(message)
        #expect(serialized.count < huge.count)
        #expect(serialized.contains("more characters truncated"))
    }

    @Test("serialize leaves short content untouched")
    func serializeLeavesShortContentAlone() {
        let message = Message(role: .user, content: "hello world")
        #expect(ChatCompaction.serialize(message) == "[User]: hello world")
    }

    // MARK: - Head clamping to the summarizer's own context

    @Test("clampHeadToFit drops oldest entries first when head is too large")
    func clampHeadDropsOldestFirst() {
        let head = (0..<20).map { "entry-\($0)-" + String(repeating: "x", count: 400) }
        let clamped = ChatCompaction.clampHeadToFit(head, summarizerContextLength: 8_000)
        #expect(clamped.count < head.count)
        // The most recent entries (end of the array) should be preserved.
        #expect(clamped.last == head.last)
    }

    @Test("clampHeadToFit is a no-op when the head already fits")
    func clampHeadNoOpWhenSmall() {
        let head = ["a short entry", "another short entry"]
        let clamped = ChatCompaction.clampHeadToFit(head, summarizerContextLength: 128_000)
        #expect(clamped == head)
    }
}
