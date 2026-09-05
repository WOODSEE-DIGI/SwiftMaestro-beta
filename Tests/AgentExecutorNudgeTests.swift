import XCTest
@testable import SwiftMaestro

/// Tests for the agentic loop's mutator classification — the falseClaim
/// nudge depends on it. A successful mutation tool (e.g. a WhatsApp send)
/// must mark the turn as mutating, or the model's legitimate "done"
/// confirmation gets nudged as a false claim and it repeats itself on screen.
@MainActor
final class AgentExecutorNudgeTests: XCTestCase {

    // MARK: - isMutatorToolName: mutating verbs

    func testMessagingSendToolsAreMutators() {
        XCTAssertTrue(AgentExecutor.isMutatorToolName("send_whatsapp_message"))
        XCTAssertTrue(AgentExecutor.isMutatorToolName("send_discord_message"))
        XCTAssertTrue(AgentExecutor.isMutatorToolName("send_agent_message"))
    }

    func testSocialActionToolsAreMutators() {
        XCTAssertTrue(AgentExecutor.isMutatorToolName("post_bluesky"))
        XCTAssertTrue(AgentExecutor.isMutatorToolName("like_bluesky_post"))
        XCTAssertTrue(AgentExecutor.isMutatorToolName("unlike_bluesky_post"))
        XCTAssertTrue(AgentExecutor.isMutatorToolName("repost_bluesky_post"))
        XCTAssertTrue(AgentExecutor.isMutatorToolName("unrepost_bluesky_post"))
    }

    func testFileAndContentWriteToolsAreMutators() {
        XCTAssertTrue(AgentExecutor.isMutatorToolName("write_file"))
        XCTAssertTrue(AgentExecutor.isMutatorToolName("edit_file"))
        XCTAssertTrue(AgentExecutor.isMutatorToolName("create_note"))
        XCTAssertTrue(AgentExecutor.isMutatorToolName("create_calendar_event"))
        XCTAssertTrue(AgentExecutor.isMutatorToolName("update_todo_status"))
        XCTAssertTrue(AgentExecutor.isMutatorToolName("delete_kanban_card"))
        XCTAssertTrue(AgentExecutor.isMutatorToolName("move_kanban_card"))
    }

    func testCaseInsensitiveMatching() {
        XCTAssertTrue(AgentExecutor.isMutatorToolName("Send_WhatsApp_Message"))
        XCTAssertTrue(AgentExecutor.isMutatorToolName("POST_BLUESKY"))
    }

    // MARK: - isMutatorToolName: read-only tools stay false

    func testReadOnlyToolsAreNotMutators() {
        for name in [
            "search_bluesky_posts", "get_bluesky_profile", "get_bluesky_timeline",
            "list_whatsapp_chats", "read_whatsapp_messages", "whatsapp_status",
            "search_contacts", "list_calendar_events", "read_file", "list_dir",
            "web_search", "fetch_url", "get_patreon_campaign",
            "list_patreon_members", "get_current_time", "spotlight_search",
        ] {
            XCTAssertFalse(AgentExecutor.isMutatorToolName(name), "\(name) should be read-only")
        }
    }

    func testVerbMustBeAPrefixNotSubstring() {
        // "research" contains no leading verb; "present" starts with "pre" not a verb.
        XCTAssertFalse(AgentExecutor.isMutatorToolName("research_topic"))
        XCTAssertFalse(AgentExecutor.isMutatorToolName("present_results"))
    }

    // MARK: - asksUserForAction (the futureNarration false-positive fix)
    //
    // A message asking the USER for authorization/permission is a valid final
    // answer — nudging it manufactures a verbatim repeat of the ask.

    func testAuthorizationAskIsDetected() {
        let ask = """
            I've located the service definition at `~/Library/LaunchAgents/com.example.plist`, \
            but I don't have permission to read it.

            **Please add `~/Library/LaunchAgents` to your authorized paths in Settings → Context.** \
            Once you've done that, I can read the file. I will then run that command manually.
            """
        XCTAssertTrue(AgentExecutor.asksUserForAction(ask))
    }

    func testCredentialAndInstallAsksAreDetected() {
        XCTAssertTrue(AgentExecutor.asksUserForAction("Please sign in to continue."))
        XCTAssertTrue(AgentExecutor.asksUserForAction("Please install the helper tool first."))
        XCTAssertTrue(AgentExecutor.asksUserForAction("Access denied: the file is outside the authorized folders."))
        XCTAssertTrue(AgentExecutor.asksUserForAction("You'll need to add the folder in Settings."))
    }

    func testOrdinaryStallIsNotAUserAsk() {
        // Future-tense self-directed intent must NOT be classified as a user ask —
        // those are exactly what futureNarration exists to nudge.
        XCTAssertFalse(AgentExecutor.asksUserForAction("I will now read the file and report back."))
        XCTAssertFalse(AgentExecutor.asksUserForAction("Let me check the directory first."))
        XCTAssertFalse(AgentExecutor.asksUserForAction("Message sent to Digi Stuff!"))
        XCTAssertFalse(AgentExecutor.asksUserForAction("The task is complete."))
    }

    // MARK: - claimsFutureAction "proceeding" patterns (the 6-hour stall)
    //
    // The run ended with "I am now proceeding to find the source files…" and
    // no tool call; none of the existing intents matched that phrasing, so no
    // nudge fired and the run parked itself.

    func testProceedingPhrasingTriggersFutureNarration() {
        XCTAssertTrue(AgentExecutor.claimsFutureAction(
            "I've sent a status update. I am now proceeding to find the source files "
                + "by performing a broader search using glob_files."))
        XCTAssertTrue(AgentExecutor.claimsFutureAction("I'm now proceeding to inspect the project file."))
        XCTAssertTrue(AgentExecutor.claimsFutureAction("I am proceeding to find the correct paths."))
        XCTAssertTrue(AgentExecutor.claimsFutureAction("I will proceed with the investigation."))
    }

    func testCompletedWorkDoesNotTriggerFutureNarration() {
        XCTAssertFalse(AgentExecutor.claimsFutureAction("The search is complete. Here are the results."))
        XCTAssertFalse(AgentExecutor.claimsFutureAction("Message sent to Example Contact One."))
        XCTAssertFalse(AgentExecutor.claimsFutureAction(""))
    }

    // MARK: - containsHesitation (the "Wait, I'll check…" dither flood)

    func testWaitAndRecheckAreHesitation() {
        XCTAssertTrue(AgentExecutor.containsHesitation(
            "Executing the fix**Wait**, I'll check the `edit_file` call one more time"))
        XCTAssertTrue(AgentExecutor.containsHesitation("Hmm, let me re-check that output."))
        XCTAssertTrue(AgentExecutor.containsHesitation("Actually, let me double-check the schema."))
        XCTAssertTrue(AgentExecutor.containsHesitation("On second thought, I'll read it again."))
        XCTAssertTrue(AgentExecutor.containsHesitation("Wait — I'll check the ps output again."))
    }

    func testDecisiveContentIsNotHesitation() {
        XCTAssertFalse(AgentExecutor.containsHesitation("The fix is applied. Here's the summary."))
        XCTAssertFalse(AgentExecutor.containsHesitation("I'll read the file now."))
        // "await" and "waiting" must not false-positive on the word-boundary rule.
        XCTAssertFalse(AgentExecutor.containsHesitation("Await the next instruction."))
        XCTAssertFalse(AgentExecutor.containsHesitation("Waiting for the server to respond is expected."))
    }
}
