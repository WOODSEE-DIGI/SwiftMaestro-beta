import Foundation
import MLXLMCommon
import SwiftMaestroKit
import Testing
@testable import SwiftMaestro

struct AgentBusTests {

    private func registerBusTools() async {
        await MaestroTools.registerBusTools()
    }

    private func makeBus() -> AgentBus {
        AgentBus(persistenceEnabled: false)
    }

    private func makeMessage(
        topic: String,
        sender: UUID = UUID(),
        senderName: String = "TestAgent",
        kind: AgentBusMessageKind = .status,
        payload: String = "hello"
    ) -> AgentBusMessage {
        AgentBusMessage(
            topic: topic,
            sender: sender,
            senderName: senderName,
            kind: kind,
            payload: payload
        )
    }

    @Test
    func publishAndReadRoundTrip() async {
        let bus = makeBus()
        let agent = UUID()
        let message = makeMessage(topic: "test:roundtrip", payload: "roundtrip payload")

        await bus.publish(message)
        let read = await bus.read(topic: "test:roundtrip", agentID: agent)

        #expect(read.count == 1)
        #expect(read.first?.payload == "roundtrip payload")
        #expect(read.first?.senderName == "TestAgent")
    }

    @Test
    func publishReturnsWhetherSubscribersExist() async {
        let bus = makeBus()
        let agent = UUID()
        let message = makeMessage(topic: "test:subscribers")

        let noSubscribers = await bus.publish(message)
        #expect(noSubscribers == false)

        await bus.subscribe(agentID: agent, topic: "test:subscribers")
        let hasSubscribers = await bus.publish(makeMessage(topic: "test:subscribers"))
        #expect(hasSubscribers == true)
    }

    @Test
    func subscribeThenReadUnreadOnly() async {
        let bus = makeBus()
        let agent = UUID()
        let topic = "test:unread"

        await bus.subscribe(agentID: agent, topic: topic)
        await bus.publish(makeMessage(topic: topic, payload: "first"))
        await bus.markRead(topic: topic, agentID: agent)
        await bus.publish(makeMessage(topic: topic, payload: "second"))

        let unread = await bus.read(topic: topic, agentID: agent, unreadOnly: true)
        #expect(unread.count == 1)
        #expect(unread.first?.payload == "second")
    }

    @Test
    func requestRepliesImmediately() async throws {
        let bus = makeBus()
        let topic = "test:echo"
        let requester = UUID()
        let responder = UUID()
        let request = makeMessage(topic: topic, sender: requester, senderName: "Requester", kind: .request, payload: "ping")

        // Subscribe the responder, then in a separate task reply after a tiny delay.
        await bus.subscribe(agentID: responder, topic: topic)

        let replyTask = Task {
            // Wait until the request is visible on the bus.
            try? await Task.sleep(nanoseconds: 10_000_000)
            let messages = await bus.read(topic: topic, agentID: responder, kinds: [.request])
            let foundRequest = messages.first!
            let reply = AgentBusMessage(
                topic: topic,
                sender: responder,
                senderName: "Responder",
                kind: .reply,
                payload: "pong",
                inReplyTo: foundRequest.id
            )
            _ = await bus.reply(reply, to: foundRequest.id)
        }

        let result = try await bus.request(message: request, timeout: .seconds(1))
        _ = await replyTask.result

        #expect(result.payload == "pong")
        #expect(result.inReplyTo == request.id)
    }

    @Test
    func requestTimesOutWhenNoReply() async {
        let bus = makeBus()
        let request = makeMessage(topic: "test:timeout", kind: .request, payload: "ping")

        await #expect(throws: AgentBusError.self) {
            try await bus.request(message: request, timeout: .milliseconds(50))
        }
    }

    @Test
    func replyToUnknownRequestReturnsFalse() async {
        let bus = makeBus()
        let reply = makeMessage(topic: "test:orphan", kind: .reply, payload: "pong")
        let didResolve = await bus.reply(reply, to: UUID())
        #expect(didResolve == false)
    }

    @Test
    func invalidTopicIsRejected() async {
        let bus = makeBus()
        let bad = makeMessage(topic: "../etc/passwd", payload: "bad")
        let published = await bus.publish(bad)
        #expect(published == false)

        let read = await bus.read(topic: "../etc/passwd", agentID: UUID())
        #expect(read.isEmpty)
    }

    @Test
    func topicsListsNonEmptyHistory() async {
        let bus = makeBus()
        await bus.publish(makeMessage(topic: "test:topics:a", payload: "a"))
        await bus.publish(makeMessage(topic: "test:topics:b", payload: "b"))

        let topics = await bus.topics()
        #expect(topics.contains("test:topics:a"))
        #expect(topics.contains("test:topics:b"))
    }

    @Test
    func busReplyToolRegisteredAndResolvesRequest() async throws {
        await registerBusTools()

        let bus = AgentBus.shared
        let topic = "test:tool:reply:\(UUID().uuidString)"
        let requester = UUID()
        let responder = UUID()

        await bus.subscribe(agentID: responder, topic: topic)

        let request = AgentBusMessage(
            topic: topic,
            sender: requester,
            senderName: "Requester",
            kind: .request,
            payload: "ping"
        )

        let replyTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000)
            let messages = await bus.read(topic: topic, agentID: responder, kinds: [.request])
            let foundRequest = messages.first!
            let call = ToolCall(function: .init(
                name: "bus_reply",
                arguments: [
                    "request_id": .string(foundRequest.id.uuidString),
                    "topic": .string(topic),
                    "payload": .string("pong"),
                    "agent_id": .string(responder.uuidString)
                ]
            ))
            return await ToolRegistry.shared.execute(call)
        }

        let result = try await bus.request(message: request, timeout: .seconds(1))
        let toolResult = await replyTask.result

        #expect(result.payload == "pong")
        #expect(result.inReplyTo == request.id)
        let toolOutput = try? toolResult.get()
        #expect(toolOutput?.contains("\"replied\":true") == true)
    }

    @Test
    func busReplyToolRegisteredInSchemas() async {
        await registerBusTools()
        let specs = await ToolRegistry.shared.schemas(enabledCategories: ["bus"])
        let names = specs.compactMap { spec -> String? in
            guard let function = spec["function"] as? [String: any Sendable] else { return nil }
            return function["name"] as? String
        }
        #expect(names.contains("bus_reply"))
        #expect(names.contains("bus_request"))
        #expect(names.contains("bus_read"))
        #expect(names.contains("bus_subscribe"))
        #expect(names.contains("bus_publish"))
    }
}
