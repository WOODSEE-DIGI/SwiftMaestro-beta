import Foundation
import Testing
@testable import SwiftMaestro

/// Live verification that file-backed body loading works against the real
/// Mail store: envelope row → .emlx on disk → parsed headers + body.
/// Requires Full Disk Access (the Mail panel's existing requirement).
struct MailBodyStoreTests {

    @Test @MainActor
    func readsNewestInboxMessageFromDisk() async throws {
        let envelope = MailEnvelopeIndex.shared
        guard envelope.open() else {
            // Skip rather than fail where the test host lacks Mail data access.
            return
        }

        let inboxIDs = try envelope.mailboxIDs(matchingFragments: ["/inbox"])
        let messages = try envelope.messages(mailboxIDs: inboxIDs, limit: 3, offset: 0)
        #expect(!messages.isEmpty)

        let store = MailBodyStore.shared
        let row = messages[0]
        let detail = try await store.detail(for: row)

        #expect(!detail.subject.isEmpty)
        #expect(!detail.sender.isEmpty)
        #expect(!detail.content.isEmpty)
        // The parsed subject should broadly agree with the index row's subject
        // (RFC 2047 decoded forms may differ in decoration but not content).
        #expect(detail.subject.contains(String(row.subject.prefix(10))) || row.subject.contains(String(detail.subject.prefix(10))))
    }

    @Test @MainActor
    func rfc2047Decoding() {
        #expect(MailBodyStore.decodeRFC2047("=?UTF-8?B?RGVtbyBTdWJqZWN0?=") == "Demo Subject")
        #expect(MailBodyStore.decodeRFC2047("=?UTF-8?Q?Example_Store_Name?=") == "Example Store Name")
        #expect(MailBodyStore.decodeRFC2047("plain subject") == "plain subject")
    }
}
