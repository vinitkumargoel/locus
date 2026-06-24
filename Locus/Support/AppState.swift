import SwiftUI
import Combine

// MARK: - State enums (port of the prototype's string unions)

enum Screen { case library, live, detail, settings }

/// Top-level recording lifecycle.
enum RecState { case idle, recording, paused, processing, captureError }

/// Sub-state of the live screen.
enum LiveSub { case recording, noSpeech, error }

enum DetailState { case processing, ready }

enum SummaryState { case notConfigured, empty, generating, ready, error }

enum AIStatus { case unconfigured, testing, connected, error }

/// Settings tabs. `.general` is the prototype's "detection" section.
enum SettingsSection: CaseIterable {
    case general, transcription, ai, templates, storage, permissions
    var title: String {
        switch self {
        case .general:       return "General"
        case .transcription: return "Transcription"
        case .ai:            return "Summaries / AI"
        case .templates:     return "Templates"
        case .storage:       return "Storage"
        case .permissions:   return "Permissions"
        }
    }
}

enum Retention { case forever, auto }

enum ConsentMode: String { case ask, always, never }

// MARK: - AppState
//
// Single source of truth for the whole app. Mirrors the `state` object and all
// handlers from the Locus prototype's `Component` class. This is the UI/front-end
// state machine — the real capture / STT / LLM engine plugs in behind these
// actions later (see DESIGN.md / TASKS.md).

final class AppState: ObservableObject {
    // Appearance
    @Published var dark = false

    // Navigation
    @Published var screen: Screen = .library

    // Recording lifecycle
    @Published var rec: RecState = .idle
    @Published var elapsed = 0
    @Published var liveSub: LiveSub = .recording

    // Menu-bar agent / consent
    @Published var agentOpen = false
    @Published var consentOpen = false
    @Published var alwaysRecord = false
    @Published var detection = true

    // Library
    @Published var search = ""

    // Detail
    @Published var selectedMeetingID = "m1"
    @Published var detailState: DetailState = .ready
    @Published var playing = false
    @Published var playPos = 0
    @Published var speakerNames: [String: String] = ["s1": "You", "s2": "Speaker 2", "s3": "Speaker 3"]

    // Summary
    @Published var summaryState: SummaryState = .empty
    @Published var streamText = ""

    // AI / summaries config
    // Privacy: ship un-configured. The network-bound summary path stays gated
    // (generate() guards on aiConfigured) until the user saves an endpoint and
    // passes Test connection.
    @Published var aiConfigured = false
    @Published var aiStatus: AIStatus = .unconfigured
    @Published var aiMasked = true

    // Settings
    @Published var settingsSection: SettingsSection = .general
    @Published var activeTemplateID = "t3"
    @Published var editTemplateID = "t1"
    @Published var teUnsaved = false
    @Published var retention: Retention = .forever
    // Privacy default-deny: every app starts at .ask. Users opt into .always.
    @Published var consentMode: [String: ConsentMode] = ["Zoom": .ask, "Slack": .ask]

    let retentionDays = 30
    /// Stable, ordered speaker roster — single source of truth for chips + colors.
    let speakerKeys = ["s1", "s2", "s3"]
    /// Approximate seconds-per-line stride for the simulated playback highlight.
    private let secondsPerLine = 12

    // MARK: Derived state

    var recording: Bool { rec == .recording }
    var paused: Bool { rec == .paused }
    var isCapturing: Bool { rec == .recording || rec == .paused || rec == .captureError }
    var liveAvailable: Bool { isCapturing }
    var elapsedString: String { TimeFmt.mmss(elapsed) }

    /// Theme-independent label for the menu-bar status item.
    var menuBarLabelText: String {
        switch rec {
        case .recording:    return "REC " + TimeFmt.mmss(elapsed)
        case .paused:       return "Paused"
        case .processing:   return "Saving…"
        case .captureError: return "Error"
        case .idle:         return detection ? "Idle" : "Off"
        }
    }

