# Functional Specification

> **For the design system / design agent.**
> This file describes **what the app must let users see and do** — every screen, the
> data it shows, the actions available, and the states it can be in.
>
> **It intentionally contains NO design direction:** no colors, theme, typography,
> spacing, layout, motion, or component styling. All visual and layout decisions are
> yours. (That explicitly includes any "Zoom-like" look — treat the visual style as
> open.) This file is self-contained; you don't need any other document to design from it.

---

## 1. What the app is

A macOS desktop app that detects **Zoom meetings** and **Slack huddles**, asks the user
for permission to record, transcribes the conversation **on-device** with **speaker
labels**, and generates **templated summaries** through the user's **own local AI model**.
It works **fully offline**.

The app has two parts:
- A **menu-bar agent** (always present; shows recording status and quick controls).
- A **main window** with screens: **Library**, **Live transcript**, **Recording detail**, **Settings**.

Plus transient surfaces: **First-run setup**, the **Consent prompt**, and the **Template editor**.

---

## 2. Hard product rules (must shape the design)

1. **Recording is always visibly unambiguous.** From anywhere — including the menu bar —
   the user must instantly know whether audio is being recorded right now. This is privacy-critical.
2. **Nothing records without consent.** Recording only ever begins after an explicit choice:
   a per-meeting prompt, or a remembered "always record this app" decision.
3. **Offline-first.** Every feature works with no internet except (a) one-time model downloads
   and (b) summary generation, which calls the user's own configured endpoint.
4. **All data is local.** Recordings, transcripts, and summaries are stored on the user's machine.
5. **Every state needs a design — not just the happy path.** Empty, loading, error, and
   in-progress states are first-class (see each screen and §6).

---

## 3. Screens

For each screen: **Purpose**, **Shows** (data), **Actions** (what the user can do), **States**
(modes the design must handle).

### 3.1 Menu-bar agent
*Always-available presence; status at a glance + quick controls without opening the window.*

**Shows**
- Current status: `idle` · `armed` (detection on, app open) · `recording` · `paused` · `processing`.
- When recording: the active meeting's name/app and elapsed time.
- Whether auto-detection is currently on.

**Actions**
- Start recording (manual) — when not recording.
- Stop recording — when recording/paused.
- Stop & discard — end without saving (audio + partial transcript deleted) — **confirm**.
- Pause / Resume — when recording.
- Enable / Disable detection.
- Open main window.
- Open live transcript — when recording.
- Quit (must stop or confirm if recording).

**States**
- `idle` — detection on, no meeting.
- `armed` — known app open, no audio activity yet.
- `recording` — capturing + transcribing.
- `paused` — temporarily paused.
- `processing` — stopped, finalizing.
- `captureError` — an active recording hit a capture problem (far-end lost, device changed, disk full); must show here, not only in the window.
- `permissionMissing` — a required permission (mic / system-audio) isn't granted; recording can't start.
- `detectionOff` — auto-detection disabled (manual only).

> The recording state must be the most prominent, glanceable thing here.
> `captureError` and `permissionMissing` must be visible from the menu bar alone — the user may never open the main window.

---

### 3.2 First-run setup
*Make the app usable on first launch: permissions, model, summary AI, consent acknowledgement.*

**Shows**
- Microphone + system-audio permission status (not granted / granted).
- Selectable transcription models, each with a size and a speed/quality tradeoff label.
- Download progress for the chosen model.
- Free disk space vs the chosen model's size (warns if there isn't room before downloading).
- Whether the entered AI endpoint responds.

**Actions**
- Grant microphone access.
- Grant system-audio access.
- Choose a transcription model.
- Download the model (resumable; shows progress).
- Retry/resume a failed or interrupted model download.
- Configure summaries: enter AI base URL + API key + model (**skippable**, can be done later).
- Acknowledge a consent disclaimer (obtaining participants' consent to record is the user's responsibility).
- Finish setup → land on Library.

**States**
- `permissions` → `modelSelect` → `downloading` → `llmSetup` (skippable) → `disclaimer` → `done`.
- `permissionDenied` — mic and/or system-audio denied; explain consequences (mic-only / no recording) and offer re-request or a System Settings deep link; onboarding can still continue.
- `downloadFailed` — model download failed/interrupted (network drop, no disk space, checksum mismatch); explain and offer retry/resume.
- Steps may be revisited; permissions can be denied and re-requested.

