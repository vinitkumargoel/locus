# Meeting Transcriber — Design Document

> **Working title:** TBD (placeholder: *HuddleScribe*). A macOS, fully-offline meeting
> transcription + summarization app for Zoom meetings and Slack huddles.
>
> **Status:** Design locked (2026-06-24). v1 = thin end-to-end vertical slice.

---

## 1. Product summary

A native macOS menu-bar + windowed app that:

1. Detects when a **Zoom meeting** or **Slack huddle** starts and **asks permission** to record.
2. Captures **both sides** of the conversation locally (the far-end participants + your own mic).
3. Produces a **live, speaker-labeled transcript** on-device (no audio ever leaves the machine).
4. Saves every meeting to a **recordings library** with audio playback + transcript.
5. Generates **summaries from editable templates** (Long Summary, One-on-One, Action Items, Quick Notes) via a **user-configured local LLM** (any OpenAI-compatible endpoint).
6. Stays **fully offline** end-to-end (STT on-device; summary LLM points at a local server).

Visual goal: a **Zoom-like theme** for the transcript + summary surfaces.

---

## 2. Non-negotiable constraints

- **Fully offline.** No telemetry, no cloud STT. The only network calls are (a) one-time model
  downloads and (b) requests to the user's *own* configured LLM endpoint (typically `localhost`).
- **Explicit consent.** Nothing is recorded without the user's choice (per-meeting prompt, with an
  optional per-app "always record" memory).
- **Local-only storage.** All audio, transcripts, and summaries live under `~/Library/Application Support`.
- **No App Store.** The sandbox would block the audio-capture path (see §13).

---

## 3. Target platform & hardware

| Dimension | Decision | Rationale |
|---|---|---|
| OS | **macOS 14.2+** (Sonoma), likely **14.4+** | CoreAudio Process Taps API requires 14.2, but the *documented* "any app can capture other apps' audio" path (the `NSAudioCaptureUsageDescription` consent prompt) landed in **14.4**. Lean toward a **14.4 floor** unless the spike proves 14.2 is reliable. *Confirm in the capture spike.* |
| CPU | **Apple Silicon only** (v1) | Parakeet (CoreML) + FluidAudio are Apple-Silicon. Intel could get a Whisper-only path later. |
| Distribution | Developer ID-signed + **notarized** `.dmg` | App Store sandbox blocks process taps. Requires Apple Developer account ($99/yr). |

---

## 4. Architecture overview

Native **SwiftUI** app. Suggested module layout (Swift packages / targets):

```
HuddleScribe.app
├─ App/                  SwiftUI app entry, menu-bar agent, window scenes
├─ Detection/           meeting detection (bundle-ID + audio-activity)
├─ Capture/             dual-stream audio capture (CoreAudio tap + mic)
├─ Transcription/       pluggable STT (STTEngine protocol)
│   ├─ ParakeetEngine   (FluidAudio)            ← default
│   └─ WhisperEngine    (WhisperKit / whisper.cpp) ← fallback
├─ Diarization/         speaker clustering + voiceprint library (FluidAudio)
├─ Pipeline/            live streaming + post-meeting refine orchestration
├─ Summaries/           template engine + OpenAI-compatible LLM client + map-reduce
├─ Persistence/         GRDB (SQLite) + audio file store + retention
├─ Models/              model registry, download manager, cache
├─ Export/              Markdown / PDF / TXT / clipboard
└─ Settings/            LLM config, engine select, templates editor, retention, Keychain
```

**High-level data flow:**

```
Detection ─► Consent prompt ─► Capture (2 tracks) ─┬─► live STT chunks ─► Live transcript UI
                                                    │
                          (on stop) Refine pass ◄───┘
                                    │
                          Diarization (global) ─► final transcript ─► Persistence
                                                                          │
                                            User clicks "Summarize" ──────┘
                                                    │
                                    Template + map-reduce ─► LLM endpoint ─► Summary ─► Persistence
```

---

## 5. Locked decisions (index)