    var filteredMeetings: [Meeting] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SampleData.meetings }
        return SampleData.meetings.filter {
            $0.title.lowercased().contains(q) || $0.body.contains(q)
        }
    }

    var noMatches: Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        return !q.isEmpty && filteredMeetings.isEmpty
    }

    var selectedMeeting: Meeting { SampleData.meeting(id: selectedMeetingID) }

    /// Display name for a speaker key, falling back to the key.
    func speakerName(_ key: String) -> String { speakerNames[key] ?? key }

    // MARK: Timers

    private var ticker: AnyCancellable?
    private var generateTimer: Timer?

    init() {
        // 1 Hz clock: advances the recording timer and playback position,
        // matching the prototype's setInterval(…, 1000).
        ticker = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func tick() {
        if rec == .recording { elapsed += 1 }
        if playing { playPos = min(playPos + 1, SampleData.detailDurationSeconds) }
    }

    deinit {
        ticker?.cancel()
        generateTimer?.invalidate()
    }

    /// Briefly show the "Listening…" state at the start of a recording, then
    /// flip to the streaming-lines state (simulates the first speech arriving).
    private func scheduleListeningTransition() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.liveSub == .noSpeech else { return }
            self.liveSub = .recording
        }
    }

    // MARK: Theme / menu bar

    func toggleTheme() { dark.toggle() }
    func toggleAgent() { agentOpen.toggle() }

    // MARK: Recording controls

    func recordNow() {
        rec = .recording
        elapsed = 0
        screen = .live
        liveSub = .noSpeech
        agentOpen = false
        consentOpen = false
        scheduleListeningTransition()
    }

    func pauseOrResume() {
        rec = (rec == .paused) ? .recording : .paused
    }

    func resumeRec() {
        rec = .recording
        liveSub = .recording
    }

    func stopRec() {
        rec = .processing
        screen = .detail
        selectedMeetingID = "m1"
        detailState = .processing
        summaryState = aiConfigured ? .empty : .notConfigured
        agentOpen = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self else { return }
            self.rec = .idle
            self.detailState = .ready
        }
    }

    func openLive() {
        screen = .live
        agentOpen = false
    }

    func openWindow() { agentOpen = false }

    func toggleDetection() { detection.toggle() }

    func simulateDetect() {
        consentOpen = true
        agentOpen = false
    }

    /// Debug affordance to exercise the capture-error state (no real capture yet).
    func simulateCaptureError() {
        rec = .captureError
        screen = .live
        agentOpen = false
    }

    // MARK: Navigation

    func goLibrary() { screen = .library }
    func goSettings() { screen = .settings }
    func goAISettings() {
        screen = .settings
        settingsSection = .ai
    }

    func openMeeting(_ meeting: Meeting) {
        screen = .detail
        selectedMeetingID = meeting.id
        summaryState = meeting.hasSummary ? .ready : (aiConfigured ? .empty : .notConfigured)
        detailState = .ready
        playing = false
        playPos = 0
    }

    // MARK: Playback

    func togglePlay() { playing.toggle() }

    func seek(toLineIndex index: Int) {
        playing = true
        playPos = index * secondsPerLine
    }

    /// Index of the transcript line currently "playing" (for highlight).
    var currentLineIndex: Int {
        guard !SampleData.transcript.isEmpty else { return 0 }
        return min(playPos / secondsPerLine, SampleData.transcript.count - 1)
    }

    // MARK: Speakers

    func renameSpeaker(_ key: String, to name: String) {
        speakerNames[key] = name
    }

    // MARK: Summary generation (simulated stream)

    func generate() {
        guard aiConfigured else { summaryState = .notConfigured; return }
        summaryState = .generating
        streamText = ""
        generateTimer?.invalidate()
        let full = SampleData.summaryStreamText
        var i = 0
        generateTimer = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            i += 4
            self.streamText = String(full.prefix(i))
            if i >= full.count {
                timer.invalidate()
                self.summaryState = .ready
            }
        }
    }

    // MARK: AI settings

    func toggleMask() { aiMasked.toggle() }

    func testAIConnection() {
        aiStatus = .testing
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.aiStatus = .connected
            self?.aiConfigured = true
        }
    }

    // MARK: Templates

    func selectTemplateForEditing(_ id: String) {
        editTemplateID = id
        teUnsaved = false
    }

    func markTemplateDirty() { teUnsaved = true }
    func saveTemplate() { teUnsaved = false }
    func discardTemplate() { teUnsaved = false }
    func newTemplate() { teUnsaved = true }

    // MARK: Settings misc

    func setSettingsSection(_ s: SettingsSection) { settingsSection = s }
    func setRetention(_ r: Retention) { retention = r }
    func setConsentMode(app: String, mode: ConsentMode) { consentMode[app] = mode }

    // MARK: Consent prompt

    func toggleAlways() { alwaysRecord.toggle() }
    func consentIgnore() { consentOpen = false }
    func consentRecord() {
        consentOpen = false
        // The real detection path should consult consentMode[app]:
        // .always -> auto-record, .never -> skip, .ask -> show this prompt.
        if alwaysRecord { consentMode["Zoom"] = .always }
        rec = .recording
        elapsed = 0
        screen = .live
        liveSub = .noSpeech
        scheduleListeningTransition()
    }

    // MARK: AI status presentation

    /// (label, dot, background, border, text) for the AI status banner.
    func aiStatusStyle(_ theme: Theme) -> (label: String, dot: Color, bg: Color, border: Color, fg: Color) {
        switch aiStatus {
        case .unconfigured:
            return ("Not configured", theme.text3, theme.card2, theme.border2, theme.text2)
        case .testing:
            return ("Testing connection…", theme.warn, theme.recSoft, theme.warn, theme.warn)
        case .connected:
            return ("Connected · llama-3.1-8b", theme.ok, theme.okSoft, theme.ok, theme.ok)
        case .error:
            return ("Connection failed — endpoint unreachable", theme.rec, theme.recSoft, theme.rec, theme.rec)
        }
    }
}