> The app must be usable for **transcription** even if the user skips AI/summary setup.
> Onboarding can be quit partway and resumed next launch; only acknowledging the disclaimer is required before the first recording.
> System-audio authorization can't be queried via an API (unlike the mic), so onboarding can confirm the prompt fired but not that it was granted — denial only shows up as silence at capture time.

---

### 3.3 Consent prompt (meeting detected)
*Shown the instant a meeting/huddle is detected; the user decides whether to record it.*

**Shows**
- Which app triggered it (e.g., Zoom, Slack).
- When detection fired.

**Actions**
- **Record** — start recording this meeting now.
- **Ignore** — don't record it.
- **"Always record this app"** — optional toggle: auto-record future meetings from this app without prompting.

**States**
- `shown` — awaiting a decision.
- `dismissedAuto` — auto-dismissed if the meeting ends before the user chooses (no recording created).
- `expired` — user never responded but the meeting is still ongoing; the prompt may time out into a non-blocking notification rather than trapping focus. Default on no-decision is **not** to record.

> Must be noticeable but interruptible; appears over whatever the user is doing.
> If the user previously chose "always record" for this app, this prompt is **skipped** and
> recording starts directly — replaced by a non-blocking notification.
> **Concurrent meetings:** if a second app is detected while a prompt is already shown (or while
> already recording), prompts must not overwrite each other — queue/stack them and label which app
> each refers to.
> **Default-deny:** if the meeting ends or the prompt expires before an explicit choice, nothing is recorded.

---

### 3.4 Library
*Browse, search, and open all past recordings.*

**Shows**
- List of all saved meetings: title, source app, date, duration, participant count, whether a summary exists.
- A free-text search field (searches titles **and** transcript content).
- Total disk used by recordings (informational).
- A low-disk-space warning banner when free space threatens future recordings.

**Actions**
- Open a recording (→ Detail).
- Search / filter.
- Sort (e.g. by date, duration, app).
- Rename a recording.
- Delete a recording (audio + transcript + summaries) — **confirm**.
- Record now (manual).

**States**
- `empty` — no recordings yet; must explain how recordings get created.
- `populated` — recordings listed.
- `searching` — showing filtered results.
- `noMatches` — search returned nothing.

> A recording may appear while still `processing` (just stopped) or `recovered` (salvaged after a
> crash) — show these non-ready states rather than hiding them.
> A row whose audio file is missing/corrupt must still be listed and openable (the transcript survives).

---

### 3.5 Live transcript
*While recording, show the real-time transcript, who's speaking now, and recording controls.*

**Shows**
- Rolling transcript: ordered lines, each with a **speaker label** + text, updating in real time.
- Who is speaking right now ("You" or "Speaker N").
- Elapsed recording time.
- Which app is being recorded.
- Recording state (recording / paused).
- A live "audio is active" signal for the two inputs (your mic / the far-end).

**Actions**
- Pause / Resume.
- Stop (→ finalize → opens Detail).
- Stop & discard — end without saving — **confirm**.
- Retry capture — when in `captureError`, after automatic retries are exhausted.
- Jump to latest line (when scrolled up).

**States**
- `recording` — transcript actively appending.
- `paused` — capture paused, transcript frozen.
- `noSpeechYet` — recording started, nothing transcribed yet.
- `farEndSilent` — mic is captured but the far-end track has had no audio for a sustained period (likely system-audio permission denied / wrong process); warn remote audio may be missing, offer continue-mic-only or stop.
- `deviceChanged` — audio device changed mid-recording (e.g. AirPods connected); capture is being re-established. Brief gap expected; recording not lost.
- `captureError` — capture failed/interrupted and automatic retries were exhausted; must surface clearly and offer retry/stop.
- `diskFull` — disk filled during recording; capture paused to protect already-written audio; offer free-space-and-resume or stop-and-keep.
- `processing` — stopped, finalizing before Detail opens.

