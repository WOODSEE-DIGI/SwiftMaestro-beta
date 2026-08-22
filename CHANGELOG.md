# SwiftMaestro 0.3.8

## MaestroDAM — AI-assisted tagging that learns as you tag

- **New Tagging workspace**: tag a few images and SwiftMaestro suggests the same tags on similar images — review and accept/reject in a queue. Every accepted tag teaches the engine further.
- **On-device matching**: Apple Vision OCR (full text per image, instantly searchable) + visual similarity fingerprints. No cloud, no training runs — the exemplar pool is the model.
- **Lightroom catalog CSV import**: ratings, pick flags, color labels, capture dates, and keywords all land in the catalog. Lightroom keywords become instant AI exemplars, custom label sets become semantic tags, and the Lightroom folder tree is rebuilt as DAM collections. Works with offline volumes.
- **Agent tools**: `dam_ai_index`, `dam_tag_apply`, `dam_tag_suggestions`, `dam_tag_resolve`, `dam_find_similar`, `dam_relearn`, `dam_import_lightroom` — agents can drive the whole tagging loop.

## Two installers

- **Full** — Gemma 4 26B + WhisperKit bundled. Self-contained, nothing to download.
- **Light (new)** — WhisperKit bundled; for Macs under 32 GB. Use online models or connect to LM Studio (local network hosts supported) instead of the bundled Gemma 4.

## Also in this release (0.3.7 features)

- **Blocky + Stocks investigations** — GRDB-backed investigation panels with agent tools and MaestroDB sync.
- **Obsidian-class Web Clipper** — full metadata capture, templates, Wayback-grade asset archiving.
- **SwiftWeaver HTML Builder** — visual HTML editor with live preview.
