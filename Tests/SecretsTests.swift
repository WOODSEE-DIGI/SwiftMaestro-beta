import XCTest

/// Pure-logic tests for the secrets layer. These intentionally avoid writing to
/// the real Keychain so they run deterministically and never trigger auth prompts.
final class SecretsTests: XCTestCase {

    // MARK: Scope -> Keychain account naming

    func testGlobalAccountNaming() {
        XCTAssertEqual(SecretScope.global.account(for: "github_token"), "secret.global.github_token")
    }

    func testProjectAccountNaming() {
        XCTAssertEqual(SecretScope.project("alpha").account(for: "api"), "secret.project.alpha.api")
    }

    func testScopeKindAndProjectId() {
        XCTAssertEqual(SecretScope.global.kind, "global")
        XCTAssertEqual(SecretScope.project("x").kind, "project")
        XCTAssertNil(SecretScope.global.projectId)
        XCTAssertEqual(SecretScope.project("x").projectId, "x")
    }

    // MARK: Reference parsing

    func testReferencePrefix() {
        XCTAssertEqual(SecretsStore.referencePrefix, "secret://")
    }

    func testResolveIgnoresNonReference() {
        // A plain key (no secret:// prefix) must NOT be treated as a reference,
        // and must resolve to nil without touching the Keychain.
        XCTAssertNil(SecretsStore.resolve(reference: "sk-plain-key-123", currentProject: nil))
        XCTAssertNil(SecretsStore.resolve(reference: "", currentProject: nil))
    }

    // MARK: Metadata <-> scope mapping

    func testMetadataScopeMapping() {
        let now = Date()
        let global = SecretMetadata(name: "a", scopeKind: "global", projectId: nil,
                                    synced: true, note: nil, createdAt: now, updatedAt: now, lastUsedAt: nil)
        XCTAssertEqual(global.scope, .global)
        XCTAssertEqual(global.account, "secret.global.a")

        let project = SecretMetadata(name: "b", scopeKind: "project", projectId: "proj",
                                     synced: false, note: nil, createdAt: now, updatedAt: now, lastUsedAt: nil)
        XCTAssertEqual(project.scope, .project("proj"))
        XCTAssertEqual(project.account, "secret.project.proj.b")
    }

    func testMetadataCodableRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let meta = SecretMetadata(name: "tok", scopeKind: "project", projectId: "p1",
                                  synced: true, note: "ci", createdAt: now, updatedAt: now, lastUsedAt: nil)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        let decoded = try decoder.decode(SecretMetadata.self, from: data)
        XCTAssertEqual(decoded, meta)
        XCTAssertEqual(decoded.account, "secret.project.p1.tok")
    }

    // MARK: Redaction

    func testRedactorIsIdentityForBenignText() {
        // With no matching secret values, redaction must return the input unchanged.
        let input = "the quick brown fox jumps over the lazy dog"
        XCTAssertEqual(SecretRedactor.redact(input), input)
    }
}
