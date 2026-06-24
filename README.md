<div align="center">

<img src="Locus/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Locus app icon" />

# Locus

**Offline meeting transcription for macOS.**
Detects Zoom meetings & Slack huddles, asks permission, and produces a live, speaker-attributed transcript — then templated summaries via a model you control. Fully on-device.

</div>

---

## Status

Native SwiftUI front-end **plus a real backend engine** wired in behind a service layer. `AppState` is no longer a mock state machine — it's a coordinator over nine injected services (`Locus/Services/`), and every screen reads service-backed data. The app builds clean (0 warnings) and runs on the real engine.

**Functional today (fully local, exercisable now):**
- **Persistence** — GRDB/SQLite store with FTS5 full-text search over titles + transcripts, crash-recovery candidates, retention, cascade deletes. Library, detail, and search are real.
- **Summaries** — streaming OpenAI-compatible client (`/v1/chat/completions` + `/v1/models`), template rendering, map-reduce for long transcripts, transient-vs-permanent error taxonomy. Point it at Ollama/LM Studio/llama.cpp.
- **Settings** — endpoint/key/model (API key in the **macOS Keychain**), STT model choice, detection + per-app consent, retention, all persisted.
- **Detection** — Zoom/Slack process + audio-activity watcher driving the consent flow.

**Implemented in real code, pending on-device validation** (can't be exercised in CI — they need TCC grants, a live meeting, and a ~hundreds-of-MB model download):
- **Capture** — CoreAudio process-tap (far-end) + AVAudioEngine (mic), 16 kHz mono, incremental `.m4a` flush, far-end-silence / device-change handling.
- **Transcription** — Parakeet TDT via [FluidAudio](https://github.com/FluidInference/FluidAudio) (live `SlidingWindowAsrManager` + batch refine).
- **Diarization** — FluidAudio offline pipeline, merged into the saved transcript.

See [`DESIGN.md`](DESIGN.md) for the architecture and [`TASKS.md`](TASKS.md) for the build plan.

## Features (UI complete)

- **Menu-bar agent** with always-visible recording status + quick controls.
- **Consent-first capture** — default-deny; nothing records until you tap *Record*. Per-app Ask / Always / Never.
- **Live transcript** — speaker-attributed lines, input meters, listening / capture-error / paused states.
- **Library** of recordings with search.
- **Recording detail** — transcript with inline speaker rename + playback, and a **summary** panel with templates (Long Summary, One-on-One, Action Items & Decisions, Quick Notes, custom).
- **Settings** — detection rules, on-device STT models, your own AI endpoint (base URL + key + model), template editor, storage/retention, permissions.

## Tech

- **SwiftUI**, macOS 14.4+, Apple Silicon, **non-sandboxed** + Hardened Runtime (the App Sandbox blocks CoreAudio process taps; distribution is Developer ID + notarization, not the App Store).
- A single `@MainActor AppState` coordinates nine protocol-typed services (`Locus/Services/Contracts.swift`); `Services.live()` wires the real engine, `Services.preview()` wires mocks for SwiftUI previews.
- Dependencies (SPM): **[FluidAudio](https://github.com/FluidInference/FluidAudio)** (Parakeet ASR + diarization, CoreML/ANE) and **[GRDB.swift](https://github.com/groue/GRDB.swift)** (SQLite + FTS5).
- Project is generated with **[XcodeGen](https://github.com/yonsson/XcodeGen)** from [`project.yml`](project.yml) (the source of truth — the `.xcodeproj` is git-ignored).

## Build & run

```bash
# one-time: install the project generator
brew install xcodegen

# generate the Xcode project and open it
xcodegen generate
open Locus.xcodeproj
# then Build & Run (⌘R)
```

Or from the command line:

```bash
xcodegen generate
xcodebuild -scheme Locus -configuration Debug build
```

## Project structure

```
Locus/
  LocusApp.swift                 # @main — MenuBarExtra agent + main Window
  Support/                       # Theme, Models + SampleData, AppState (coordinator), Components
  Services/                      # Contracts (protocols) + live engine + mocks
    Capture/ Transcription/ Diarization/ Persistence/ Summaries/ Detection/ System/
  MenuBar/MenuBarAgentView.swift # status item + popover
  Windows/MainWindowView.swift   # sidebar + screen router + consent overlay
  Overlays/ConsentPromptView.swift
  Screens/                       # Library, Live, RecordingDetail, Settings (+ Detail/, Settings/)
  Assets.xcassets/               # AppIcon
project.yml                      # XcodeGen manifest
DESIGN.md · TASKS.md · FUNCTIONAL_SPEC.md
```

The UI was implemented from a Claude Design prototype (`Locus.dc.html`).