| Area | Decision |
|---|---|
| Platform | macOS only, Apple Silicon, floor macOS 14.2+ (lean 14.4 — see §3) |
| Framework | Native SwiftUI |
| Audio capture | Dual-stream: **CoreAudio process tap** (far-end) + **AVAudioEngine mic** (you) — separate tracks |
| Detection | Hybrid: known **bundle-IDs + live audio-activity**; no Accessibility permission |
| Consent | Prompt Record/Ignore + "remember per app" + menu-bar indicator + manual start/stop/pause |
| STT engine | **Parakeet (FluidAudio/CoreML)** default, **Whisper** fallback — pluggable `STTEngine` |
| STT timing | **Live streaming** + **post-meeting refine pass** + global diarization |
| Speakers | "You" from mic track; remote = embedding clusters; inline rename; **voiceprint memory** |
| Summaries | **OpenAI-compatible** endpoint (base URL + key + model via `/v1/models`); key in **Keychain**; **map-reduce** for long transcripts |
| Templates | Curated, **fully editable** presets + custom |
| Storage | **SQLite (GRDB)** + **compressed audio** (AAC/Opus); configurable retention; all local |
| App shell | Menu-bar agent + main window (Library · Live · Detail · Settings) |
| Model delivery | **Download-on-first-run** with size/quality picker, cached locally |
| Export | **Markdown / PDF / TXT** + clipboard |
| Distribution | Developer ID-signed + notarized; **not** App Store |
| v1 scope | Thin end-to-end vertical slice (see §14) |

---

## 6. Audio capture (the hardest subsystem)

**Strategy: two independent tracks**, never pre-mixed:

- **Track A — far-end participants:** a **CoreAudio Process Tap** on the meeting app's process
  (`CATapDescription` → `AudioHardwareCreateProcessTap` → aggregate device).
  - Driver-free (no BlackHole), audio-only, per-process, low overhead.
  - Targets the specific PID (Zoom helper / Slack), so unrelated audio (music, notifications) is excluded.
- **Track B — your voice:** an **AVAudioEngine** input tap on the default mic.

**Why two tracks:** Track B is unambiguously "You" → diarization only has to cluster Track A.

**Both tracks** are resampled to **16 kHz mono** (STT input format), timestamped against a shared
clock, and (optionally) persisted compressed.

