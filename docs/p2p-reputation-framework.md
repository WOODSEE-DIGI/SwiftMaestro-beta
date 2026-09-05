# P2P Reputation Framework

**Status:** Architecture / design phase  
**Applies to:** SwiftMaestro unpaid-invoice blacklist, Political Money billionaire-karma tracker, and any future reputation use case.

---

## 1. Overview

This document defines a general-purpose, decentralised reputation framework for SwiftMaestro-family apps. It lets users create **attestations** about a **subject** (a business, person, or entity), sign them with a self-sovereign identity, and share them over a peer-to-peer gossip network. Other peers verify, aggregate, and display the results without requiring a central server.

The framework is intentionally agnostic about the *meaning* of a score. It supports:

- **Unpaid-invoice blacklist** — negative attestations about businesses that default on invoices.
- **Political Money / Billionaire Karma** — public karma scores for billionaires based on political contributions and perceived influence.
- Future use cases such as vendor reviews, contractor reputation, or public-interest scoring.

---

## 2. Design principles

1. **Privacy-preserving by default.** Raw identifiers (ABN, ACN, names, wallet addresses) are hashed or verified off-chain; only attestations and aggregates travel over the network.
2. **Verifiable, not anonymous.** Every attestation is signed by a stable identity. Reputation comes from *provable history*, not throwaway accounts.
3. **Sybil-resistant.** New identities have low weight. Weight grows through stake, past paid invoices, or other proof-of-participation mechanisms.
4. **Revocable.** Reporters can revoke their own attestations; subjects can dispute attestations with counter-evidence.
5. **Offline-first.** A device can import bulk public datasets, verify subjects locally, and only go online to gossip or fetch updates.
6. **Legally conservative.** Attestations are statements of fact backed by evidence; the protocol discourages speculation and provides dispute paths.

---

## 3. Core concepts

### 3.1 Subject

The entity being rated. A subject is identified by a canonical, stable fingerprint derived from public attributes:

| Use case | Subject fingerprint input |
|---|---|
| Unpaid invoice | SHA-256(name + normalised tax ID + country) |
| Billionaire karma | SHA-256(name + Forbes profile URL + primary known entity) |
| Generic | SHA-256 of a user-supplied URI or public key |

The fingerprint is the only subject identifier that appears in attestations.

### 3.2 Attestation

A signed statement about a subject. It contains:

```json
{
  "id": "uuid",
  "schema": "com.woodseedigi.reputation.attestation/1",
  "subjectHash": "sha256:...",
  "scope": "unpaid-invoice | billionaire-karma | ...",
  "claim": {
    "type": "default | late-payment | political-contribution | influence-score",
    "value": -1.0,
    "currency": "AUD",
    "amount": 12500.00,
    "daysOverdue": 45,
    "evidenceHash": "sha256:...",
    "metadata": {}
  },
  "verifierProof": {
    "kind": "abn-verified | acn-verified | public-record",
    "issuer": "device-key-id",
    "signature": "...",
    "verifiedAt": "2026-09-03T18:52:00Z"
  },
  "reporter": {
    "keyID": "device-key-id",
    "stakeWeight": 0.15,
    "reputationScore": 0.82
  },
  "createdAt": "2026-09-03T18:52:00Z",
  "expiresAt": "2027-09-03T18:52:00Z",
  "signature": "..."
}
```

- **Negative values** mean harm/distrust; **positive values** mean trust/karma.
- `evidenceHash` points to encrypted evidence stored locally by the reporter (or, for public data, a content-addressed URL).
- `verifierProof` proves that the reporter verified the subject against an authoritative source before attesting.

### 3.3 Identity

Each device/user has an Ed25519 key pair generated on first opt-in. The public key becomes the `keyID`. No email or phone number is required.

To resist Sybil attacks, identity weight is derived from:

- **History weight** — number of previous attestations that were not revoked or successfully disputed.
- **Stake weight** — optional small time-locked deposit (future).
- **Proof-of-business** — for the blacklist use case, a history of paid invoices.
- **Proof-of-humanity** — optional linkage to a verified credential or existing Web-of-Trust graph (future).

### 3.4 Aggregate score

Each subject has a computed score based on weighted attestations:

```
score(subject) = Σ (attestation.value × reporter.weight × ageDecay × verificationBoost)
```

- `ageDecay` reduces the weight of old attestations.
- `verificationBoost` increases weight when the subject was verified against an authoritative dataset.
- Outliers and disputes reduce the weight of suspicious attestations.

For the billionaire-karma use case, the score is surfaced as a **Karma Rank** (e.g. -100 to +100) with breakdown by contribution type.

---

## 4. Network layer

The framework does not require a single blockchain. Two candidate designs are kept open:

### 4.1 Option A: libp2p gossipsub

- Peers discover each other via DHT or bootstrap nodes.
- Attestations are published to topic `reputation/{scope}/{subjectPrefix}`.
- Peers subscribe to topics relevant to their contacts or local database.
- Best for high-volume, app-integrated networks.

