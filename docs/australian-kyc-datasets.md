# Australian Government Datasets for KYC / Verification

> A working list of Australian public registers and bulk datasets that SwiftMaestro can use to verify businesses and individuals before they are reported through the P2P unpaid-invoice blacklist.
> 
> The goal is **offline-first, privacy-preserving verification**: import the bulk extracts once, verify on-device, and only publish blind attestations to the network.

---

## Core business identity datasets

| Dataset | Source | Update frequency | Key fields | KYC use |
|---|---|---|---|---|
| **ABN Bulk Extract** | [data.gov.au](https://data.gov.au/data/dataset/abn-bulk-extract) | Weekly snapshot | ABN, ABN status/date, entity type, legal name, business/trading names, state/postcode of main business location, ACN/ARBN, GST status, DGR status | Confirm the ABN exists, is active, and matches the supplied business name. |
| **ABN Lookup Web Service** | [abr.business.gov.au/Webservices.aspx](http://abr.business.gov.au/Webservices.aspx) | Live lookup | Same as above plus current details | Fallback when the bulk extract is stale or missing; requires a free GUID. |
| **ASIC Company Dataset** | [data.gov.au](https://data.gov.au/data/dataset/asic-companies) | Weekly (Tuesdays) | Company name, ACN, type/class/sub-class, status, registration/deregistration dates, ABN, current name and start date | Verify the company is registered and has not been deregistered; cross-check ACN ↔ ABN. |
| **ASIC Business Names Dataset** | [data.gov.au](https://data.gov.au/data/dataset/asic-business-names) | Weekly (Wednesdays) | Business name, status, registration/cancellation dates, renewal date, former state number, ABN | Match a trading name to its underlying ABN/legal entity. |

---

## Risk / regulatory status datasets

| Dataset | Source | Update frequency | Key fields | KYC use |
|---|---|---|---|---|
| **Banned and Disqualified Persons** | [data.gov.au](https://data.gov.au/data/dataset/asic-banned-disqualified-per) | Weekly (Tuesdays) | Person name, type, document number, start/end dates, address locality/state/postcode/country, comments, register name | Flag if a director or controller is disqualified or banned from AFS/credit industries. |
| **Credit Licensee Dataset** | [data.gov.au](https://data.gov.au/data/dataset/asic-credit-licensee) | Weekly (Thursdays) | Licensee number/name, status, issue/cease dates, ABN/ACN, AFSL number, authorisations, principal business address | Verify a credit provider is licensed (useful for finance/trade-credit clients). |
| **AFS Licensee Dataset** | [data.gov.au](https://data.gov.au/data/dataset/asic-afs-licensee) | Weekly (Thursdays) | AFS licence number, licensee name, ABN/ACN/ARBN, issue date, principal business address, licence conditions | Verify a financial-services business is licensed. |
| **Financial Advisers Dataset** | [data.gov.au](https://data.gov.au/data/dataset/asic-financial-adviser) | Weekly | Adviser name/number, role, status, ABN, licence details, disciplinary actions, product authorisations | Verify an individual adviser is registered and has no active disciplinary actions. |
| **Liquidator Dataset** | [data.gov.au](https://data.gov.au/data/dataset/asic-liquidator) | Weekly (Fridays) | Liquidator number/name, status, suspension date, principal business address, firm membership | Useful when verifying insolvency-related correspondence. |
| **ACNC Registered Charities** | [data.gov.au](https://data.gov.au/data/dataset/acnc-register) | Weekly | Charity name, ABN, registration status, charity subtype, state, operating countries | Verify a not-for-profit / charity client. |
| **ASIC Insolvency Notices** | [publishednotices.asic.gov.au](https://publishednotices.asic.gov.au/) | Daily / as published | Appointment of administrators, liquidators, receivers | Stronger risk signal than a single unpaid invoice; not a bulk data.gov.au dataset. |

---

## How these fit into SwiftMaestro

1. **Bulk import UI** in the P2P Blacklist page (or Settings → Verification).  
   User points SwiftMaestro at the downloaded CSV/TSV/ZIP files; the app parses them and stores only the fields it needs locally.
2. **Verification at report time.** When a debtor ABN/ACN is entered, SwiftMaestro checks, in order:
   - local format checksum (ABN/ACN)
   - imported ABR bulk extract
   - imported ASIC company/business-name extracts
   - live ABN Lookup fallback (if enabled and a GUID is supplied)
3. **Blind attestation.** If verification passes, the published P2P record only says `abn-verified: true`, `acn-verified: true`, etc. The raw identifier never leaves the device.
4. **Risk flags.** Optional ASIC datasets (banned/disqualified, insolvency notices) can add red/yellow badges to a contact card even before an invoice becomes overdue.

---

## Privacy, licensing and legal notes

- **Licensing:** most ASIC/ABR datasets on data.gov.au are published under **Creative Commons Attribution 3.0 Australia** (CC BY 3.0 AU). SwiftMaestro should display attribution in the UI/about page.
- **No redistribution of raw identifiers.** The datasets are public, but the P2P blacklist design deliberately does **not** republish names, ABNs, or ACNs into the gossip network. Only hashed fingerprints and blind verification flags are shared.
- **Point-in-time snapshots.** Bulk extracts are updated weekly; for time-sensitive decisions, use the live ABN Lookup web service or ASIC Connect.
- **Defamation / accuracy.** A verified ABN only proves the entity existed and was active at the snapshot date. It does not prove the debt is valid. UI copy must keep these distinctions clear.

---

## Suggested implementation order

1. ABN Bulk Extract importer + live ABN Lookup JSON web service.
2. ASIC Company + Business Names extract importers.
3. Banned/Disqualified Persons + Organisations importers for risk flags.
4. Credit Licensee / AFS Licensee / Financial Adviser importers (sector-specific verification).
5. ACNC charities importer.
6. Optional: ASIC Insolvency Notices feed (RSS/Atom or scrape/API) for real-time risk signals.
