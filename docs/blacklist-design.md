# Peer-to-Peer Unpaid-Invoice Blacklist — Design Notes

> **Framework:** The p2p layer is specified generically in [`p2p-reputation-framework.md`](./p2p-reputation-framework.md). This document describes how that framework is applied to the unpaid-invoice use case.

## Goal
Allow SwiftMaestro users to report business contacts that have unpaid invoices beyond 60 days, creating a shared, decentralised reputation signal for late/non-paying customers. The system must be privacy-preserving, legally cautious, and optionally migrate to blockchain later.

## Core Principles
1. **Voluntary & consensual** — users choose what to report; no automatic reporting.
2. **Privacy-first** — never publish raw invoice amounts, personal names, or addresses in the open.
3. **Verifiable but pseudonymous** — a reported debt should be attributable to a real invoice in the reporter's books without doxxing either party.
4. **Legally cautious** — clearly label data as "reported by users, not verified by SwiftMaestro"; provide dispute/removal workflow.
5. **Decentralised by design** — no single server holds the authoritative list.

## Data Model (MVP)

### Local Report Record
Stored in the user's own MaestroBooks database before any network share:

```
BlacklistReport
- id (local)
- invoiceID (local reference)
- reportedAt
- reporterPublicKey (or derived identifier)
- debtorFingerprint (hash of business name + tax number + country)
- amountBand (ENUM: <1k, 1k-10k, 10k-50k, 50k-100k, >100k)
- daysOverdueAtReport
- evidenceHash (SHA-256 of invoice PDF + metadata)
- status: pending | published | disputed | withdrawn
```

### Shared Record (gossip/p2p)
When a report is published, only this minimal record leaves the device:

```json
{
  "debtorFingerprint": "sha256:...",
  "reporterFingerprint": "sha256:...",
  "amountBand": "10k-50k",
  "currency": "AUD",
  "daysOverdueAtReport": 67,
  "reportedAt": "2026-09-03T00:00:00Z",
  "evidenceHash": "sha256:...",
  "signature": "..."
}
```

No business names, no ABNs, no email addresses in the shared payload. The fingerprint lets other users check whether a contact they already know matches a reported debtor, without revealing the debtor to the network.

## Matching Flow
1. User A has a contact "Bluegum Builders Pty Ltd" with ABN `63 117 208 944`.
2. SwiftMaestro computes `debtorFingerprint = SHA-256(normalisedName + taxNumber + country)`.
3. The app queries the p2p network for that fingerprint.
4. If a report exists, the app shows: "1 report: 10k-50k AUD, 67 days overdue, reported 2026-09-03".
5. The matching happens entirely locally; the network never learns which contact the user queried.

## Blockchain Path (future)
- Store a Merkle root or anchor hash on a low-cost chain (e.g., Bitcoin OP_RETURN, Ethereum calldata, or a purpose-specific L2).
- Each report gets a timestamp attestation.
- The actual report data lives in a p2p gossip network (e.g., libp2p, BitTorrent DHT, or Nostr with encrypted DM semantics).
- Blockchain provides immutability and ordering; gossip provides availability.

## MVP without Blockchain
For the first version, use a simple gossip protocol:
- SwiftMaestro nodes exchange Bloom filters of debtor fingerprints with peers they trust (Tailscale tailnet, local LAN, or opt-in relay).
- Reports are signed with an Ed25519 key derived from the user's SwiftMaestro identity.
- A small set of community relays (run by WOODSEE-DIGI or volunteers) cache reports and serve fingerprint lookups.

## Dispute & Removal
- A debtor can request removal by contacting the reporter through a privacy-preserving channel.
- Reporters can withdraw their own reports at any time.
- After 7 years, reports automatically expire and are no longer propagated.

## UI/UX
- In MaestroBooks: when an invoice hits 60 days overdue, show a "Report to p2p network" option in the Reminders page.
- In Contacts/Clients and Suppliers: show a risk badge if the contact's fingerprint matches any report; show a banner in the detail/editor view.
- New client/supplier confirmation: if a flagged contact is being created, warn the user and let them save anyway.
- Bulk imports (Xero/QuickBooks CSV/IIF): after import, present a list of flagged contacts with severity so the user can review.
- Per-client toggle: "Allow p2p blacklist reporting for this client". When off, no invoice for that client can be reported.
- Per-invoice override: "Inherit from client", "Allow reporting", or "Do not report this invoice".
- Contact Card (CRM preview): displays the same risk banner for any profile with a matching fingerprint.
- Settings → Privacy: opt-in to participate in the p2p network; generate/export revocation key.

## Verification without exposing ABN/ACN
- A user submits a report to a SwiftMaestro verifier node with full details including ABN/ACN.
- The verifier checks the identifier using:
  1. **Locally-imported ABR weekly bulk extract** (`abr.business.gov.au/Tools/BulkExtract` / `data.gov.au`) for offline, privacy-preserving ABN validation.
  2. **Locally-imported ASIC company extract** (`data.gov.au` under Australian Securities and Investments Commission) for ACN/company validation.
  3. **Live ABN Lookup search** as a fallback/update path for newly-registered or changed entities.
- Raw identifiers are cached only on the verifier's device; they never go on-chain, into gossip, or into shared memory.
- The verifier issues a cryptographic attestation: `"ABN/ACN verified, active, matches name"` — without revealing the identifier.
- That attestation hash/signature goes on-chain or into gossip.
- Public consumers see `ABN_VERIFIED: true` or `ACN_VERIFIED: true` but never see the identifier.

## Open Questions
- Which chain or gossip layer to use?
- Legal review: defamation, GDPR, Australian Privacy Act.
- Incentives: why do nodes relay reports? Reputation? Micro-tipping?
- Sybil resistance: prevent fake reports. Require a small stake? Proof of past paid invoices?

## Next Steps
1. Legal review of report schema and UI wording.
2. Prototype gossip protocol using libp2p or Nostr.
3. Design key management and revocation flow.
4. Build reporter UI behind an explicit opt-in.
