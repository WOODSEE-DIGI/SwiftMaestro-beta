import Foundation
import MLXLMCommon

// MARK: - WhatsApp tools
//
// Native bridge management + chat/message access for the self-hosted
// whatsapp-bridge (see WhatsAppService.swift for the full architecture
// rationale). Mirrors the shared-service-instance + fuzzy-resolution
// pattern already used for Kanban/Apple Notes in MaestroTools+Apps.swift.
extension MaestroTools {

    static func registerWhatsAppTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "whatsapp_status", spec: whatsappToolSpecs[0],
                category: ToolCategory.whatsapp.rawValue,
                handler: { _ in await whatsappStatusTool() }),
            ToolDefinition(
                name: "start_whatsapp_bridge", spec: whatsappToolSpecs[1],
                category: ToolCategory.whatsapp.rawValue,
                handler: { _ in await startWhatsAppBridgeTool() }),
            ToolDefinition(
                name: "stop_whatsapp_bridge", spec: whatsappToolSpecs[2],
                category: ToolCategory.whatsapp.rawValue,
                handler: { _ in await stopWhatsAppBridgeTool() }),
            ToolDefinition(
                name: "list_whatsapp_chats", spec: whatsappToolSpecs[3],
                category: ToolCategory.whatsapp.rawValue,
                handler: { _ in await listWhatsAppChatsTool() }),
            ToolDefinition(
                name: "read_whatsapp_messages", spec: whatsappToolSpecs[4],
                category: ToolCategory.whatsapp.rawValue,
                handler: { call in await readWhatsAppMessagesTool(call) }),
            ToolDefinition(
                name: "send_whatsapp_message", spec: whatsappToolSpecs[5],
                category: ToolCategory.whatsapp.rawValue,
                handler: { call in await sendWhatsAppMessageTool(call) }),
        ])
    }



    static var whatsappToolSpecs: [ToolSpec] {
        [
            rawSpec("whatsapp_status",
                "Check the WhatsApp bridge's connection status (stopped, starting, awaiting a QR "
                + "code scan, connected, or errored). The bridge must be connected before chats/messages "
                + "are available.",
                properties: [:], required: []),
            rawSpec("start_whatsapp_bridge",
                "Start the WhatsApp bridge process. If it needs re-pairing, it will print a QR code — "
                + "tell the user to open the WhatsApp panel in the sidebar to scan it with their phone "
                + "(WhatsApp -> Linked Devices -> Link a Device). You cannot scan it yourself.",
                properties: [:], required: []),
            rawSpec("stop_whatsapp_bridge",
                "Stop the WhatsApp bridge process.",
                properties: [:], required: []),
            rawSpec("list_whatsapp_chats",
                "List WhatsApp chats (most recently active first). Requires the bridge to be connected.",
                properties: [:], required: []),
            rawSpec("read_whatsapp_messages",
                "Read recent messages in a WhatsApp chat.",
                properties: [
                    "chat": ["type": "string", "description": "Chat name or JID (from list_whatsapp_chats)."],
                    "limit": ["type": "integer", "description": "Max messages to return (default 50)."],
                ], required: ["chat"]),
            rawSpec("send_whatsapp_message",
                "Send a WhatsApp message to a chat. Requires the bridge to be connected.",
                properties: [
                    "chat": ["type": "string", "description": "Chat name or JID (from list_whatsapp_chats)."],
                    "message": ["type": "string", "description": "Message text to send."],
                ], required: ["chat", "message"]),
        ]
    }

    @MainActor
    static let sharedWhatsAppService = WhatsAppService()

    private struct ReadMessagesArgs: Codable { let chat: String?; let limit: Int? }
    private struct SendMessageArgs: Codable { let chat: String?; let message: String? }

    /// Fuzzy chat lookup: exact JID, then case-insensitive exact name, then substring —
    /// same convention as `findBoard` for Kanban.
    @MainActor
    private static func findChat(_ key: String) -> WhatsAppChat? {
        if let byJID = sharedWhatsAppService.chats.first(where: { $0.jid == key }) { return byJID }
        if let exact = sharedWhatsAppService.chats.first(where: {
            ($0.name ?? "").caseInsensitiveCompare(key) == .orderedSame
        }) { return exact }
        return sharedWhatsAppService.chats.first { ($0.name ?? "").localizedCaseInsensitiveContains(key) }
    }

    private static func statusDescription(_ status: WhatsAppService.Status) -> String {
        switch status {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .awaitingQRScan: return "awaiting QR scan — open the WhatsApp panel in the sidebar to scan it"
        case .connected: return "connected"
        case .error(let message): return "error: \(message)"
        }
    }

    // MARK: - Implementations

    static func whatsappStatusTool() async -> String {
        let status = await MainActor.run { sharedWhatsAppService.status }
        return jsonString(["status": statusDescription(status)])
    }

    static func startWhatsAppBridgeTool() async -> String {
        await MainActor.run { sharedWhatsAppService.start() }
        // Give the process a moment to either connect immediately (already
        // paired) or print a QR prompt, so this call's result is informative
        // rather than always just "starting".
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let status = await MainActor.run { sharedWhatsAppService.status }
        return jsonString(["status": statusDescription(status)])
    }

    static func stopWhatsAppBridgeTool() async -> String {
        await MainActor.run { sharedWhatsAppService.stop() }
        return jsonString(["status": "stopped"])
    }

    static func listWhatsAppChatsTool() async -> String {
        if await MainActor.run(body: { sharedWhatsAppService.status }) != .connected {
            return errorJSON("Bridge is not connected. Use start_whatsapp_bridge first.")
        }
        await sharedWhatsAppService.loadChats()
        return await MainActor.run {
            let chats = sharedWhatsAppService.chats
            guard !chats.isEmpty else { return "No chats found." }
            let iso = ISO8601DateFormatter()
            return jsonString(["chats": chats.map { chat -> [String: Any] in
                var dict: [String: Any] = ["jid": chat.jid, "name": chat.name ?? chat.jid]
                if let time = chat.lastMessageTime { dict["lastMessageTime"] = iso.string(from: time) }
                return dict
            }])
        }
    }

    static func readWhatsAppMessagesTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ReadMessagesArgs.self),
              let key = args.chat?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { return errorJSON("read_whatsapp_messages requires 'chat'") }
        if await MainActor.run(body: { sharedWhatsAppService.status }) != .connected {
            return errorJSON("Bridge is not connected. Use start_whatsapp_bridge first.")
        }
        if await MainActor.run(body: { sharedWhatsAppService.chats.isEmpty }) {
            await sharedWhatsAppService.loadChats()
        }
        guard let chat = await MainActor.run(body: { findChat(key) }) else {
            return errorJSON("no chat matching \"\(key)\". Use list_whatsapp_chats first.")
        }
        await sharedWhatsAppService.loadMessages(chatJID: chat.jid, limit: args.limit ?? 50)
        return await MainActor.run {
            let messages = sharedWhatsAppService.messages
            guard !messages.isEmpty else { return "No messages in \"\(chat.name ?? chat.jid)\"." }
            let iso = ISO8601DateFormatter()
            let lines = messages.map { message -> String in
                let who = message.isFromMe ? "me" : (message.sender ?? "them")
                let when = message.timestamp.map(iso.string(from:)) ?? ""
                let text = message.content ?? (message.mediaType.map { "[\($0)]" } ?? "")
                return "[\(when)] \(who): \(text)"
            }
            return "Messages in \"\(chat.name ?? chat.jid)\" (\(messages.count)):\n" + lines.joined(separator: "\n")
        }
    }

    static func sendWhatsAppMessageTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SendMessageArgs.self),
              let key = args.chat?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              let message = args.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty
        else { return errorJSON("send_whatsapp_message requires 'chat' and 'message'") }
        if await MainActor.run(body: { sharedWhatsAppService.status }) != .connected {
            return errorJSON("Bridge is not connected. Use start_whatsapp_bridge first.")
        }
        if await MainActor.run(body: { sharedWhatsAppService.chats.isEmpty }) {
            await sharedWhatsAppService.loadChats()
        }
        guard let chat = await MainActor.run(body: { findChat(key) }) else {
            return errorJSON("no chat matching \"\(key)\". Use list_whatsapp_chats first.")
        }
        do {
            try await sharedWhatsAppService.sendMessage(to: chat.jid, text: message)
            return jsonString(["status": "sent", "chat": chat.name ?? chat.jid])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }
}