### 4.2 Option B: Nostr

- Attestations are Nostr events (`kind` TBD, e.g. 39000).
- Identity is the Nostr public key.
- Relays propagate events; clients choose relays.
- Best for interoperability with existing open-social infrastructure.

### 4.3 Option C: Hybrid

- Use Nostr for discovery and relay propagation.
- Use libp2p for large evidence blobs and private peer sync.

**Decision:** Start with **Nostr** for the first prototype because it requires no custom network code and gives immediate relay availability. Migrate to hybrid if volume or privacy demands it.

---

## 5. Verifier nodes

A verifier node is any peer that performs local verification before signing an attestation. Verification sources include:

| Dataset | Use case | Source |
|---|---|---|
| ABR bulk extract | Blacklist | data.gov.au / abr.business.gov.au |
| ASIC companies | Blacklist | data.gov.au |
| ASIC business names | Blacklist | data.gov.au |
| ABN Lookup | Blacklist | abr.business.gov.au |
| Forbes billionaire list | Karma | Forbes API / archived snapshots |
| FEC / AEC / OpenSecrets | Karma | Public campaign-finance APIs |

The verifier node issues a `verifierProof` that states: *"I have verified the subject against source X and the claim is consistent with that source."* The proof does not reveal the raw identifier.

---

## 6. Revocation and dispute

### 6.1 Revocation

A reporter can publish a revocation event that invalidates a previous attestation by ID. Revocations are signed by the same key that created the attestation.

### 6.2 Dispute

A subject (or anyone with evidence) can publish a counter-attestation or a dispute event. Disputes do not delete the original attestation but attach a rebuttal that other peers weigh in their aggregate.

For public figures (billionaires), disputes may include links to official corrections or counter-narratives.

---

## 7. Privacy and legal considerations

- **No raw PII on chain.** Only hashed fingerprints, signed claims, and encrypted evidence references.
- **Right to reply.** Subjects can see disputes/counter-claims.
- **Jurisdiction awareness.** Defamation, GDPR, and Australian Privacy Act implications must be reviewed before enabling publish-by-default.
- **No automatic publishing.** The user must explicitly approve every attestation that leaves their device.

---

## 8. Swift integration points

The framework exposes a small Swift API surface:

```swift
// Create an identity
let identity = try await ReputationIdentity.createOrLoad()

// Build and sign an attestation
let attestation = try await identity.attest(
    subject: subjectFingerprint,
    scope: .unpaidInvoice,
    claim: .default(value: -1.0, currency: "AUD", amount: 12500, daysOverdue: 45),
    verifierProof: abnProof)

// Publish to the network
let publisher = ReputationPublisher(relays: defaultRelays, identity: identity)
try await publisher.publish(attestation)

// Aggregate scores for known subjects
let aggregator = ReputationAggregator()
let score = await aggregator.score(for: subjectFingerprint, scope: .unpaidInvoice)
```

Concrete implementations:

- `ReputationIdentity` — Keychain-backed Ed25519 key pair.
- `ReputationPublisher` — Nostr event builder/relay client.
- `ReputationAggregator` — Local SQLite cache of received attestations + scoring logic.
- `ReputationSubject` — Fingerprint builders for business, person, and URI subjects.

---

## 9. Use-case mappings

### 9.1 Unpaid-invoice blacklist

- **Subject:** business fingerprint.
- **Claim:** `late-payment` with amount, currency, days overdue.
- **Verifier proof:** ABN/ACN verified against ABR/ASIC.
- **Score meaning:** higher negative = worse payment history.
- **UI:** risk banner in CRM; opt-in report flow from invoice screen.

### 9.2 Political Money / Billionaire Karma

- **Subject:** billionaire fingerprint.
- **Claim:** `political-contribution` (recipient, amount, year) or `influence-score` (user sentiment).
- **Verifier proof:** public campaign-finance record or Forbes profile.
- **Score meaning:** aggregate public sentiment + verified contribution data.
- **UI:** leaderboard, karma timeline, contribution breakdown, per-billionaire CRM-like card.

---

## 10. Open questions

1. Which Nostr `kind` number to register for reputation attestations?
2. Should attestations include encrypted evidence, or only content-addressed hashes?
3. What is the exact Sybil-resistance mechanism for the first release?
4. Which relays/bootstrap nodes are trusted by default?
5. Legal review: does the attestation format expose the project to defamation risk?
6. Should there be a small economic cost (e.g. Lightning Network) to publish, to deter spam?

---

## 11. Next steps

1. Prototype `ReputationIdentity`, `ReputationPublisher`, and `ReputationAggregator` in Swift.
2. Integrate with the existing `ABNVerifierService` to generate `verifierProof`.
3. Build the **Prepare blacklist report** UI that creates and signs an attestation without publishing.
4. Reuse the same framework for the Political Money billionaire-karma prototype.