> **Live transcript is provisional:** speaker labels and lines can be re-grouped/relabeled once
> the meeting ends. The design must tolerate content changing after the fact.
> There are two audio inputs under the hood, but the user only ever sees **one merged,
> time-ordered transcript** — you do not need to expose the two tracks separately.
> **Capture interruptions self-heal where possible:** device changes, a coreaudiod restart, or a
> brief far-end drop are auto-retried with backoff and mark a small gap in the transcript rather than
> ending the recording. If the recorded app quits mid-meeting, the recording auto-stops and finalizes
> what was captured. Multi-hour meetings must stay responsive (don't assume an unbounded in-memory list).

---

### 3.6 Recording detail
*Read a finished recording: full transcript, audio playback, speaker renaming, summaries, export.*

**Shows**
- Metadata: title, source app, date, duration, participants.
- Full transcript: ordered lines with speaker label, timestamp, text.
- The distinct speakers in this meeting, each with an **editable display name**.
- Audio playback of the recording; selecting a line seeks playback to that moment.
- Generated summaries (each tied to a template + model), shown as formatted text.
- The template selected for the next summary.

**Actions**
- Play / Pause audio.
- Seek to a transcript line.
- Rename a speaker (applies across the whole transcript).
- Edit a transcript line's text (correct mistakes).
- Choose a summary template.
- Generate summary — runs the selected template via the configured AI (only when AI is configured).
- Regenerate a summary (e.g. after editing the transcript, or to refresh a stale one).
- Retry a failed summary — for transient errors only (timeout / connection refused), distinct from a configuration fix.
- Cancel an in-progress summary.
- Copy (transcript or a summary) to clipboard.
- Export (transcript or summary) to a file (Markdown / plain text / PDF).
- Delete recording — **confirm**.

**States**
- `processing` — final transcript still being produced after stop.
- `recovered` — recording salvaged after an unexpected interruption (crash/quit/power-loss); transcript/audio may be partial and must be flagged as recovered.
- `ready` — transcript available; no summary yet.
- `summarizing` — a summary is being generated (may stream in progressively; cancellable).
- `summaryReady` — at least one summary exists.
- `summaryStale` — the transcript was edited (text or speaker name) after a summary was generated, so it may be out of date; invite regeneration without deleting the old one.
- `summaryError` — generation failed; must distinguish **transient** (timeout/connection refused/server busy → offer retry) from **permanent** (bad URL/key, model not found, context overflow → link to settings, no blind retry).
- `llmNotConfigured` — summaries unavailable because no AI endpoint is set; must prompt the user to configure it.
- `audioMissing` — audio file missing/corrupt; transcript, summaries, copy and export still work, but playback/seek are unavailable and must say so.
- `playing` — audio playing, with the current line indicated.

> Editing transcript text or renaming a speaker after a summary exists moves the recording into
> `summaryStale` rather than silently invalidating the summary.
> Deleting while `processing`/`summarizing` cancels that work cleanly and leaves no orphaned files/rows.
> Long-transcript summaries use map-reduce; a single failed chunk is retried in isolation, not the whole summary.

---

### 3.7 Settings
*Configure detection, recording, transcription, summaries, templates, storage, and permissions.*

Sections: **(1) General / Detection · (2) Recording · (3) Transcription engine & models ·
(4) Summaries / AI · (5) Templates · (6) Storage & retention · (7) Permissions.**

**Actions by section**

*Detection*
- Master toggle for auto-detection.
- Manage detected apps: enable/disable per app (Zoom, Slack, …) and set each to **ask / always-record / never**.

*Transcription*
- Select the speech-to-text engine (a default and a fallback exist). Disabled while a recording is active.
- Manage models: download, switch the active one, or remove models (each shows size + status). Switching/removing the active model is blocked while recording; removing the active model requires choosing a replacement.

*Summaries / AI*
- Set base URL.
- Set API key (entered/shown **masked**; treated as a secret).
- Load available models from the endpoint and pick one.
- Test connection (verify the endpoint responds with the chosen credentials/model).

*Templates*
- Open the Template editor (§3.8).

*Storage*
- Set retention: keep forever **or** auto-delete after N days. If a shorter window would immediately delete existing recordings, **confirm** and state how many before applying.
- Reveal the local storage location.
- Delete all recordings — **confirm**.

*Permissions*
- Review microphone + system-audio permission status, with links to fix them in System Settings.

**States**
- `default` — browsing.
- `llmUnconfigured` — no AI endpoint set yet.
- `llmTesting` — testing the connection.
- `llmConnected` — verified.
- `llmError` — connection failed; distinguish bad URL vs auth failure vs unreachable endpoint vs model-not-found so the user knows what to fix.
- `modelDownloading` — a model is downloading (progress shown).
- `modelDownloadFailed` — a model download failed/interrupted; explain why (network, disk space, checksum) and offer resume/retry.
- `permissionMissing` — a required OS permission is not granted.
- `recordingActive` — a recording is in progress; transcription engine/model changes are locked until it ends.

> The API key must be masked by default and never shown in plaintext casually.
> Destructive storage actions (delete-all, retention that deletes existing recordings) always confirm and state the impact.

---

### 3.8 Template editor (within Settings)
*Create and edit the summary templates that drive how summaries are generated.*

**Shows**
- All templates: built-in presets + custom ones.
- For the selected template: name; the prompt/instruction body (supports variables like
  `{transcript}`, `{participants}`, `{date}`, `{duration}`); whether it's a built-in preset.

**Actions**
- New template.
- Duplicate an existing one as a starting point.
- Edit name + prompt + variables.
- Delete a custom template — **confirm**.
- Insert a variable token into the prompt.

**States**
- `list` — browsing templates.
- `editing` — editing fields.
- `unsaved` — pending edits (save / discard).
- `invalid` — can't be saved: name empty, an unknown variable token is used, or the required `{transcript}` variable is missing; explain before allowing save.

> Built-in presets to ship (all editable): **Long Summary**, **One-on-One**,
> **Action Items & Decisions**, **Quick Notes / Standup**.
> A template must contain `{transcript}` to be usable; saving without it is blocked with a clear reason.
> Deleting a template does **not** delete summaries already generated from it — past summaries keep their
> (snapshotted) template name even if the template is gone. Editing a built-in preset offers "reset to default".

---

## 4. Data shown (entities)

The objects the screens display. (These describe **information**, not storage.)

**Meeting** — a recorded meeting/huddle.
- title (editable; default derived from app + date), source app (Zoom | Slack | Manual | future others),
  start date/time, duration, participant count, whether a summary exists,
  status (`recording` | `processing` | `ready` | `recovered` | `failed`).

**Speaker** — a distinct voice in a meeting.
- system label ("You" for the user's mic, or "Speaker N"), optional user-assigned display name.

**Transcript line** — one utterance.
- speaker, start time, end time, text (editable), whether it's provisional (live) or final,
  whether it marks a capture gap (brief interruption where audio was missed).

**Summary** — a generated summary of a meeting.
- template used, AI model used, content (formatted text), created date/time,
  whether it's stale (transcript changed after it was generated).

**Summary template** — a reusable prompt that produces a summary.
- name, prompt body (with variables), whether it's a built-in preset.

**App detection rule** — per-app detection + consent preference.
- app, enabled on/off, consent mode (ask | always | never).

**AI configuration** — connection settings for summaries.
- base URL, API key (secret, masked), selected model, status (unconfigured | testing | connected | error),
  last error kind when error (unreachable | authFailed | modelNotFound | badUrl | timeout) — drives whether retry or a settings fix is offered.

**Transcription model** — an on-device model.
- name, download size, speed/quality tradeoff label, status (not-downloaded | downloading | ready | active).

**Retention policy** — how long recordings are kept.
- mode (keep-forever | auto-delete), days (when auto-delete).

---

## 5. User flows (must be supported end-to-end)

1. **First-run setup** — launch → grant mic + system-audio → choose & download a model →
   optionally configure summary AI → acknowledge consent disclaimer → land on Library (empty).
2. **Auto-detect → consent → record** — known app starts using audio → if app is "ask", show
   consent prompt (Record / Ignore / Always); if "always", start recording + non-blocking
   notification → menu-bar shows recording → user can open Live → live transcript appends.
3. **Manual record** — user clicks "Record now" → recording starts → Live becomes active.
4. **Stop → finalize → save** — user stops → app finalizes transcript and groups speakers
   (`processing`) → recording saved and opened in Detail (`ready`).
5. **Generate a summary** — in Detail, pick a template → Generate; if no AI configured, prompt
   to set it up → summary generated (may stream) → user can regenerate / switch template / copy / export.
6. **Rename speakers** — in Detail, rename "Speaker N" to a real name → applies across the transcript.
7. **Export / share** — in Detail, export transcript or summary to Markdown / text / PDF, or copy.
8. **Configure summary AI** — Settings → enter base URL + API key → load models → pick one →
   Test connection → connected (or error with a reason).
9. **Manage templates** — Settings → browse presets + custom → create / duplicate / edit / delete.
10. **Switch transcription model** — Settings → view models with size/status → download a new one
    (progress) or switch active; optionally remove old ones.
11. **Capture interruption → recover** — during recording, audio is interrupted (device changes,
    far-end app quits, coreaudiod restarts, or far-end goes silent) → app auto-retries with backoff,
    marks a brief transcript gap, and self-heals where possible → if the far-end can't be recovered,
    fall back to mic-only with a warning; if nothing can, stop and finalize what was captured →
    if retries are exhausted, Live shows `captureError` with Retry / Stop (keep). The partial recording
    is never silently discarded.
12. **Crash / quit during recording → recover** — recording is interrupted by a crash, force-quit,
    power loss, or sleep → on next launch the app detects the meeting left in recording/processing
    state → salvages incrementally-flushed audio, re-runs finalize, and saves it as `recovered` →
    it opens / is listed clearly flagged as recovered (possibly partial).

---

## 6. Global behaviors (cross-cutting; affect many screens)

- **Recording visibility** — it must always be unambiguous whether audio is being recorded, from
  anywhere in the app and the menu bar. (Privacy-critical.)
- **Offline-first** — every feature except model download and summary generation works with no
  network. Transcription never requires the internet.
- **Consent by default** — no recording begins without a prior explicit choice (per-meeting prompt
  or a remembered per-app "always").
- **Non-blocking notifications** — background events (auto-record started, summary finished,
  capture error) surface as non-blocking notifications, not only as in-window state.
- **Error clarity** — every failure (capture interrupted, AI unreachable, model download failed,
  permission missing) explains what happened and offers the next action (retry / open the relevant settings).
- **Empty states** — Library, Detail-without-summary, and Settings-without-AI/model each need a
  first-use empty state that guides the user to the next step.
- **Secret masking** — the AI API key is a secret: masked by default, never displayed casually.
- **Provisional live data** — live transcript text and speaker labels are provisional and can
  change after the meeting is finalized; the design must handle late re-grouping/relabeling gracefully.
- **Retry policy** — recoverable failures retry before becoming errors: capture interruptions
  auto-retry with bounded backoff; model downloads are resumable + manually retryable; LLM/network
  calls retry only for transient errors (timeout, connection refused, 5xx) and never blindly for
  permanent ones (4xx auth/bad-request, model-not-found). Every error states whether retrying is the
  right next step.
- **Capture degradation** — capture failures degrade gracefully instead of dropping the recording:
  a transient blip marks a short transcript gap and self-heals; losing the far-end track falls back to
  mic-only with a warning; only an unrecoverable failure stops the recording — and even then it
  finalizes and saves whatever was already captured.
- **Crash recovery** — an interrupted recording (crash, force-quit, power loss, sleep) is never
  silently lost: audio is flushed incrementally so partial data survives, and on next launch any
  meeting left mid-flight is detected, salvaged, finalized, and shown as `recovered`.
- **Disk safety** — disk space is checked before model downloads and watched during recording: low
  space warns early; a full disk pauses capture to protect already-written audio rather than corrupting
  it, and offers resume-after-freeing or stop-and-keep.
- **Concurrency safety** — conflicting actions are prevented, not raced: only one recording is active
  at a time; a second detected meeting queues a prompt instead of overwriting; engine/model changes are
  locked while recording; deleting a recording cancels its in-progress processing/summarizing and cleans
  up its files.
- **Partial-failure isolation** — multi-step jobs isolate failures: a single failed map-reduce chunk
  is retried on its own rather than restarting the whole summary, and a captured recording is still
  saved even if a later finalize step fails.
- **Permission revocation** — permissions can be revoked mid-session, not just missing at startup:
  losing mic or system-audio access during a recording is surfaced immediately (degrade or stop), with
  a deep link to fix it in System Settings.

---

## 7. Screen / state coverage checklist (for design completeness)

| Screen | Must design these states |
|---|---|
| Menu-bar agent | idle · armed · recording · paused · processing · capture-error · permission-missing · detection-off |
| First-run setup | permissions · permission-denied · model-select · downloading · download-failed · ai-setup (skippable) · disclaimer · done |
| Consent prompt | shown · auto-dismissed · expired · (skipped → notification) · (concurrent → queued) |
| Library | empty · populated · searching · no-matches · (rows: processing / recovered / audio-missing) |
| Live transcript | recording · paused · no-speech-yet · far-end-silent · device-changed · capture-error · disk-full · processing |
| Recording detail | processing · recovered · ready · summarizing · summary-ready · summary-stale · summary-error (transient/permanent) · ai-not-configured · audio-missing · playing |
| Settings | default · ai-unconfigured · ai-testing · ai-connected · ai-error · model-downloading · model-download-failed · permission-missing · recording-active |
| Template editor | list · editing · unsaved · invalid |
