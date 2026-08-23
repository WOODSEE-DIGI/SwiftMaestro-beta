# Media Player — Work Handover

**Date:** 2026-08-23  
**Status:** Phases 1-6 complete (build succeeded). Phase 7 written but needs clean rebuild.  
**Next agent:** Continue from Phase 7 verification.

---

## What Was Built

A BTOP+-styled multimedia player panel integrated into SwiftMaestro's flexible panel system. AVKit-backed playback with the retro phosphor-on-black aesthetic from `RetroAudioViews.swift`.

### New Files (9)

| File | Path | Lines | Purpose |
|------|------|-------|---------|
| **MediaPlayerEngine.swift** | `Sources/Services/` | ~240 | Core AVKit playback engine. Singleton. Play/pause/seek, time observation via `addPeriodicTimeObserver`, metadata extraction (title/artist/artwork/format/sample rate/channels/resolution/file size), audio tap integration for live spectrum. |
| **MediaPlayerQueue.swift** | `Sources/Services/` | ~280 | Playlist manager. Append/insert/remove/reorder, shuffle/repeat (off/one/all), next/previous navigation, disk persistence to `~/Library/Application Support/SwiftMaestro/data/media-player/queue.json`. |
| **MediaPlayerAudioTap.swift** | `Sources/Services/` | ~90 | Bridges `AVPlayerItem` audio output to `SpectrumAnalyzer` via `AVAudioTap`. Lock-free atomic snapshot for main-thread UI consumption. Peak-hold caps with slow decay. |
| **MediaPlayerView.swift** | `Sources/Views/MediaPlayer/` | ~200 | Main container. Combines now-playing card, visualization, progress, transport, volume, playlist, speed selector. Drag-drop + file picker support. |
| **MediaPlayerTransportView.swift** | `Sources/Views/MediaPlayer/` | ~100 | Retro transport buttons. Seek ±15s, skip, play/pause with glow-on-hover. |
| **MediaPlayerProgressBar.swift** | `Sources/Views/MediaPlayer/` | ~90 | Segmented progress bar. 60 zone-colored segments, white position marker, time readout, click-to-seek. |
| **MediaPlayerVolumeView.swift** | `Sources/Views/MediaPlayer/` | ~80 | Retro volume slider. Segmented bar, mute toggle, dB readout. |
| **MediaPlayerVisualization.swift** | `Sources/Views/MediaPlayer/` | ~100 | Spectrum analyzer + waveform display wrapping existing `RetroSpectrumMeter`. |
| **MediaPlayerInfoView.swift** | `Sources/Views/MediaPlayer/` | ~120 | Media metadata readout. Title, artist, format, size, resolution, sample rate, channels in monospace. |

### Modified Files (3)

| File | Change |
|------|--------|
| `Sources/Views/WorkspaceLayoutState.swift` | Added `case mediaPlayer` to `WorkspacePanelKind` enum + all 5 computed properties (icon, themeStorageKey, staticDisplayName, storageKey — `minColumnWidth` uses default 320). |
| `Sources/Views/WorkspacePanelContentView.swift` | Added `.mediaPlayer → MediaPlayerView()` case to the content switch. |
| `Sources/Services/AppEnablementStore.swift` | Added `.mediaPlayer` to `.swiftApps` category array and `appCategory` computed property. |

---

## Build Issues Fixed

The initial build (Phases 1-6) succeeded after fixing these errors:

1. **`UTType.aiffAudio` not found** — Removed from `mediaTypes` array. Not a standard UTType on macOS 14.
2. **`mutation of captured var in concurrently-executing code`** — `handleDrop` closure captured `urls` array from outer scope. Fixed with `NSLock` around append.
3. **Type-check timeout on complex expression** — `sin(Date().timeIntervalSince1970 * 2.0 + Double(band) * 0.3)` in a `.map` closure. Fixed by extracting `time` and `phase` into local `let` bindings.
4. **`QueueData` not `Codable`** — `RepeatMode` was a nested enum inside `MediaPlayerQueue` (an `@Observable @MainActor` class). Moved to top-level `MediaPlayerRepeatMode` enum.
5. **`deinit` can't reference `self` in `@MainActor` class** — Removed time observer cleanup from `deinit` (player deallocation handles it).
6. **`AVAsset.url` not accessible** — In newer AVFoundation, `.url` is not an `AVAsyncProperty`. Used `currentURL` (the URL passed to `load()`) instead.
7. **`loadTracks(withMediaType:)` throws** — Added `try?` to async track loading calls.
8. **`trackRow` opaque return type** — `let` binding at top level confused type inference. Extracted to `@ViewBuilder trackRowContent()` helper.

---

## Architecture Notes

### Panel Registration Pattern
Every panel in SwiftMaestro follows this checklist:
1. Add `case` to `WorkspacePanelKind` enum in `WorkspaceLayoutState.swift`
2. Add entries to all 5 switch statements: `icon`, `themeStorageKey`, `staticDisplayName`, `storageKey` (and optionally `minColumnWidth`)
3. Add view mapping in `WorkspacePanelContentView.swift`
4. Add to `AppCategory.kinds` array in `AppEnablementStore.swift`
5. Add to `appCategory` computed property in same file
6. Run `./scripts/gen-project.sh` (new .swift file needs project regen)

