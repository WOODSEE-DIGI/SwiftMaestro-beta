import Foundation
import MLXLMCommon

// MARK: - Shared contacts service

@MainActor
private let sharedContactsService = ContactsService()

// MARK: - Native macOS system tools
//
// Expose the real `MacOSIntegration` (EventKit Reminders/Calendar, Notes via
// Apple Events, URL opening, Contacts) as in-process agent tools. Each reports
// the actual outcome; permission prompts appear on first use.
extension MaestroTools {

    /// This one file's specs actually span THREE categories (matches
    /// ToolCategory's existing per-name lists exactly: rules/system/notes) -
    /// not just `.system` for everything, since rules/create_note were
    /// co-located here even though they're categorized separately.
    static func registerSystemTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "list_rules", spec: systemToolSpecs[0],
                category: ToolCategory.rules.rawValue,
                handler: { _ in listRulesTool() }),
            ToolDefinition(
                name: "set_rule", spec: systemToolSpecs[1],
                category: ToolCategory.rules.rawValue,
                handler: { call in setRuleTool(call) }),
            ToolDefinition(
                name: "read_project_rules", spec: systemToolSpecs[2],
                category: ToolCategory.rules.rawValue,
                handler: { call in readProjectRulesTool(call) }),
            ToolDefinition(
                name: "create_reminder", spec: systemToolSpecs[3],
                category: ToolCategory.system.rawValue,
                handler: { call in await createReminder(call) }),
            ToolDefinition(
                name: "list_reminders", spec: systemToolSpecs[4],
                category: ToolCategory.system.rawValue,
                handler: { call in await listRemindersTool(call) }),
            ToolDefinition(
                name: "create_calendar_event", spec: systemToolSpecs[5],
                category: ToolCategory.system.rawValue,
                handler: { call in await createCalendarEvent(call) }),
            ToolDefinition(
                name: "create_note", spec: systemToolSpecs[6],
                category: ToolCategory.notes.rawValue,
                handler: { call in await createNoteTool(call) }),
            ToolDefinition(
                name: "open_url", spec: systemToolSpecs[7],
                category: ToolCategory.system.rawValue,
                handler: { call in await openURLTool(call) }),
            ToolDefinition(
                name: "search_contacts", spec: systemToolSpecs[8],
                category: ToolCategory.system.rawValue,
                handler: { call in await searchContactsTool(call) }),
            ToolDefinition(
                name: "create_contact", spec: systemToolSpecs[9],
                category: ToolCategory.system.rawValue,
                handler: { call in await createContactTool(call) }),
            ToolDefinition(
                name: "update_contact", spec: systemToolSpecs[10],
                category: ToolCategory.system.rawValue,
                handler: { call in await updateContactTool(call) }),
            ToolDefinition(
                name: "delete_contact", spec: systemToolSpecs[11],
                category: ToolCategory.system.rawValue,
                handler: { call in await deleteContactTool(call) }),
            ToolDefinition(
                name: "list_shortcuts", spec: systemToolSpecs[12],
                category: ToolCategory.system.rawValue,
                handler: { _ in await listShortcutsTool() }),
            ToolDefinition(
                name: "run_shortcut", spec: systemToolSpecs[13],
                category: ToolCategory.system.rawValue,
                handler: { call in await runShortcutTool(call) }),
            ToolDefinition(
                name: "create_shortcut", spec: systemToolSpecs[14],
                category: ToolCategory.system.rawValue,
                handler: { call in await createShortcutTool(call) }),
        ])
    }



    static var systemToolSpecs: [ToolSpec] {
        [
            rawSpec("list_rules",
                "List all behavioral rules currently configured. Shows rule text, enabled status, and scope (All or agent name).",
                properties: [:], required: []),
            rawSpec("set_rule",
                "Add or update a behavioral rule. Rules are injected into the system prompt and guide the model's behavior.",
                properties: [
                    "text": ["type": "string", "description": "The rule text."],
                    "enabled": ["type": "boolean", "description": "Whether the rule is active (default true)."],
                    "scope": ["type": "string", "description": "Scope: 'All' for every agent, or a specific agent name."],
                ], required: ["text"]),
            rawSpec("read_project_rules",
                "Read the project rule files (AGENTS.md, README.md, .ai-context/README.md) from the agent's working directory. "
                + "Use to verify which project rules are currently loaded.",
                properties: [:], required: []),
            rawSpec("create_reminder",
                "Create a reminder in the macOS Reminders app. Prompts for access on first use.",
                properties: [
                    "title": ["type": "string", "description": "Reminder title."],
                    "notes": ["type": "string", "description": "Optional notes."],
                    "due": ["type": "string", "description": "Optional ISO-8601 due date/time, e.g. 2026-06-15T14:00:00Z."],
                ], required: ["title"]),
            rawSpec("list_reminders",
                "List reminders from the macOS Reminders app.",
                properties: [
                    "limit": ["type": "integer", "description": "Max reminders to return (default 25)."],
                ], required: []),
            rawSpec("create_calendar_event",
                "Create an event in the macOS Calendar app. Prompts for access on first use.",
                properties: [
                    "title": ["type": "string", "description": "Event title."],
                    "start": ["type": "string", "description": "ISO-8601 start, e.g. 2026-06-15T14:00:00Z."],
                    "end": ["type": "string", "description": "ISO-8601 end."],
                    "notes": ["type": "string", "description": "Optional notes."],
                ], required: ["title", "start", "end"]),
            rawSpec("create_note",
                "Create a note in the macOS Notes app.",
                properties: [
                    "title": ["type": "string", "description": "Note title."],
                    "body": ["type": "string", "description": "Note body text."],
                ], required: ["title", "body"]),
            rawSpec("open_url",
                "Open a URL in the user's default browser.",
                properties: [
                    "url": ["type": "string", "description": "The URL to open (https://…)."],
                ], required: ["url"]),
            rawSpec("search_contacts",
                "Search the macOS Contacts app. Matches name, organization, phone, email, or URL. Prompts for access on first use.",
                properties: [
                    "query": ["type": "string", "description": "Optional search string. Leave empty to list contacts."],
                    "limit": ["type": "integer", "description": "Max contacts to return (default 50)."],
                ], required: []),
            rawSpec("create_contact",
                "Create a new contact in the macOS Contacts app.",
                properties: [
                    "given_name": ["type": "string", "description": "First name."],
                    "family_name": ["type": "string", "description": "Last name."],
                    "organization": ["type": "string", "description": "Company or organization."],
                    "phone": ["type": "string", "description": "Phone number."],
                    "email": ["type": "string", "description": "Email address."],
                ], required: ["given_name"]),
            rawSpec("update_contact",
                "Update an existing contact in the macOS Contacts app.",
                properties: [
                    "id": ["type": "string", "description": "The contact identifier from search_contacts."],
                    "given_name": ["type": "string", "description": "First name."],
                    "family_name": ["type": "string", "description": "Last name."],
                    "organization": ["type": "string", "description": "Company or organization."],
                    "phone": ["type": "string", "description": "Phone number."],
                    "email": ["type": "string", "description": "Email address."],
                ], required: ["id", "given_name"]),
            rawSpec("delete_contact",
                "Delete a contact from the macOS Contacts app by identifier.",
                properties: [
                    "id": ["type": "string", "description": "The contact identifier from search_contacts."],
                ], required: ["id"]),
            rawSpec("list_shortcuts",
                "List all Apple Shortcuts on this Mac. Returns shortcut names.",
                properties: [:], required: []),
            rawSpec("run_shortcut",
                "Run an Apple Shortcut by name. The shortcut must already exist in the Shortcuts app.",
                properties: [
                    "name": ["type": "string", "description": "The name of the shortcut to run."],
                    "input": ["type": "string", "description": "Optional input text to pass to the shortcut."],
                ], required: ["name"]),
            rawSpec("create_shortcut",
                "Create a new Apple Shortcut from a list of actions. The shortcut is saved as a .shortcut file on the Desktop — the user double-clicks to import it into the Shortcuts app.",
                properties: [
                    "name": ["type": "string", "description": "Name for the new shortcut."],
                    "actions": ["type": "array", "description": "Array of action objects, each with 'type' and parameters. Supported types: 'open_url' (url), 'create_reminder' (title, notes), 'create_note' (title, body), 'send_message' (to, body), 'get_current_date', 'run_shortcut' (name), 'set_volume' (value 0-100), 'play_sound', 'wait' (seconds), 'if' (condition, then_actions, else_actions), 'repeat' (count, actions), 'text' (value), 'get_contents_of_url' (url), 'show_result' (text)."],
                ], required: ["name", "actions"]),
        ]
    }

    private struct ReminderArgs: Codable { let title: String?; let notes: String?; let due: String? }
    private struct ListRemindersArgs: Codable { let limit: Int? }
    private struct EventArgs: Codable { let title: String?; let start: String?; let end: String?; let notes: String? }
    private struct NoteArgs: Codable { let title: String?; let body: String? }
    private struct OpenURLArgs: Codable { let url: String? }
    private struct SearchContactsArgs: Codable { let query: String?; let limit: Int? }
    private struct ContactWriteArgs: Codable {
        let id: String?
        let given_name: String?
        let family_name: String?
        let organization: String?
        let phone: String?
        let email: String?
    }
    private struct DeleteContactArgs: Codable { let id: String? }

    static func createReminder(_ call: ToolCall) async -> String {
        guard let a = decodeArgs(call, as: ReminderArgs.self),
              let title = a.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
            return errorJSON("create_reminder requires 'title'")
        }
        do { return try await MacOSIntegration.createReminder(title: title, notes: a.notes, due: a.due) }
        catch { return errorJSON(error.localizedDescription) }
    }

    static func listRemindersTool(_ call: ToolCall) async -> String {
        let a = decodeArgs(call, as: ListRemindersArgs.self)
        do {
            let items = try await MacOSIntegration.listReminders(limit: a?.limit ?? 25)
            return items.isEmpty
                ? "No reminders found."
                : "Reminders (\(items.count)):\n" + items.joined(separator: "\n")
        } catch { return errorJSON(error.localizedDescription) }
    }

    static func createCalendarEvent(_ call: ToolCall) async -> String {
        guard let a = decodeArgs(call, as: EventArgs.self),
              let title = a.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
              let start = a.start, let end = a.end else {
            return errorJSON("create_calendar_event requires 'title', 'start', and 'end'")
        }
        do { return try await MacOSIntegration.createCalendarEvent(title: title, start: start, end: end, notes: a.notes) }
        catch { return errorJSON(error.localizedDescription) }
    }

    static func createNoteTool(_ call: ToolCall) async -> String {
        guard let a = decodeArgs(call, as: NoteArgs.self),
              let title = a.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
              let body = a.body else {
            return errorJSON("create_note requires 'title' and 'body'")
        }
        do { return try await MacOSIntegration.createNote(title: title, body: body) }
        catch { return errorJSON(error.localizedDescription) }
    }

    static func openURLTool(_ call: ToolCall) async -> String {
        guard let a = decodeArgs(call, as: OpenURLArgs.self),
              let url = a.url?.trimmingCharacters(in: .whitespaces), !url.isEmpty else {
            return errorJSON("open_url requires 'url'")
        }
        let ok = await MacOSIntegration.openURL(url)
        return ok ? jsonString(["status": "opened", "url": url]) : errorJSON("could not open '\(url)'")
    }

    static func searchContactsTool(_ call: ToolCall) async -> String {
        let a = decodeArgs(call, as: SearchContactsArgs.self)
        do {
            let contacts = try await sharedContactsService.searchContacts(
                query: a?.query,
                limit: a?.limit ?? 50
            )
            guard !contacts.isEmpty else { return "No contacts found." }
            let list: [[String: Any]] = contacts.map { c in
                [
                    "id": c.id ?? "",
                    "name": c.displayName,
                    "organization": c.organizationName,
                    "phones": c.phoneNumbers.map(\.value),
                    "emails": c.emailAddresses.map(\.value),
                    "urls": c.urls.map(\.value),
                ]
            }
            return jsonString(["count": contacts.count, "contacts": list])
        } catch { return errorJSON(error.localizedDescription) }
    }

    static func createContactTool(_ call: ToolCall) async -> String {
        guard let a = decodeArgs(call, as: ContactWriteArgs.self),
              let givenName = a.given_name?.trimmingCharacters(in: .whitespaces), !givenName.isEmpty else {
            return errorJSON("create_contact requires 'given_name'")
        }
        let contact = Contact(
            givenName: givenName,
            familyName: a.family_name ?? "",
            organizationName: a.organization ?? "",
            phoneNumbers: a.phone.map { [.init(label: nil, value: $0)] } ?? [],
            emailAddresses: a.email.map { [.init(label: nil, value: $0)] } ?? []
        )
        do {
            let id = try await sharedContactsService.createContact(contact)
            return jsonString(["status": "created", "id": id])
        } catch { return errorJSON(error.localizedDescription) }
    }

    static func updateContactTool(_ call: ToolCall) async -> String {
        guard let a = decodeArgs(call, as: ContactWriteArgs.self),
              let id = a.id?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
              let givenName = a.given_name?.trimmingCharacters(in: .whitespaces), !givenName.isEmpty else {
            return errorJSON("update_contact requires 'id' and 'given_name'")
        }
        do {
            guard let existing = try await sharedContactsService.contact(withIdentifier: id) else {
                return errorJSON("contact not found")
            }
            let updated = Contact(
                id: id,
                givenName: givenName,
                familyName: a.family_name ?? existing.familyName,
                organizationName: a.organization ?? existing.organizationName,
                phoneNumbers: a.phone.map { [.init(label: nil, value: $0)] } ?? existing.phoneNumbers,
                emailAddresses: a.email.map { [.init(label: nil, value: $0)] } ?? existing.emailAddresses
            )
            try await sharedContactsService.updateContact(updated)
            return jsonString(["status": "updated", "id": id])
        } catch { return errorJSON(error.localizedDescription) }
    }

    static func deleteContactTool(_ call: ToolCall) async -> String {
        guard let a = decodeArgs(call, as: DeleteContactArgs.self),
              let id = a.id?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
            return errorJSON("delete_contact requires 'id'")
        }
        do {
            try await sharedContactsService.deleteContact(identifier: id)
            return jsonString(["status": "deleted", "id": id])
        } catch { return errorJSON(error.localizedDescription) }
    }

    static func readProjectRulesTool(_ call: ToolCall) -> String {
        guard let wd = MaestroTools.workingDirectory, !wd.isEmpty else {
            return errorJSON("No working directory is set for this agent. "
                + "Set a working directory before reading project rules.")
        }
        let rules = ProjectRuleService.shared.refreshRules(forWorkingDirectory: wd)
        guard !rules.isEmpty else {
            return jsonString([
                "rules": [],
                "count": 0,
                "message": "No project rule files found in \(wd). "
                    + "Expected: AGENTS.md, README.md, .ai-context/README.md",
            ])
        }
        let list: [[String: Any]] = rules.map { rule in
            [
                "source": rule.source.displayName,
                "path": rule.path,
                "size": rule.content.count,
                "content": rule.content,
            ]
        }
        return jsonString(["rules": list, "count": list.count])
    }
}
