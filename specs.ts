/**
 * specs.ts — FUNCTIONAL UI specification (features only)
 * =====================================================
 * App: macOS, fully-offline meeting transcription + summarization for Zoom
 *      meetings and Slack huddles.
 *
 * AUDIENCE: the UI/design agent.
 *
 * SCOPE OF THIS FILE — read carefully:
 *   ✅ WHAT each surface must let the user SEE and DO, the data it shows,
 *      the actions available, and the STATES it can be in.
 *   ❌ NO visual design, theme, colors, typography, spacing, layout, motion,
 *      component styling, or aesthetic direction. ALL of that is the design
 *      agent's job and is intentionally omitted.
 *
 * The `kind` field on each surface ("window-tab" | "menu-bar" | "modal" |
 * "onboarding") is a FUNCTIONAL classification (persistent screen vs transient
 * prompt vs system-tray presence) — it is NOT a layout instruction.
 */

// ─────────────────────────────────────────────────────────────────────────────
// Shared types
// ─────────────────────────────────────────────────────────────────────────────

export type SurfaceKind = "menu-bar" | "window-tab" | "modal" | "onboarding";

/** A thing the user can do on a surface. */
export interface Action {
  id: string;
  label: string;
  /** What it does, functionally. */
  description: string;
  /** Optional: only enabled/visible when this condition holds. */
  availableWhen?: string;
  /** Optional: confirmation required before it runs (destructive/irreversible). */
  confirm?: boolean;
}

/** A piece of information a surface displays. */
export interface DataField {
  name: string;
  /** Conceptual type, not a rendering hint. */
  type:
    | "text"
    | "longText"
    | "markdown"
    | "number"
    | "duration"
    | "datetime"
    | "boolean"
    | "enum"
    | "list"
    | "audio"
    | "secret";
  description: string;
}

/** A distinct mode the surface can be in (drives empty/loading/error handling). */
export interface UIState {
  id: string;
  description: string;
}

export interface Surface {
  id: string;
  name: string;
  kind: SurfaceKind;
  /** Why this surface exists / the user's goal on it. */
  purpose: string;
  /** Information shown. */
  dataShown: DataField[];
  /** Things the user can do here. */
  actions: Action[];
  /** Modes the surface can occupy. The design must handle each. */
  states: UIState[];
  /** Functional notes / edge cases the design must accommodate. */
  notes?: string[];
}

/** A domain object referenced by surfaces. */
export interface Entity {
  name: string;
  description: string;
  fields: DataField[];
}

/** An end-to-end user journey across surfaces. */
export interface UserFlow {
  id: string;
  name: string;
  /** Ordered steps. Each references surfaces/actions by intent, not pixels. */
  steps: string[];
}

export interface AppSpec {
  product: {
    name: string; // TBD
    oneLiner: string;
    platform: string;
    hardConstraints: string[];
  };
  surfaces: Surface[];
  entities: Entity[];
  flows: UserFlow[];
  /** Cross-cutting functional requirements that touch many surfaces. */
  globalBehaviors: { id: string; description: string }[];
}

// ─────────────────────────────────────────────────────────────────────────────
// Specification
// ─────────────────────────────────────────────────────────────────────────────