### Engine Singleton
`MediaPlayerEngine.shared` is `@Observable @MainActor`. The `MediaPlayerAudioTap` runs its FFT on the real-time audio thread and publishes results via `NSLock`-guarded snapshot. The UI timer (0.06s interval) calls `engine.refreshSpectrum()` to pull the latest data.

### BTOP+ Aesthetic
All UI uses `RetroPalette` from `RetroAudioViews.swift`:
- `green` (0.20, 1.00, 0.35) — primary accent, healthy levels
- `amber` (1.00, 0.75, 0.20) — warning/mid zone
- `red` (1.00, 0.30, 0.25) — clipping/peak zone
- `dim` (0.10, 0.16, 0.10) — inactive segments
- `background` (white: 0.055) — panel background
- CRT scanlines via `.retroScanlines()` modifier
- Monospace fonts throughout via `.font(.caption2.monospaced())`

---

## Remaining Work

### Phase 7: Live Spectrum Visualization (IN PROGRESS)
**File written:** `MediaPlayerAudioTap.swift`  
**Engine updated:** `MediaPlayerEngine.swift` now has `audioTap`, `refreshSpectrum()`, `spectrumBands`, `spectrumCaps`  
**View updated:** `MediaPlayerView.swift` now uses `engine.spectrumBands` and `engine.spectrumCaps`  

**Status:** Build timed out due to derived data lock. Needs:
1. Delete build DB: `rm -f ~/Library/Developer/Xcode/DerivedData/SwiftMaestro-byyblsitlhcauycfeghuroqdagov/Build/Intermediates.noindex/XCBuildData/build.db`
2. Rebuild: `xcodebuild -project SwiftMaestro.xcodeproj -scheme SwiftMaestro -configuration Debug -destination "platform=macOS" build`
3. If `AVAudioTap` is not available on macOS 14 deployment target, gate with `#available(macOS 15, *)` and fall back to simulated spectrum

**Potential issue:** `AVAudioTap` was introduced in macOS 15 / iOS 18. If it's not available, alternatives:
- Use `AVPlayerItem`'s audio output via `AVAudioEngine` tap (more complex but works on macOS 14)
- Or just keep the simulated spectrum as a placeholder

### Phase 8: Keyboard Shortcuts
Add to `MediaPlayerView`:
- Space → play/pause
- Left arrow → seek -15s
- Right arrow → seek +15s
- Up arrow → volume +5%
- Down arrow → volume -5%
- Cmd+O → open file picker
- Cmd+L → clear queue
- N → next track
- P → previous track

Use `.onKeyPress` modifier (macOS 14+).

### Phase 9: FFmpeg Fallback
The `MediaPlayerFormat.needsFFmpeg()` check exists but no handler. Need:
- Probe files via `ffprobe` to detect unsupported formats
- Use `FFmpegService` (already bundled) to transcode to a temp file
- Load the temp file into AVPlayer
- Clean up temp files on stop/quit

### Phase 10: Video Playback
- Add `AVPlayerView` (AppKit) wrapped in `NSViewRepresentable`
- Show video view when media has video tracks (`engine.mediaInfo.hasVideo`)
- Hide visualization/waveform when video is showing
- Support fullscreen toggle

### Phase 11: Agent Tools
Add to `MaestroTools+MediaPlayer.swift`:
- `play_media(path: String)` — load and play a file
- `pause_media()` — pause playback
- `resume_media()` — resume playback
- `seek_media(seconds: Double)` — seek to position
- `set_volume(level: Double)` — set volume 0-1
- `list_media_queue()` — show current queue
- `add_to_queue(path: String)` — add file to queue

Register in `MaestroTools.swift` dispatch table.

---

## Key Files to Read First

If picking up this work, read these in order:
1. `Sources/Services/MediaPlayerEngine.swift` — core engine
2. `Sources/Services/MediaPlayerQueue.swift` — playlist management
3. `Sources/Services/MediaPlayerAudioTap.swift` — spectrum bridge (new, needs build check)
4. `Sources/Views/MediaPlayer/MediaPlayerView.swift` — main UI
5. `Sources/Views/RetroAudioViews.swift` — the BTOP+ aesthetic palette/components
6. `Sources/Services/SpectrumAnalyzer.swift` — FFT engine used by the audio tap

---

## Commands

```bash
# Regenerate project after adding/removing files
./scripts/gen-project.sh

# Build
xcodebuild -project SwiftMaestro.xcodeproj -scheme SwiftMaestro -configuration Debug -destination "platform=macOS" build

# If build DB is locked
rm -f ~/Library/Developer/Xcode/DerivedData/SwiftMaestro-byyblsitlhcauycfeghuroqdagov/Build/Intermediates.noindex/XCBuildData/build.db
```
