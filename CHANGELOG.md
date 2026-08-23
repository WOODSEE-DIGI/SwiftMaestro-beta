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

## Fixes

- **macOS 14/15 launch crash fixed** — an unused hard link to the PaperKit framework (macOS 26+ only) crashed the app on launch for Sonoma/Sequoia users. Both installers now launch correctly on macOS 14+.

# SwiftMaestro 0.3.9

## Mechanic — built-in support engineer

- **Mechanic agent** (Agents panel, under Maestro): SwiftMaestro's support specialist — diagnoses internal problems via the crash watchdog + self-healing logs, helps configure MCP servers, and restores the app to its last known working condition.
- **Bundled Qwen3-4B support model** (in BOTH installers, ~2.1 GB): help works on fresh installs with nothing else configured. This build ships the first fine-tuned specialist (LoRA-trained on the project's own runbooks + failure log — see scripts/mechanic-training/).
- **Git-referenced reset**: versioned config history (settings + MCP registry committed to a local offline git repo on every backup) with restore-any-point; the Mechanic can also fetch an earlier release DMG for guided reinstall.

## ToolCallGuardian — self-healing tool calls

- Tool failures are classified and self-healed: transient faults (locked DB, network hiccups) retry automatically; other errors return to the agent with prescriptive recovery hints so it routes around them instead of failing silently.
- Fixes that heal the same failure twice are learned per model and applied pre-emptively — new external models (LM Studio, Ollama, online) calibrate themselves.
- Settings → Self-Healing shows heal rates, learned quirks, and the failure log; agents can self-report via self_healing_stats / self_healing_failures.

## Retro audio metering + EQ

- Audio Control gains a live input monitor: 24-band spectrum analyzer + segmented VU level bar with peak-hold — btop-style phosphor graphics with scanlines and VU ballistics.
- 8-band retro EQ (60 Hz–15 kHz, ±12 dB) with presets, applied to the Voice Notes recording chain; Voice Notes shows a live spectrum strip while recording.

## Pomodoro title-bar clock

- Omarchy-style top-center clock in the main window: remaining time with per-state tint, hover for stats, left-click opens the dashboard panel, right-click for controls.

## Fixes

- **Memory guard**: evicts resident models before refusing a load — a 128 GB machine no longer refuses a 26 GB model while an unused 65 GB model sits resident.
- Audio monitor threading/exclusivity crashes; SF Symbol rendering in the Tagging workspace; title-bar timer render churn.