export const spec: AppSpec = {
  product: {
    name: "TBD",
    oneLiner:
      "Detects Zoom meetings and Slack huddles, asks permission to record, " +
      "transcribes them on-device with speaker labels, and generates " +
      "templated summaries via a user-configured local LLM. Fully offline.",
    platform: "macOS desktop app (menu-bar agent + main window).",
    hardConstraints: [
      "Fully offline: no cloud transcription; the only network calls are model downloads and the user's own configured LLM endpoint.",
      "Nothing is recorded without explicit user consent.",
      "All recordings, transcripts, and summaries are stored locally.",
    ],
  },

  // ───────────────────────────────────────────────────────────────────────────
  // SURFACES
  // ───────────────────────────────────────────────────────────────────────────
  surfaces: [
    // 1) MENU-BAR AGENT ────────────────────────────────────────────────────────
    {
      id: "menubar",
      name: "Menu-bar agent",
      kind: "menu-bar",
      purpose:
        "Always-available presence. Shows recording status at a glance and " +
        "offers quick controls without opening the main window.",
      dataShown: [
        { name: "status", type: "enum", description: "idle | armed (detection on) | recording | paused | processing." },
        { name: "activeMeetingTitle", type: "text", description: "Name/app of the meeting currently being recorded (when recording)." },
        { name: "elapsed", type: "duration", description: "How long the current recording has been running." },
        { name: "detectionEnabled", type: "boolean", description: "Whether auto-detection is currently on." },
      ],
      actions: [
        { id: "start", label: "Start recording", description: "Begin a manual recording immediately.", availableWhen: "not recording" },
        { id: "stop", label: "Stop recording", description: "End the current recording and trigger processing.", availableWhen: "recording or paused" },
        { id: "stopDiscard", label: "Stop & discard", description: "End the current recording WITHOUT saving it (audio + partial transcript deleted).", availableWhen: "recording or paused", confirm: true },
        { id: "pause", label: "Pause / Resume", description: "Pause or resume the current recording.", availableWhen: "recording" },
        { id: "toggleDetection", label: "Enable/Disable detection", description: "Turn meeting auto-detection on or off." },
        { id: "openWindow", label: "Open main window", description: "Reveal the main app window (Library)." },
        { id: "openLive", label: "Open live transcript", description: "Jump to the Live surface.", availableWhen: "recording" },
        { id: "quit", label: "Quit", description: "Quit the app (recording must be stopped first or confirmed)." },
      ],
      states: [
        { id: "idle", description: "Detection on, no meeting active." },
        { id: "armed", description: "A known meeting app is open but no audio activity yet." },
        { id: "recording", description: "Actively capturing + transcribing." },
        { id: "paused", description: "Recording temporarily paused." },
        { id: "processing", description: "Recording stopped; finalizing transcript." },
        { id: "captureError", description: "An active recording hit a capture problem (e.g. far-end audio lost, device changed, disk full). Must surface here, not only in the window." },
        { id: "permissionMissing", description: "A required OS permission (mic / system-audio) is not granted; recording can't start. Glanceable warning + path to fix." },
        { id: "detectionOff", description: "Auto-detection disabled; manual only." },
      ],
      notes: [
        "Status must be distinguishable at a glance for each state.",
        "Recording state must be unambiguous (privacy-critical — the user must always know when audio is being captured).",
        "captureError and permissionMissing must be visible from the menu bar alone — the user may never have the main window open.",
      ],
    },

    // 2) ONBOARDING / FIRST RUN ─────────────────────────────────────────────────
    {
      id: "onboarding",
      name: "First-run setup",
      kind: "onboarding",
      purpose:
        "Get the app usable on first launch: grant permissions, choose & " +
        "download a transcription model, configure the summary LLM, and " +
        "acknowledge the recording-consent disclaimer.",
      dataShown: [
        { name: "permissionStatuses", type: "list", description: "Microphone + system-audio capture permission states (not granted / granted)." },
        { name: "availableModels", type: "list", description: "Selectable speech-to-text models with size + speed/quality tradeoff labels." },
        { name: "downloadProgress", type: "number", description: "Progress of the chosen model download." },
        { name: "freeDiskSpace", type: "text", description: "Available disk space vs the selected model's size — warns if there isn't room before download starts." },
        { name: "llmReachable", type: "boolean", description: "Whether the entered LLM endpoint responds." },
      ],
      actions: [
        { id: "grantMic", label: "Grant microphone access", description: "Trigger the macOS microphone permission request." },
        { id: "grantSystemAudio", label: "Grant system-audio access", description: "Trigger the macOS system-audio capture permission request." },
        { id: "pickModel", label: "Choose model", description: "Select a speech-to-text model to download." },
        { id: "downloadModel", label: "Download model", description: "Download the chosen model for offline use." },
        { id: "retryDownload", label: "Retry download", description: "Resume or restart a failed/interrupted model download (network dropped, checksum mismatch, or cancelled).", availableWhen: "download failed or interrupted" },
        { id: "configureLLM", label: "Set up summaries", description: "Enter LLM base URL + API key + model (can be skipped and done later)." },
        { id: "acknowledgeDisclaimer", label: "Acknowledge", description: "Confirm understanding that obtaining participant consent to record is the user's responsibility." },
        { id: "finish", label: "Finish setup", description: "Complete onboarding and open the app." },
      ],
      states: [
        { id: "permissions", description: "Requesting required OS permissions." },
        { id: "permissionDenied", description: "User denied mic and/or system-audio. Must explain consequences (mic-only / no recording) and offer re-request or a deep link to System Settings; onboarding can still proceed and be fixed later." },
        { id: "modelSelect", description: "Choosing a transcription model." },
        { id: "downloading", description: "Model download in progress (resumable, shows progress)." },
        { id: "downloadFailed", description: "Model download failed or was interrupted (network drop, no disk space, checksum mismatch) — must explain why and offer retry/resume." },
        { id: "llmSetup", description: "Configuring the summary LLM (skippable)." },
        { id: "disclaimer", description: "Consent/legal acknowledgement." },
        { id: "done", description: "Setup complete." },
      ],
      notes: [
        "Steps may be revisited; permissions can be denied and re-requested.",
        "LLM setup is optional — the app must be usable for transcription without it.",
        "Onboarding can be exited/quit partway through and resumed on next launch; nothing here is a hard wall except acknowledging the disclaimer before the first recording.",
        "System-audio capture authorization cannot be queried via an API (unlike mic) — denial only manifests as silence at capture time, so onboarding can confirm the prompt was shown but not that it was granted.",
      ],
    },

    // 3) CONSENT PROMPT (meeting detected) ──────────────────────────────────────
    {
      id: "consentPrompt",
      name: "Recording consent prompt",
      kind: "modal",
      purpose:
        "Shown the moment a meeting/huddle is detected. Lets the user decide " +
        "whether to record this meeting, and optionally remember the choice for the app.",
      dataShown: [
        { name: "detectedApp", type: "enum", description: "Which app triggered it (e.g., Zoom, Slack)." },
        { name: "detectedAt", type: "datetime", description: "When detection fired." },
      ],
      actions: [
        { id: "record", label: "Record", description: "Start recording this meeting now." },
        { id: "ignore", label: "Ignore", description: "Do not record this meeting." },
        { id: "rememberToggle", label: "Always record this app", description: "Optional toggle: auto-record future meetings from this app without prompting." },
      ],
      states: [
        { id: "shown", description: "Prompt awaiting a decision." },
        { id: "dismissedAuto", description: "Auto-dismissed if the meeting ends (audio activity stops) before a choice is made — no recording is created." },
        { id: "expired", description: "User never responded and the meeting is still ongoing: prompt may time out into a non-blocking notification so it doesn't trap focus indefinitely. Default on no-decision is NOT to record." },
      ],
      notes: [
        "Must be noticeable but interruptible; appears over whatever the user is doing.",
        "If 'always record' was previously chosen for this app, this prompt is skipped and recording starts directly (with a non-blocking notification instead).",
        "Concurrent meetings: if a second app is detected while a prompt is already shown (or while already recording), prompts must not silently overwrite each other — queue or stack them, and make clear which app each prompt refers to.",
        "Default-deny on ambiguity: if the meeting ends or the prompt expires before an explicit choice, nothing is recorded.",
      ],
    },

    // 4) LIBRARY ────────────────────────────────────────────────────────────────
    {
      id: "library",
      name: "Library",
      kind: "window-tab",
      purpose: "Browse, search, and open all past recordings.",
      dataShown: [
        { name: "recordings", type: "list", description: "All saved meetings (see Meeting entity): title, source app, date, duration, participant count, whether a summary exists." },
        { name: "searchQuery", type: "text", description: "Free-text search across titles and transcript content." },
        { name: "storageUsed", type: "text", description: "Total disk used by recordings (informational)." },
        { name: "lowSpaceWarning", type: "boolean", description: "Set when free disk space is low enough to threaten future recordings; surfaced as a non-alarming banner." },
      ],
      actions: [
        { id: "open", label: "Open recording", description: "Open a recording in Detail." },
        { id: "search", label: "Search", description: "Filter recordings by text in title/transcript." },
        { id: "sort", label: "Sort", description: "Order the list (e.g. by date, duration, app)." },
        { id: "rename", label: "Rename", description: "Edit a recording's title." },
        { id: "delete", label: "Delete", description: "Permanently delete a recording (audio + transcript + summaries).", confirm: true },
        { id: "newManual", label: "Record now", description: "Start a manual recording." },
      ],
      states: [
        { id: "empty", description: "No recordings yet (first-use). Must explain how recordings get created." },
        { id: "populated", description: "One or more recordings listed." },
        { id: "searching", description: "Showing filtered results; may be zero matches." },
        { id: "noMatches", description: "Search returned nothing." },
      ],
      notes: [
        "A recording may appear while still 'processing' (just stopped) or 'recovered' (salvaged after a crash) — the list must show these non-ready states, not hide them.",
        "A row whose audio file is missing/corrupt must still be listed and openable (transcript survives) rather than vanishing.",
        "Deleting the currently-recording meeting is not offered here; stop it first.",
      ],
    },

    // 5) LIVE ───────────────────────────────────────────────────────────────────
    {
      id: "live",
      name: "Live transcript",
      kind: "window-tab",
      purpose:
        "While recording, show the real-time transcript with who is currently " +
        "speaking, plus recording controls.",
      dataShown: [
        { name: "liveSegments", type: "list", description: "Rolling transcript: ordered segments with speaker label + text, updating in real time." },
        { name: "currentSpeaker", type: "text", description: "Who is speaking right now ('You' or 'Speaker N')." },
        { name: "elapsed", type: "duration", description: "Recording elapsed time." },
        { name: "sourceApp", type: "enum", description: "App being recorded." },
        { name: "recordingState", type: "enum", description: "recording | paused." },
        { name: "audioLevels", type: "number", description: "Live input levels for the two tracks (mic / far-end) as a recording-active signal." },
      ],
      actions: [
        { id: "pause", label: "Pause / Resume", description: "Pause or resume capture." },
        { id: "stop", label: "Stop", description: "End recording; transitions to processing then opens Detail." },
        { id: "stopDiscard", label: "Stop & discard", description: "End recording without saving (deletes audio + partial transcript).", confirm: true },
        { id: "retryCapture", label: "Retry capture", description: "Manually re-establish audio capture after a capture error (after automatic retries are exhausted).", availableWhen: "captureError" },
        { id: "jumpToLatest", label: "Jump to latest", description: "Scroll to the most recent line when scrolled up." },
      ],
      states: [
        { id: "recording", description: "Transcript actively appending; provisional speaker labels may change." },
        { id: "paused", description: "Capture paused; transcript frozen." },
        { id: "noSpeechYet", description: "Recording started but no speech transcribed yet." },
        { id: "farEndSilent", description: "Mic is captured but the far-end track has produced no audio for a sustained period (likely system-audio permission denied or wrong process). Warn that remote audio may be missing; offer continue-mic-only or stop. (System-audio auth can't be queried, so this is the only signal.)" },
        { id: "deviceChanged", description: "Input/output audio device changed mid-recording (e.g. AirPods connected); capture is being re-established. Brief gap expected; recording should not be lost." },
        { id: "captureError", description: "Audio capture failed/interrupted mid-recording and automatic retries were exhausted (must surface clearly, offer retry/stop)." },
        { id: "diskFull", description: "Disk filled during recording; capture is paused to protect already-written audio. Explain + offer to free space and resume, or stop and keep what exists." },
        { id: "processing", description: "Stopped; finalizing before Detail opens." },
      ],
      notes: [
        "Live speaker labels are provisional and may be re-grouped after the meeting; the UI must tolerate labels/segments changing.",
        "Two audio tracks exist (your mic vs far-end) — the design only needs a single merged, time-ordered transcript view.",
        "Capture interruptions (device change, coreaudiod restart, far-end app quit) are auto-retried with backoff before falling back to captureError; transient blips should self-heal and mark a small gap in the transcript rather than ending the recording.",
        "If the recorded far-end app quits/crashes mid-meeting, the recording auto-stops and finalizes what was captured rather than discarding it.",
        "Long meetings (multi-hour) must remain responsive — the transcript view should not assume an unbounded in-memory list.",
      ],
    },

    // 6) DETAIL (recording view) ────────────────────────────────────────────────
    {
      id: "detail",
      name: "Recording detail",
      kind: "window-tab",
      purpose:
        "Read a finished recording: full transcript with speaker labels, " +
        "audio playback, speaker renaming, summary generation, and export.",
      dataShown: [
        { name: "meta", type: "text", description: "Title, source app, date, duration, participants." },
        { name: "transcript", type: "list", description: "Final transcript: ordered segments with speaker label, timestamp, text." },
        { name: "speakers", type: "list", description: "Distinct speakers in this meeting with editable display names." },
        { name: "audio", type: "audio", description: "Playback of the recording; clicking a segment seeks to its time." },
        { name: "summaries", type: "list", description: "Generated summaries (each tied to a template + model), rendered as Markdown." },
        { name: "selectedTemplate", type: "enum", description: "Template chosen for the next summary." },
      ],
      actions: [
        { id: "play", label: "Play / Pause audio", description: "Control playback." },
        { id: "seekFromSegment", label: "Seek to segment", description: "Jump audio playback to a transcript segment's time." },
        { id: "renameSpeaker", label: "Rename speaker", description: "Set a display name for a speaker; applies across the whole transcript." },
        { id: "editSegment", label: "Edit text", description: "Correct the text of a transcript segment." },
        { id: "pickTemplate", label: "Choose summary template", description: "Select which template to summarize with." },
        { id: "summarize", label: "Generate summary", description: "Run the selected template against the transcript via the configured LLM.", availableWhen: "LLM configured" },
        { id: "regenerate", label: "Regenerate", description: "Re-run a summary (e.g. after editing the transcript, or to refresh a stale one)." },
        { id: "retrySummary", label: "Retry summary", description: "Retry a failed summary generation; for transient errors (timeout, connection refused) only, distinct from configuration errors.", availableWhen: "summaryError" },
        { id: "cancelSummary", label: "Cancel", description: "Abort an in-progress summary generation.", availableWhen: "summarizing" },
        { id: "copy", label: "Copy", description: "Copy transcript or a summary to the clipboard." },
        { id: "export", label: "Export", description: "Export transcript or summary to a file (Markdown / text / PDF)." },
        { id: "delete", label: "Delete recording", description: "Permanently delete this recording.", confirm: true },
      ],
      states: [
        { id: "processing", description: "Final transcript still being produced after stop." },
        { id: "recovered", description: "Recording was salvaged after an unexpected interruption (crash/quit/power-loss). Transcript/audio may be partial; must be clearly flagged as recovered." },
        { id: "ready", description: "Transcript available; no summary yet." },
        { id: "summarizing", description: "A summary is being generated (may stream in; cancellable)." },
        { id: "summaryReady", description: "At least one summary exists." },
        { id: "summaryStale", description: "The transcript was edited (text fixed or speaker renamed) after a summary was generated, so the existing summary may be out of date — invite regeneration without deleting the old one." },
        { id: "summaryError", description: "Summary generation failed — must distinguish transient errors (timeout, connection refused, server busy → offer retry) from permanent ones (bad URL/key, model not found, context overflow → link to LLM settings, no blind retry)." },
        { id: "llmNotConfigured", description: "Summaries unavailable because no LLM endpoint is set — must prompt the user to configure it." },
        { id: "audioMissing", description: "The audio file is missing or corrupt; transcript, summaries, copy and export still work, but playback/seek are unavailable and must say so." },
        { id: "playing", description: "Audio playing, with the active segment indicated." },
      ],
      notes: [
        "Editing transcript text or renaming a speaker after a summary exists moves the recording into summaryStale rather than silently invalidating the summary.",
        "Deleting or summarizing must behave sanely against in-progress work: deleting while processing/summarizing cancels that work cleanly and leaves no orphaned files or rows.",
        "Long-transcript summaries use map-reduce; a single failed chunk is retried in isolation rather than restarting the whole summary.",
      ],
    },

    // 7) SETTINGS ────────────────────────────────────────────────────────────────
    {
      id: "settings",
      name: "Settings",
      kind: "window-tab",
      purpose: "Configure detection, recording, transcription, summaries, templates, storage, and permissions.",
      dataShown: [
        { name: "sections", type: "list", description: "Grouped settings sections (see notes for the full list)." },
      ],
      actions: [
        // Detection
        { id: "manageApps", label: "Manage detected apps", description: "Enable/disable detection per app (Zoom, Slack, …) and set each to ask / always-record / never." },
        { id: "toggleDetection", label: "Toggle auto-detection", description: "Master switch for meeting auto-detection." },
        // Transcription
        { id: "selectEngine", label: "Select STT engine", description: "Choose the speech-to-text engine (default vs fallback). Disabled while a recording is active." },
        { id: "manageModels", label: "Manage models", description: "Download, switch, or remove transcription models (shows size + status). Switching/removing the active model is blocked while recording; removing the active model requires choosing a replacement." },
        // Summaries / LLM
        { id: "setLLMUrl", label: "Set LLM base URL", description: "Enter the OpenAI-compatible endpoint base URL." },
        { id: "setLLMKey", label: "Set API key", description: "Enter the API key (stored securely; shown masked)." },
        { id: "loadModels", label: "Load available models", description: "Fetch the list of models offered by the endpoint and pick one." },
        { id: "testConnection", label: "Test connection", description: "Verify the endpoint responds with the chosen credentials/model." },
        // Templates
        { id: "manageTemplates", label: "Manage templates", description: "Open the template editor (list/create/edit/duplicate/delete templates)." },
        // Storage
        { id: "setRetention", label: "Set retention", description: "Keep recordings forever or auto-delete after N days. If a shorter window would immediately delete existing recordings, confirm and state how many before applying.", confirm: true },
        { id: "openStorage", label: "Reveal storage location", description: "Open the local folder where data is stored." },
        { id: "clearAll", label: "Delete all recordings", description: "Wipe all stored recordings.", confirm: true },
        // Permissions
        { id: "reviewPermissions", label: "Review permissions", description: "Show microphone + system-audio permission status with links to fix in System Settings." },
      ],
      states: [
        { id: "default", description: "Browsing settings." },
        { id: "llmUnconfigured", description: "No LLM endpoint set yet." },
        { id: "llmTesting", description: "Testing the LLM connection." },
        { id: "llmConnected", description: "LLM connection verified." },
        { id: "llmError", description: "LLM connection failed (bad URL/key/model) — must show a clear reason." },
        { id: "modelDownloading", description: "A model is downloading (progress shown)." },
        { id: "modelDownloadFailed", description: "A model download failed/was interrupted — explain why (network, disk space, checksum) and offer resume/retry." },
        { id: "permissionMissing", description: "A required OS permission is not granted." },
        { id: "recordingActive", description: "A recording is in progress; transcription-engine/model changes are locked out until it ends." },
      ],
      notes: [
        "Settings sections: (1) General/Detection, (2) Recording, (3) Transcription engine & models, (4) Summaries/LLM, (5) Templates, (6) Storage & retention, (7) Permissions.",
        "API key must be entered/displayed as a secret (masked), never shown in plaintext by default.",
        "Test-connection failures must distinguish bad URL vs auth failure vs unreachable endpoint vs model-not-found so the user knows what to fix.",
        "Destructive storage actions (delete-all, retention that deletes existing recordings) always confirm and state the impact.",
      ],
    },

    // 7a) TEMPLATE EDITOR (sub-surface of Settings) ──────────────────────────────
    {
      id: "templateEditor",
      name: "Template editor",
      kind: "modal",
      purpose: "Create and edit summary templates that drive how summaries are generated.",
      dataShown: [
        { name: "templates", type: "list", description: "All templates (built-in presets + custom)." },
        { name: "name", type: "text", description: "Template name." },
        { name: "prompt", type: "longText", description: "The instruction/prompt body, supporting variables (e.g., {transcript}, {participants}, {date}, {duration})." },
        { name: "isBuiltIn", type: "boolean", description: "Whether it's a shipped preset (editable; can be duplicated)." },
      ],
      actions: [
        { id: "create", label: "New template", description: "Create a custom template." },
        { id: "duplicate", label: "Duplicate", description: "Copy an existing template as a starting point." },
        { id: "edit", label: "Edit", description: "Modify name + prompt + variables." },
        { id: "delete", label: "Delete", description: "Remove a custom template.", confirm: true },
        { id: "insertVariable", label: "Insert variable", description: "Insert an available variable token into the prompt." },
      ],
      states: [
        { id: "list", description: "Browsing templates." },
        { id: "editing", description: "Editing a template's fields." },
        { id: "unsaved", description: "Edits pending save/discard." },
        { id: "invalid", description: "Template can't be saved: name empty, an unknown variable token is used, or the required {transcript} variable is missing. Explain what's wrong before allowing save." },
      ],
      notes: [
        "Built-in presets to ship: 'Long Summary', 'One-on-One', 'Action Items & Decisions', 'Quick Notes / Standup'. All editable.",
        "A template must contain the {transcript} variable to be usable; saving without it is blocked with a clear reason.",
        "Deleting a template does not retroactively delete summaries already generated from it — past summaries keep their (snapshotted) template name even if the template no longer exists.",
        "Editing a built-in preset is allowed; offer a 'reset to default' so users can recover the shipped prompt.",
      ],
    },
  ],

  // ───────────────────────────────────────────────────────────────────────────
  // ENTITIES (data the surfaces display)
  // ───────────────────────────────────────────────────────────────────────────
  entities: [
    {
      name: "Meeting",
      description: "A single recorded meeting/huddle.",
      fields: [
        { name: "id", type: "text", description: "Unique id." },
        { name: "title", type: "text", description: "Editable title (default derived from app + date)." },
        { name: "sourceApp", type: "enum", description: "Zoom | Slack | Manual | (future others)." },
        { name: "startedAt", type: "datetime", description: "Recording start." },
        { name: "duration", type: "duration", description: "Length of the recording." },
        { name: "participantCount", type: "number", description: "Distinct speakers detected." },
        { name: "hasSummary", type: "boolean", description: "Whether any summary exists." },
        { name: "status", type: "enum", description: "recording | processing | ready | recovered | failed." },
      ],
    },
    {
      name: "Speaker",
      description: "A distinct voice within a meeting.",
      fields: [
        { name: "id", type: "text", description: "Unique id within the meeting." },
        { name: "label", type: "text", description: "System label: 'You' (your mic) or 'Speaker N'." },
        { name: "displayName", type: "text", description: "User-assigned name (optional)." },
      ],
    },
    {
      name: "TranscriptSegment",
      description: "One utterance/line in a transcript.",
      fields: [
        { name: "speakerId", type: "text", description: "Which speaker said it." },
        { name: "tStart", type: "duration", description: "Start time within the recording." },
        { name: "tEnd", type: "duration", description: "End time." },
        { name: "text", type: "longText", description: "Transcribed (and editable) text." },
        { name: "isProvisional", type: "boolean", description: "True while live; finalized after the meeting." },
        { name: "isGap", type: "boolean", description: "Marks a known gap where capture was briefly interrupted (device change / re-establish), so the transcript honestly shows missing audio rather than implying silence." },
      ],
    },
    {
      name: "Summary",
      description: "A generated summary of a meeting.",
      fields: [
        { name: "templateName", type: "text", description: "Template used." },
        { name: "model", type: "text", description: "LLM model used." },
        { name: "content", type: "markdown", description: "The summary, as structured Markdown." },
        { name: "createdAt", type: "datetime", description: "When generated." },
        { name: "isStale", type: "boolean", description: "True when the transcript changed after this summary was generated; signals it may be out of date." },
      ],
    },
    {
      name: "SummaryTemplate",
      description: "A reusable prompt that produces a summary.",
      fields: [
        { name: "name", type: "text", description: "Template name." },
        { name: "prompt", type: "longText", description: "Prompt body with variables." },
        { name: "isBuiltIn", type: "boolean", description: "Shipped preset vs custom." },
      ],
    },
    {
      name: "AppDetectionRule",
      description: "Per-app detection + consent preference.",
      fields: [
        { name: "app", type: "enum", description: "Zoom | Slack | (future others)." },
        { name: "enabled", type: "boolean", description: "Detection on/off for this app." },
        { name: "consentMode", type: "enum", description: "ask | always | never." },
      ],
    },
    {
      name: "LLMConfig",
      description: "Connection settings for summary generation.",
      fields: [
        { name: "baseUrl", type: "text", description: "OpenAI-compatible endpoint base URL." },
        { name: "apiKey", type: "secret", description: "API key (stored securely, shown masked)." },
        { name: "model", type: "text", description: "Selected model name." },
        { name: "status", type: "enum", description: "unconfigured | testing | connected | error." },
        { name: "lastErrorKind", type: "enum", description: "When status is error: unreachable | authFailed | modelNotFound | badUrl | timeout — drives whether a retry vs a settings fix is offered." },
      ],
    },
    {
      name: "STTModel",
      description: "An on-device transcription model.",
      fields: [
        { name: "name", type: "text", description: "Model name." },
        { name: "sizeLabel", type: "text", description: "Download size." },
        { name: "tradeoff", type: "text", description: "Speed/quality tradeoff descriptor." },
        { name: "status", type: "enum", description: "not-downloaded | downloading | ready | active." },
      ],
    },
    {
      name: "RetentionPolicy",
      description: "How long recordings are kept.",
      fields: [
        { name: "mode", type: "enum", description: "keep-forever | auto-delete." },
        { name: "days", type: "number", description: "Delete after N days (when auto-delete)." },
      ],
    },
  ],

  // ───────────────────────────────────────────────────────────────────────────
  // FLOWS (journeys the design must support end-to-end)
  // ───────────────────────────────────────────────────────────────────────────
  flows: [
    {
      id: "firstRun",
      name: "First-run setup",
      steps: [
        "Launch → onboarding starts.",
        "Grant microphone + system-audio permissions.",
        "Choose and download a transcription model.",
        "Optionally configure the summary LLM (base URL + key + model).",
        "Acknowledge recording-consent disclaimer.",
        "Finish → land on Library (empty state).",
      ],
    },
    {
      id: "autoDetectRecord",
      name: "Auto-detect → consent → record",
      steps: [
        "A known meeting app starts using audio → detection fires.",
        "If app's consentMode is 'ask': show consent prompt (Record / Ignore / Always-record).",
        "If 'always': start recording directly + show a non-blocking notification.",
        "On Record: menu-bar shows recording; user can open Live.",
        "Audio captured on two tracks; live transcript appends with provisional speaker labels.",
      ],
    },
    {
      id: "manualRecord",
      name: "Manual record",
      steps: [
        "User clicks 'Record now' (menu-bar or Library).",
        "Recording starts immediately; Live becomes active.",
      ],
    },
    {
      id: "stopAndSave",
      name: "Stop → finalize → save",
      steps: [
        "User stops recording (menu-bar or Live).",
        "App finalizes the transcript and groups speakers (processing state).",
        "Recording is saved and opened in Detail (ready state).",
      ],
    },
    {
      id: "summarize",
      name: "Generate a summary",
      steps: [
        "In Detail, user picks a template and clicks Generate summary.",
        "If no LLM configured → prompt to configure it.",
        "Summary is generated (summarizing state, may stream) → shown as Markdown.",
        "User can regenerate, switch template, copy, or export.",
      ],
    },
    {
      id: "renameSpeakers",
      name: "Rename speakers",
      steps: [
        "In Detail, user renames 'Speaker N' to a real name.",
        "The new name applies across the entire transcript.",
      ],
    },
    {
      id: "export",
      name: "Export / share",
      steps: [
        "In Detail, user exports a transcript or summary to Markdown / text / PDF, or copies to clipboard.",
      ],
    },
    {
      id: "configureLLM",
      name: "Configure the summary LLM",
      steps: [
        "In Settings → Summaries, enter base URL + API key.",
        "Load available models from the endpoint and select one.",
        "Test connection → connected (or error with reason).",
      ],
    },
    {
      id: "manageTemplates",
      name: "Manage summary templates",
      steps: [
        "In Settings → Templates, browse presets + custom templates.",
        "Create / duplicate / edit / delete; edit prompt with variable tokens.",
      ],
    },
    {
      id: "manageModels",
      name: "Switch transcription model",
      steps: [
        "In Settings → Transcription, view models with size/status.",
        "Download a new model (progress) or switch the active one; optionally remove old ones.",
      ],
    },
    {
      id: "captureRecovery",
      name: "Capture interruption → recover",
      steps: [
        "During recording, capture is interrupted (audio device changes, far-end app quits, coreaudiod restarts, or far-end goes silent).",
        "App auto-retries with backoff; a brief gap is marked in the transcript and capture self-heals where possible.",
        "If the far-end track can't be recovered, fall back to mic-only with a warning; if nothing can be recovered, stop and finalize what was captured.",
        "If retries are exhausted, Live shows captureError with explicit Retry / Stop (keep) options — the partial recording is never silently discarded.",
      ],
    },
    {
      id: "crashRecovery",
      name: "Crash / quit during recording → recover on next launch",
      steps: [
        "A recording is interrupted by a crash, force-quit, power loss, or sleep.",
        "On next launch, the app detects the meeting left in recording/processing state.",
        "It salvages incrementally-flushed audio, re-runs finalize, and saves the meeting with status 'recovered'.",
        "The recording opens (or is listed) clearly flagged as recovered, possibly partial.",
      ],
    },
  ],

  // ───────────────────────────────────────────────────────────────────────────
  // GLOBAL BEHAVIORS (cross-cutting, touch many surfaces)
  // ───────────────────────────────────────────────────────────────────────────
  globalBehaviors: [
    { id: "recordingVisibility", description: "It must ALWAYS be unambiguous whether audio is currently being recorded, from anywhere in the app and from the menu bar (privacy-critical)." },
    { id: "offlineFirst", description: "Every feature except model download and summary generation works with no network. Transcription never requires the internet." },
    { id: "consentDefault", description: "No recording ever begins without an explicit prior choice (per-meeting prompt or a remembered per-app 'always' decision)." },
    { id: "nonBlockingNotifications", description: "Background events (auto-record started, summary finished, capture error) surface as non-blocking notifications, not just in-window state." },
    { id: "errorClarity", description: "Failures (capture interrupted, LLM unreachable, model download failed, permission missing) must explain what happened and offer the next action (retry / open relevant settings)." },
    { id: "emptyStates", description: "Library, Detail (no summary), and Settings (no LLM/model) each need a first-use empty state that guides the user to the next step." },
    { id: "secretsMasking", description: "The LLM API key is a secret: masked by default, never logged or displayed in plaintext casually." },
    { id: "provisionalLiveData", description: "Live transcript content and speaker labels are provisional and can change once the meeting is finalized; the UI must handle late re-grouping/relabeling gracefully." },
    { id: "retryPolicy", description: "Recoverable failures retry before surfacing as errors. Capture interruptions auto-retry with bounded backoff; model downloads are resumable + manually retryable; LLM/network calls retry only for transient errors (timeout, connection refused, 5xx) and never blindly for permanent ones (4xx auth/bad-request, model-not-found). Every surfaced error states whether retrying is the right next action." },
    { id: "captureDegradation", description: "Capture failures degrade gracefully instead of dropping the recording: a transient blip marks a short transcript gap and self-heals; losing the far-end track falls back to mic-only with a warning; only an unrecoverable failure stops the recording — and even then it finalizes and saves whatever was already captured." },
    { id: "crashRecovery", description: "An interrupted recording (crash, force-quit, power loss, system sleep) is never silently lost. Audio is flushed incrementally so partial data survives; on next launch any meeting left in a recording/processing state is detected, salvaged, finalized, and shown as 'recovered'." },
    { id: "diskSafety", description: "Disk space is checked before model downloads and watched during recording. Low space warns early; a full disk pauses capture to protect already-written audio rather than corrupting the file, and offers resume-after-freeing or stop-and-keep." },
    { id: "concurrencySafety", description: "Conflicting actions are prevented rather than left to race: only one recording is active at a time; a second detected meeting queues a prompt instead of overwriting; transcription engine/model changes are locked while recording; deleting a recording cancels any in-progress processing/summarizing for it and cleans up its files." },
    { id: "partialFailureIsolation", description: "Multi-step jobs isolate failures: in map-reduce summarization a single failed chunk is retried on its own instead of restarting the whole summary, and a successfully captured recording is still saved even if a later finalize/refine step fails." },
    { id: "permissionRevocation", description: "OS permissions can be revoked mid-session, not just missing at startup. Losing mic or system-audio access during a recording is surfaced immediately (degrade or stop), and the relevant surface always offers a deep link to fix it in System Settings." },
  ],
};

export default spec;
