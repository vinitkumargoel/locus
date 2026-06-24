# v1 Task Breakdown — Thin End-to-End Vertical Slice

**v1 goal:** detect meeting → consent prompt → dual-stream capture → live transcript (Parakeet) →
save to library → manual summary with **one** template via the user's LLM endpoint.
Speakers: **You** vs **Speaker N** (no voiceprint yet).

**Sequencing principle:** retire the riskiest unknown (audio capture) *before* building UI on top of it.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · ⚠ = risk gate

---

## Phase 0 — Project setup
- [ ] Decide app name + bundle identifier (see DESIGN §18).
- [ ] Sort **Apple Developer ID** signing identity + notarization workflow (do this early — see R5).
- [ ] Create Xcode project: SwiftUI, macOS 14.2+, Apple-Silicon, menu-bar + window scenes.
- [ ] Add deps: **GRDB.swift**, **FluidAudio** (eval first), audio utils.
- [ ] Wire Hardened Runtime + Info.plist usage strings (mic, audio capture).
- [ ] Basic CI: build + lint.

## Phase 1 — Capture spike ⚠ (the make-or-break milestone)
- [ ] **Spike: CoreAudio Process Tap** on a target PID → pull far-end audio to 16 kHz mono.
      Reference: `ownscribe`, `RecapAI/Recap`.
- [ ] Confirm exact **TCC permission** the tap requires on 14.2 vs 14.4; wire the request flow. ⚠
- [ ] **Mic capture** via AVAudioEngine → 16 kHz mono, separate track.
- [ ] Shared timestamp clock across both tracks.
- [ ] **Decision gate:** if process taps are unreliable, switch to ScreenCaptureKit fallback
      (`tonton-golio/meeting-recorder`, `Parrot`) before proceeding. ⚠
- [ ] Write captured tracks to compressed AAC/Opus files (validate playback).
- [ ] **Flush audio incrementally** (don't hold a whole meeting in memory) so a crash leaves a salvageable file. ⚠ (R7)
- [ ] Detect **far-end silent** (no Track-A frames for N s) — system-audio auth can't be queried, so this is the only signal. ⚠ (R6)

## Phase 2 — Detection + consent
- [ ] App registry (Zoom `us.zoom.xos`, Slack `com.tinyspeck.slackmacgap`).
- [ ] Process watcher + **CoreAudio audio-activity** signal per process.
- [ ] Debounce (sustained activity > ~3 s) to avoid notification-sound false positives.
- [ ] Verify Slack-huddle fires via audio-I/O state (not window). ⚠
- [ ] Consent prompt: **[Record] [Ignore]** + "always record this app" memory (`app_consent` table).
- [ ] Default-deny: meeting ends / prompt expires before a choice → no recording. Concurrent meeting → queue prompt (don't overwrite).
- [ ] Menu-bar indicator (idle / armed / recording / **capture-error** / **permission-missing**) + manual start/stop/pause.

## Phase 3 — Live transcription (Parakeet)
- [ ] Evaluate **FluidAudio Parakeet** streaming latency/accuracy on real audio. ⚠ (R3)
- [ ] `STTEngine` protocol + `ParakeetEngine` (live `transcribeStream`).
- [ ] Chunked rolling-window inference per track → `TranscriptChunk` stream.
- [ ] Merge two tracks into a single time-ordered transcript; label mic track = **You**.
- [ ] Basic remote-speaker split via FluidAudio embeddings → **Speaker N** (provisional).

## Phase 4 — Persistence + Library + Live UI
- [ ] GRDB schema (DESIGN §12): `meeting`, `speaker`, `segment`, `app_consent`.
- [ ] Persist meeting + segments (live rows) + audio file paths.
- [ ] **Crash-recovery on launch:** salvage any `recording`/`processing` meeting, finalize, mark `recovered`. (R7)
- [ ] **Live tab:** real-time transcript, who's-speaking, controls, elapsed timer.
- [ ] **Library tab:** list past meetings (date/app/duration), open, delete.
- [ ] **Detail tab:** transcript + audio playback + inline speaker rename.

## Phase 5 — Summaries (one template)
- [ ] OpenAI-compatible client: `POST /v1/chat/completions`, `GET /v1/models`.
- [ ] **Settings:** Base URL + API Key (Keychain) + Model picker.
- [ ] Ship **one** built-in template (Long Summary) with variables + Markdown output.
- [ ] **Map-reduce** for transcripts exceeding model context; single-shot otherwise.
- [ ] LLM **error taxonomy**: transient (timeout/conn-refused/5xx → retry) vs permanent (bad URL/auth/model-not-found → fix in Settings).
- [ ] **Summarize** button in Detail → render + persist (`summary` table, with `template_name` snapshot).

## Phase 6 — Export + model delivery + polish
- [ ] Export transcript/summary to **Markdown / TXT** + **copy to clipboard** (PDF deferred).
- [ ] **Model download-on-first-run** with size/quality picker + progress + checksum + cache.
- [ ] Retention setting (keep forever | auto-delete after N days).
- [ ] First-run consent/disclaimer screen.
- [ ] **Zoom-like theme** pass on Live + Detail + summary surfaces.
- [ ] Sign + **notarize** `.dmg`; smoke-test install on a clean machine.

---

## Deferred to v1.x+ (tracked, not built in v1)
Whisper fallback engine · post-meeting **refine pass** + global diarization · **voiceprint** cross-meeting
memory · multiple/custom templates + template editor · **PDF** export · multilingual (Parakeet v3) ·
Google Meet / MS Teams detection · Notes/Slack/email integrations · Sparkle auto-update · Intel support.

**Robustness (from the edge-case pass — v1 ships only the minimum-honest version noted in DESIGN §17):**
disk-space pre-flight + low-space watcher · **stop & discard** · capture **auto-retry/backoff** + device-change
re-establish + **gap-marking** · single-track degrade (mic-only / far-end-only) · **disk-full** pause-to-protect ·
map-reduce **per-chunk retry** · **summary-stale** flag on transcript edits · mid-session **permission-revocation**
handling · audio-missing Detail state · Library sort + `recovered`/`processing` rows.

> **v1 minimum-honest failure bar (must-have, already folded into the phases above):** never record
> without consent (default-deny), never silently lose a captured recording (incremental flush + launch
> recovery), and always show whether audio is being captured (menu-bar capture-error/permission states).

---

## Milestones
- **M1 — Capture proven:** Phases 0–1 (audio from Zoom + mic, two clean tracks). *Biggest risk retired.*
- **M2 — Records meetings:** + Phases 2–4 (detect → consent → live transcript → saved + browsable).
- **M3 — v1 feature-complete:** + Phases 5–6 (summary + export + model download + theme + notarized build).