**Permissions:** microphone (`NSMicrophoneUsageDescription` + `com.apple.security.device.audio-input`)
and the system-audio capture TCC (`NSAudioCaptureUsageDescription`). **Spike item:** confirm exactly
which TCC category the process tap triggers on 14.2 vs 14.4 (this is the #1 unknown — see §12).

> **Critical capture edge case:** unlike microphone access, the **system-audio tap authorization
> cannot be queried** via an API. If the user denies it, the tap simply returns **silence** and the
> app has no way to read the permission status. Therefore far-end loss must be detected *behaviorally*
> — "no audio frames on Track A for N seconds" — and surfaced as the `farEndSilent` state (offer
> continue-mic-only / stop / open System Settings). The app must never assume the far-end is being
> captured just because the tap was created.

**References:** `ownscribe` (CLI, CoreAudio taps + mic, macOS 14.2+), `RecapAI/Recap` (SwiftUI,
CoreAudio taps). Fallback path if process taps prove unreliable: **ScreenCaptureKit** system audio
(macOS 13+, needs Screen-Recording permission) — references `tonton-golio/meeting-recorder`, `Parrot`.

---

## 7. Meeting detection

**Hybrid signal — both must be true:**

1. **Bundle-ID match** for a known app in an extensible registry:
   - Zoom: `us.zoom.xos` (and helper `us.zoom.xos`/`CptHost`)
   - Slack: `com.tinyspeck.slackmacgap`
   - (later: Google Meet, MS Teams)
2. **Live audio activity** on that process — detected via CoreAudio (process is actively doing
   audio I/O). "App running" alone is too noisy (Zoom/Slack run constantly).

**Slack huddles** are not a separate process — a huddle surfaces as Slack entering an **active audio
I/O state**. Detection keys off that, not a window. (Reference for the auto-record-on-detect UX:
`pasrom/meeting-transcriber`.)

**Debounce:** require sustained audio activity (e.g. > 3 s) before firing, to ignore notification chimes.

**No Accessibility permission** required (window-title detection is rejected as brittle/locale-fragile).

---

## 8. Consent & recording flow

- On detection → prompt: **[Record] [Ignore]** with an optional **"Always record Zoom / Slack"** toggle.
- Remembered choices stored per-app; revocable in Settings.
- **Menu-bar indicator** reflects state (idle / armed / recording).
- **Manual controls** always available: start / stop / **pause**, even with no detection.
- Default posture: **nothing recorded until a choice is made.**
- One-time disclaimer on first run re: participant-consent being the user's responsibility (jurisdiction-dependent).

---

## 9. Transcription pipeline

**Two phases:**

1. **Live (during meeting):** chunked streaming inference (e.g. rolling ~5–10 s windows with overlap)
   per track → provisional text with provisional speaker labels → Live transcript UI.
2. **Refine (on stop):** full-file re-transcription per track for higher accuracy + **global speaker
   clustering** across the whole meeting → clean final transcript persisted to DB.

**Engine abstraction:**

```swift
protocol STTEngine {
    func transcribeStream(_ audio: AudioStream) -> AsyncStream<TranscriptChunk>   // live
    func transcribeFile(_ url: URL) async throws -> Transcript                    // refine
    var capabilities: STTCapabilities { get }   // languages, streaming, timestamps
}
```

- **Default:** `ParakeetEngine` (FluidAudio, CoreML, Apple Silicon, fast). Model
  `parakeet-tdt-0.6b-v3` (multilingual ~25 langs) or `-v2` (English).
- **Fallback:** `WhisperEngine` (WhisperKit CoreML, or whisper.cpp via C interop) for multilingual / broader coverage.
- Engine selectable in Settings.

---

## 10. Diarization & speakers

- **"You"** = Track B (mic), labeled with certainty.
- **Remote speakers** = cluster Track A via **FluidAudio** (segmentation + speaker embeddings →
  clustering) → `Speaker 1 / 2 / 3…`.
- **Inline rename** in the transcript UI.
- **Voiceprint memory (deferred past v1):** persist speaker embeddings in a local voice library so a
  recurring colleague is auto-named across meetings. (`tonton-golio/meeting-recorder` already ships a
  learnable 256-dim voice library — strongest reference.)

Live diarization is provisional; the refine pass does global clustering for the saved transcript.

---

## 11. Summaries

- **LLM client:** OpenAI-compatible `POST /v1/chat/completions`. Settings = **Base URL + API Key +
  Model**. Model dropdown auto-populated via `GET /v1/models`. API key stored in **macOS Keychain**.
  - Works with Ollama, LM Studio, llama.cpp server, LocalAI (offline) and OpenAI/OpenRouter (if ever wanted).
- **Templates:** curated, fully editable presets + user-created custom. Each template =
  prompt + variables (`{transcript}`, `{participants}`, `{date}`, `{duration}`) + structured Markdown output.
  - Presets: **Long Summary**, **One-on-One**, **Action Items & Decisions**, **Quick Notes / Standup**.
- **Long transcripts:** **map-reduce** — token-aware chunk → summarize each → reduce/combine.
  Single-shot when the transcript fits the model context. Configurable max context.
- **Reference for clean provider settings:** VoiceInk; Meetily (Ollama / OpenAI-compatible wiring).
- **LLM failure taxonomy** (drives retry vs fix — see §11a):
  - *Transient* → timeout, connection refused, 5xx, server-busy → **auto-retry once** then offer manual Retry.
  - *Permanent* → bad base URL, 401/403 auth, model-not-found, 400/context-overflow → **no blind retry**; link to Settings.
  - *Map-reduce* → a single failed chunk is retried in isolation (bounded), not the whole job.

---

## 11a. Failure handling, retry & recovery (negative paths)

The happy path is the easy part; these are the failure modes the implementation must handle explicitly.
States referenced here are defined in `FUNCTIONAL_SPEC.md` / `specs.ts`.

**Capture interruptions (mid-recording):**

| Event | Detection | Handling |
|---|---|---|
| Audio **device change** (AirPods connect, output switch) | aggregate-device / IO-proc invalidation | Rebuild tap + aggregate device; mark a short `is_gap` segment; `deviceChanged` → auto-resume. |
| **`coreaudiod` restarts** (PID changes — observed in the wild) | tap/IO-proc handle dies | Re-establish tap with bounded backoff (e.g. 3× exponential); gap-mark; only then `captureError`. |
| **Far-end app quits/crashes** mid-meeting | target PID gone | Auto-stop, **finalize and save** what was captured (never discard). |
| **Far-end silent** (system-audio denied / wrong process) | no Track-A frames for N s (auth not queryable) | `farEndSilent`; offer continue-mic-only / stop / open Settings. |
| **Mic lost** (unplugged, permission revoked) | AVAudioEngine input failure | `captureError`; "You" track gap-marked; degrade to far-end-only or stop. |
| **Disk full** mid-write | write error / low-space watcher | `diskFull`; pause capture to protect already-flushed audio; resume-after-freeing or stop-and-keep. |

Principle: **transient blips self-heal** (retry + gap-mark); **partial loss degrades** (mic-only / far-end-only with a warning); only **unrecoverable** failure stops — and even then the recording is finalized and saved.

**Crash / abnormal-exit recovery:**
- Audio is **flushed incrementally** (don't buffer a whole meeting in memory) so a crash/force-quit/power-loss/sleep leaves a salvageable file.
- On launch, any `meeting` row left in `recording`/`processing` is a recovery candidate → salvage audio, re-run finalize, set `status = recovered` (or `failed` if nothing usable), surface as `recovered`.

**Retry policy (global):** capture re-establish = bounded backoff; model download = resumable + manual retry + checksum re-download; LLM = per the taxonomy above. Every surfaced error must state whether retrying is the right next action.

**Concurrency guards:** single active recording; second detected meeting **queues** a consent prompt (never overwrites); STT engine/model changes **locked while recording**; deleting a recording **cancels** its in-flight processing/summarizing and cleans up files; editing transcript after a summary sets `is_stale`.

**Disk pre-flight:** check free space ≥ model size before download; watch space during recording and warn early.

---

## 12. Persistence & data model

- **SQLite via GRDB.swift** for metadata/transcripts/summaries; **audio files** on disk (compressed AAC/Opus).
- Location: `~/Library/Application Support/<bundle-id>/`.
- **Retention:** configurable (keep forever | auto-delete after N days). Relies on FileVault;
  optional app-level encryption later.
- Full-text search over transcripts (SQLite FTS5).

**Draft schema:**

```
meeting(id, app, title, started_at, ended_at, duration_s, audio_path_far, audio_path_mic, status)
        -- status: recording | processing | ready | recovered | failed (recording/processing rows = crash-recovery candidates on launch)
speaker(id, meeting_id, label, display_name, embedding BLOB?)        -- embedding null until voiceprint
segment(id, meeting_id, speaker_id, t_start, t_end, text, is_final, is_gap)
        -- is_gap marks a capture interruption (audio missed) so the transcript is honest about it
summary(id, meeting_id, template_id, template_name, model, content_md, created_at, is_stale)
        -- template_name snapshotted so deleting a template doesn't orphan past summaries; is_stale set when transcript edited after generation
template(id, name, prompt, output_schema, is_builtin, is_editable)
app_consent(bundle_id, mode)                                          -- ask | always | never
voiceprint(id, display_name, embedding BLOB)                         -- cross-meeting library (deferred)
```

---

## 13. UI shell & screens

- **Menu-bar agent:** status dot (idle/armed/recording), detect toggle, quick start/stop, open-window.
- **Main window — tabs:**
  - **Library:** list of past meetings (date, app, duration, participants), search, delete.
  - **Live:** real-time transcript, who's-speaking, recording controls, elapsed time.
  - **Detail:** full transcript + audio playback + speaker rename + **Summarize** (template picker) + export.
  - **Settings:** LLM (URL/key/model), STT engine + model picker/download, detection apps, retention,
    templates editor.
- **Theme:** Zoom-like styling on Live + Detail + summary surfaces (built from scratch — no OSS reference has it).

---

## 14. Distribution

- **Developer ID-signed + notarized `.dmg`.** Not App Store (sandbox blocks process taps).
- Hardened Runtime with the minimum entitlements (mic + audio capture). Confirm exact set in the capture spike.
- Auto-update later (e.g. Sparkle).

---

## 15. OSS reference map (learn-from / fork-from)

| Subproblem | Best reference(s) | Notes |
|---|---|---|
| macOS meeting-audio capture (CoreAudio taps) | `ownscribe`, `RecapAI/Recap` | driver-free taps + mic, macOS 14.2+ |
| …(ScreenCaptureKit fallback) | `tonton-golio/meeting-recorder`, `Parrot` | SCKit system audio + AVAudioEngine mic |
| STT + diarization + voiceprint (Swift) | `tonton-golio/meeting-recorder` + **FluidAudio** | FluidAudio = Parakeet ASR + diarization + learnable voice library |
| Parakeet shipping examples | VoiceInk (FluidAudio), Meetily (ONNX `parakeet-tdt-0.6b-v3-onnx`) | confirms Parakeet viability |
| Meeting auto-detection | `pasrom/meeting-transcriber` | auto-records detected Teams/Zoom/Webex |
| LLM provider settings (base URL+key+model) | VoiceInk, Meetily | clean OpenAI-compatible config |
| Closest overall meeting app (Tauri, not our stack) | Hyprnote (~10k★), Meetily (~12.9k★) | study UX/templates; both MIT |

**Verdict from research:** no single OSS app does all 9 target features; **nobody** ships a Zoom-like
theme or first-class Slack-huddle detect+prompt. Build is justified; reuse heavily per-subproblem.

---

## 16. Risks & mitigations (retire early)

| # | Risk | Mitigation |
|---|---|---|
| R1 | **CoreAudio process-tap capture** of Zoom/Slack may have permission/reliability surprises on 14.2 vs 14.4 | **First spike.** Validate against `ownscribe`/`Recap`; have ScreenCaptureKit fallback ready |
| R2 | **Slack-huddle detection** (no dedicated process) | Key off Slack's active audio-I/O state, not windows; debounce |
| R3 | **FluidAudio live-streaming latency/accuracy** for Parakeet | Benchmark early; fall back to chunked WhisperKit if needed |
| R4 | Live vs refine **double pipeline** complexity | v1 ships live-only quality first; refine pass is a deferred add |
| R5 | Notarization / entitlements friction | Sort signing identity before building UI |
| R6 | **Silent capture** — system-audio auth can't be queried; denial = silence, not an error | Behavioral detection: no Track-A frames for N s → `farEndSilent`; never assume far-end is captured (see §6, §11a) |
| R7 | **Data loss** on crash/quit/power-loss mid-recording | Incremental audio flush + launch-time recovery of `recording`/`processing` rows → `recovered` (see §11a) |
| R8 | **Capture stability** under device changes / `coreaudiod` restarts | Bounded-backoff re-establish + gap-mark; degrade to single-track before failing (see §11a) |
| R9 | **Disk exhaustion** corrupting an in-flight recording | Disk pre-flight before downloads + low-space watcher; pause-to-protect on full (see §11a) |

---

## 17. Deferred past v1

Whisper fallback engine · post-meeting refine pass · voiceprint cross-meeting memory · multiple/custom
templates (v1 ships one) · PDF export (v1 ships MD/TXT/clipboard) · multilingual · Google Meet / Teams ·
app integrations (Notes/Slack/email) · auto-update.

**Robustness features (surfaced by the edge-case pass; deferred to keep v1 scope thin):**
crash/abnormal-exit **recovery** of interrupted recordings · **disk-space** pre-flight + low-space
watcher · **stop & discard** (record without saving) · transient/permanent **LLM error taxonomy** with
typed retry · map-reduce **per-chunk retry** · **concurrent-meeting** prompt queueing · **summary-stale**
flag on transcript edits · capture **gap-marking** + single-track degrade · per-app **manual re-run
diarization / merge-speakers**.

> v1 still ships the *minimum honest* failure handling: never record without consent, never silently
> lose a captured recording, and always show whether audio is being captured. The richer recovery/retry
> machinery above is layered in v1.x. (The functional specs describe these states so the design can
> accommodate them even where v1 implements only the basic version.)

---

## 18. Open items to confirm before/at coding time

1. **TCC permission category** for CoreAudio process taps on 14.2 vs 14.4, and whether to **floor at 14.4** for the documented `NSAudioCaptureUsageDescription` path (capture spike).
2. App **name** + bundle identifier.
3. Whether any **Intel Mac** must be supported (currently: no, Apple-Silicon-only).
4. FluidAudio **Parakeet model variant** for v1: `-v2` (English) vs `-v3` (multilingual).
5. **`farEndSilent` threshold** — how many seconds of no far-end audio before warning (must tolerate genuine quiet stretches without false alarms).
6. **Capture-retry budget** — backoff count/intervals before giving up to `captureError`.
7. **Recovery UX** — auto-open a `recovered` recording vs just flag it in Library.

See `TASKS.md` for the v1 build breakdown.
