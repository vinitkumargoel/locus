import SwiftUI
import Combine
import AVFoundation
import AppKit
import OSLog

// MARK: - State enums (port of the prototype's string unions)

enum Screen { case library, live, detail, settings }

/// Top-level recording lifecycle.
enum RecState { case idle, recording, paused, processing, captureError }

/// Sub-state of the live screen.
enum LiveSub { case recording, noSpeech, error }

enum DetailState { case processing, ready }

enum SummaryState { case notConfigured, empty, generating, ready, error }

enum AIStatus { case unconfigured, testing, connected, error }

/// Readiness of the on-device model bundle (Parakeet STT + FluidAudio diarization).
/// Distinct from `ModelStatus` (the per-row STT picker state in Models.swift):
/// this tracks the one-time download/load that gates live transcription.
enum ModelState: Equatable {
    case unknown                 // not yet attempted this launch
    case downloading(Double)     // 0...1 fraction
    case ready
    case failed(String)          // user-facing message
}

/// Settings tabs. `.general` is the prototype's "detection" section.
enum SettingsSection: CaseIterable {
    case general, recordingBar, transcription, ai, templates, storage, permissions, diagnostics
    var title: String {
        switch self {
        case .general:       return "General"
        case .recordingBar:  return "Recording Bar"
        case .transcription: return "Transcription"
        case .ai:            return "Summaries / AI"
        case .templates:     return "Templates"
        case .storage:       return "Storage"
        case .permissions:   return "Permissions"
        case .diagnostics:   return "Diagnostics"
        }
    }
}

enum Retention { case forever, auto }

enum ConsentMode: String, Codable { case ask, always, never }

/// One row in the Settings → Diagnostics self-test. `passed == nil` means the
/// check hasn't run / is in flight (⏳); `true` = ✅, `false` = ⚠️. `detail`
/// carries the concise outcome or the thrown error's `localizedDescription`.
struct DiagnosticCheck: Identifiable {
    let id: String
    let name: String
    var passed: Bool?
    var detail: String
}

// MARK: - Timeout helper

/// Thrown by `withTimeout` when the wrapped operation doesn't finish in time.
struct TimeoutError: Error {}

/// Race `operation` against a sleep of `seconds`. If the operation wins, its
/// value is returned; if the timer wins, the operation task is cancelled and
/// `TimeoutError` is thrown so the caller can fall back instead of hanging
/// forever. Used to bound the refine/diarize awaits at finalize so a wedged
/// STT/diarization pass can't strand the meeting in `.processing`.
func withTimeout<T: Sendable>(
    _ seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        // First task to finish wins; cancel the loser (the sleeper, or the
        // still-running operation on timeout) before returning.
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - AppState
//
// Single source of truth for the whole app and the coordinator over the service
// layer (see Services/Contracts.swift). Views bind to the @Published properties;
// every action routes to a real service and republishes its output here.

@MainActor
final class AppState: ObservableObject {
    let services: Services

    // Appearance
    @Published var dark = false

    // Navigation
    @Published var screen: Screen = .library

    // Recording lifecycle
    @Published var rec: RecState = .idle { didSet { syncHUDPresentation() } }
    @Published var elapsed = 0
    @Published var liveSub: LiveSub = .recording

    // Menu-bar agent / consent
    @Published var agentOpen = false
    @Published var consentOpen = false
    @Published var alwaysRecord = false
    @Published var detection = true
    /// App that triggered the current consent prompt / recording (bundle id + label).
    @Published var pendingApp: (label: String, bundleId: String)? = nil

    // Library (loaded from the store)
    @Published var search = "" { didSet { scheduleSearch() } }
    @Published var meetings: [Meeting] = []
    @Published var libraryDiskBytes: Int64 = 0
    /// Non-nil when the on-disk store couldn't be opened; surfaced as a banner so
    /// an empty library can't be mistaken for "no recordings".
    @Published var storeError: String? = nil
    /// Non-nil when the last recording couldn't be transcribed/saved cleanly.
    @Published var finalizeWarning: String? = nil

    // Detail
    @Published var selectedMeetingID = ""
    @Published var selectedMeetingRow: MeetingRow?
    @Published var transcriptLines: [TranscriptLine] = []
    @Published var detailState: DetailState = .ready
    @Published var playing = false
    @Published var playPos = 0
    @Published var detailDurationSeconds = 1
    @Published var speakerNames: [String: String] = ["s1": "You", "s2": "Speaker 2", "s3": "Speaker 3"]

    // Live transcript
    @Published var liveLines: [LiveLine] = []

    // Floating recording bar (HUD) — an NSPanel that overlays other apps so you
    // can pause/stop and watch the live transcript during a call. State here is
    // the single source of truth; `FloatingHUDController` renders + positions it.
    @Published var hudEnabled: Bool = true { didSet { services.settings.hudEnabled = hudEnabled; syncHUDPresentation() } }
    @Published var hudExpanded: Bool = false { didSet { hud.applyExpanded(hudExpanded) } }
    /// Transient: show the bar while idle so it can be drag-positioned outside a
    /// meeting (Settings → Recording Bar → "Position on screen"). Not persisted.
    @Published var hudPreview: Bool = false { didSet { syncHUDPresentation() } }
    /// Normalized bar position (0…1 top-left), persisted on edit. Written by the
    /// controller on drag and by `moveHUD(to:)` for the preset grid.
    @Published var hudPosX: Double = 1.0 { didSet { services.settings.hudPosX = hudPosX } }
    @Published var hudPosY: Double = 0.0 { didSet { services.settings.hudPosY = hudPosY } }
    /// Created lazily the first time the bar needs to show; holds AppState weakly.
    private(set) lazy var hud = FloatingHUDController(app: self)

    // Summary
    @Published var summaryState: SummaryState = .empty
    @Published var streamText = ""
    @Published var detailSummaries: [SummaryRow] = []

    // AI / summaries config
    @Published var aiConfigured = false
    @Published var aiStatus: AIStatus = .unconfigured
    @Published var aiMasked = true
    @Published var aiModelsAvailable: [String] = []
    // Editable fields, persisted through the settings/secrets services on edit.
    @Published var aiBaseURLField: String = "" { didSet { services.settings.aiBaseURL = aiBaseURLField } }
    @Published var aiKeyField: String = "" { didSet { services.secrets.setApiKey(aiKeyField.isEmpty ? nil : aiKeyField) } }
    @Published var aiModel: String = "" { didSet { services.settings.aiModel = aiModel } }

    // Transcription model selection, persisted on edit.
    @Published var sttVersion: String = "v3" { didSet { services.settings.sttModelVersion = sttVersion } }

    // On-device model bundle readiness (download/load progress + failure).
    @Published var modelState: ModelState = .unknown

    // Settings
    @Published var settingsSection: SettingsSection = .general
    @Published var diagnostics: [DiagnosticCheck] = []
    /// True while `runDiagnostics()` is in flight (disables the Run button).
    @Published var diagnosticsRunning = false
    @Published var templatesList: [TemplateRow] = []
    @Published var activeTemplateID = "t3"
    @Published var editTemplateID = "t1"
    @Published var teUnsaved = false
    @Published var retention: Retention = .forever
    @Published var consentMode: [String: ConsentMode] = ["Zoom": .ask, "Slack": .ask]

    let retentionDays = 30
    /// Stable, ordered speaker roster — single source of truth for chips + colors.
    let speakerKeys = ["s1", "s2", "s3"]
    /// Approximate seconds-per-line stride for the simulated playback fallback
    /// (used only when the meeting has no audio file on disk — e.g. previews).
    private let secondsPerLine = 12

    // Detail playback. When the open meeting has a real audio file we drive
    // playback (and the line highlight) from AVAudioPlayer; otherwise `player`
    // stays nil and we fall back to the simulated ticker + `secondsPerLine`.
    // `segmentTimes` is the per-line [start, end) range in seconds, parallel to
    // `transcriptLines`, so the highlight follows the REAL segment timings.
    private var player: AVAudioPlayer?
    private var segmentTimes: [(start: Double, end: Double)] = []

    private var cancellables = Set<AnyCancellable>()
    private var ticker: AnyCancellable?
    private var searchTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var activeMeetingID: String?
    private let log = Logger(subsystem: "com.locus.app", category: "AppState")

    private static let bundleForApp = ["Zoom": "us.zoom.xos", "Slack": "com.tinyspeck.slackmacgap"]

    // MARK: Init

    init(services: Services = .preview()) {
        self.services = services
        self.dark = services.settings.darkAppearance
        self.detection = services.settings.detectionEnabled
        self.aiMasked = true
        self.aiBaseURLField = services.settings.aiBaseURL
        self.aiModel = services.settings.aiModel
        self.aiKeyField = services.secrets.apiKey() ?? ""
        self.sttVersion = services.settings.sttModelVersion
        self.retention = services.settings.retentionForever ? .forever : .auto
        self.hudEnabled = services.settings.hudEnabled
        self.hudPosX = services.settings.hudPosX
        self.hudPosY = services.settings.hudPosY

        // 1 Hz clock for elapsed (recording) + playback position (detail).
        ticker = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }

        subscribeCapture()
        subscribeCaptureAudio()
        subscribeLiveTranscript()
        subscribeDetection()

        Task { await bootstrap() }
    }

    deinit { ticker?.cancel() }

    private func bootstrap() async {
        do {
            try await services.store.bootstrap()
            storeError = nil
        } catch {
            // A store that can't open means the library, detail and new recordings
            // would all silently no-op. Surface it instead of looking empty.
            log.error("Store bootstrap failed: \(error.localizedDescription, privacy: .public)")
            storeError = "Couldn't open the recordings database. Your recordings can't be loaded or saved until this is resolved."
        }
        await refreshAIConfigured()
        for appName in ["Zoom", "Slack"] {
            if let bundle = Self.bundleForApp[appName],
               let mode = (try? await services.store.consentMode(bundleId: bundle)) ?? nil {
                consentMode[appName] = mode
            }
        }
        await reloadLibrary()
        await reloadTemplates()
        if detection { services.detector.start() }
        // Crash recovery: finalize anything left mid-flight. On failure mark the
        // row `.failed` so it stops reappearing as "recoverable" every launch.
        if let stuck = try? await services.store.recoverableMeetings() {
            for m in stuck {
                do {
                    try await services.store.finalizeMeeting(id: m.id, durationSec: m.durationSec,
                                                             status: .recovered,
                                                             audioFarPath: m.audioFarPath,
                                                             audioMicPath: m.audioMicPath)
                } catch {
                    log.error("Recovery finalize failed for \(m.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    try? await services.store.finalizeMeeting(id: m.id, durationSec: m.durationSec,
                                                              status: .failed,
                                                              audioFarPath: m.audioFarPath,
                                                              audioMicPath: m.audioMicPath)
                }
            }
            if !stuck.isEmpty { await reloadLibrary() }
        }
    }

    /// Bridge captured 16 kHz mono buffers into the live STT engine. Without this
    /// the capture pipeline produced audio that nothing consumed, so the live
    /// transcript stayed empty on the real engine.
    private func subscribeCaptureAudio() {
        services.capture.audio
            .sink { [weak self] payload in
                guard let self else { return }
                let (buffer, track) = payload
                Task { await self.services.stt.feed(buffer, track: track) }
            }
            .store(in: &cancellables)
    }

    private func tick() {
        if rec == .recording { elapsed += 1 }
        guard playing else { return }
        if let player {
            // Real playback: read the engine's clock rather than counting ticks.
            if player.isPlaying {
                playPos = Int(player.currentTime)
            } else {
                // Reached end of file (or was stopped underneath us): pause at 0.
                playing = false
                player.currentTime = 0
                playPos = 0
            }
        } else {
            // Simulated fallback (no audio file on disk, e.g. previews).
            playPos = min(playPos + 1, max(1, detailDurationSeconds))
        }
    }

    // MARK: Service subscriptions

    private func subscribeCapture() {
        services.capture.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handleCapture(event) }
            .store(in: &cancellables)
    }

    private func handleCapture(_ event: CaptureEvent) {
        switch event {
        case .started:
            rec = .recording
        case .level:
            break   // meters animate independently; hook here for real VU later
        case .farEndSilent:
            liveSub = .recording   // keep recording mic-only; surfaced in UI copy
        case .deviceChanged:
            break   // capture self-heals; brief gap is marked downstream
        case .diskFull, .error:
            rec = .captureError
            screen = .live
            // Don't strand the in-flight meeting in `.recording`; mark it failed
            // (its partially-flushed audio is still on disk and recoverable).
            if let id = activeMeetingID {
                activeMeetingID = nil
                Task {
                    try? await services.store.finalizeMeeting(id: id, durationSec: elapsed,
                                                              status: .failed,
                                                              audioFarPath: nil, audioMicPath: nil)
                    await reloadLibrary()
                }
            }
        case let .stopped(far, mic, duration):
            Task { await finalizeRecording(durationSec: duration, audioFar: far, audioMic: mic) }
        }
    }

    private func subscribeLiveTranscript() {
        services.stt.liveUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in self?.applyLiveUpdate(update) }
            .store(in: &cancellables)
    }

    private func applyLiveUpdate(_ u: LiveUpdate) {
        guard rec == .recording || rec == .paused else { return }
        if liveSub == .noSpeech { liveSub = .recording }
        let key = (u.track == .you) ? "s1" : "s2"
        let line = LiveLine(speakerKey: key, speaker: speakerName(key),
                            time: TimeFmt.mmss(Int(u.timeSec)), text: u.text, isFinal: u.isFinal)
        // Replace a trailing non-final line from the same track, else append.
        if let last = liveLines.last, !last.isFinal, last.speakerKey == key {
            liveLines[liveLines.count - 1] = line
        } else {
            liveLines.append(line)
        }
    }

    private func subscribeDetection() {
        services.detector.detections
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meeting in self?.handleDetection(meeting) }
            .store(in: &cancellables)
    }

    private func handleDetection(_ meeting: DetectedMeeting) {
        guard rec == .idle else { return }   // single active recording; ignore while busy
        Task {
            let mode = (try? await services.store.consentMode(bundleId: meeting.bundleId)) ?? .ask
            switch mode {
            case .never: return
            case .always:
                pendingApp = (meeting.app, meeting.bundleId)
                startRecording(label: meeting.app, bundleId: meeting.bundleId)
            case .ask:
                pendingApp = (meeting.app, meeting.bundleId)
                agentOpen = false
                consentOpen = true
            }
        }
    }

    // MARK: Derived state

    var recording: Bool { rec == .recording }
    var paused: Bool { rec == .paused }
    var isCapturing: Bool { rec == .recording || rec == .paused || rec == .captureError }
    var liveAvailable: Bool { isCapturing }
    var elapsedString: String { TimeFmt.mmss(elapsed) }

    var menuBarLabelText: String {
        switch rec {
        case .recording:    return "REC " + TimeFmt.mmss(elapsed)
        case .paused:       return "Paused"
        case .processing:   return "Saving…"
        case .captureError: return "Error"
        case .idle:         return detection ? "Idle" : "Off"
        }
    }

    var filteredMeetings: [Meeting] { meetings }

    var noMatches: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty && meetings.isEmpty
    }

    var selectedMeeting: Meeting {
        if let row = selectedMeetingRow { return Self.uiMeeting(row) }
        return Meeting(id: "", title: "Recording", app: .manual, date: "", duration: "0:00",
                       people: 0, hasSummary: false, body: "")
    }

    func speakerName(_ key: String) -> String { speakerNames[key] ?? defaultLabel(for: key) }

    /// Speaker keys actually present in the loaded transcript, ordered s1, s2, ….
    /// Drives the editable speaker chips and the summary participant list, so a
    /// meeting with a 4th speaker (or only one) renders correctly rather than a
    /// hardcoded three.
    var detailSpeakerKeys: [String] {
        let keys = Set(transcriptLines.map(\.speakerKey))
        let ordered = keys.sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
        return ordered.isEmpty ? ["s1"] : ordered
    }

    var currentLineIndex: Int {
        guard !transcriptLines.isEmpty else { return 0 }
        // Real timings: the line whose [start, end) range contains playPos.
        if segmentTimes.count == transcriptLines.count {
            let pos = Double(playPos)
            if let i = segmentTimes.firstIndex(where: { pos >= $0.start && pos < $0.end }) {
                return i
            }
            // Between segments (a gap) or past the last end: snap to the most
            // recent line that has already started, else the first line.
            if let i = segmentTimes.lastIndex(where: { pos >= $0.start }) { return i }
            return 0
        }
        // Simulated fallback stride.
        return min(playPos / secondsPerLine, transcriptLines.count - 1)
    }

    // MARK: Data loading

    private func reloadLibrary() async {
        let q = search.trimmingCharacters(in: .whitespaces)
        let rows = (try? await (q.isEmpty ? services.store.allMeetings()
                                          : services.store.searchMeetings(q))) ?? []
        meetings = rows.map(Self.uiMeeting)
        libraryDiskBytes = (try? await services.store.diskUsageBytes()) ?? 0
    }

    private func reloadTemplates() async {
        templatesList = (try? await services.store.templates()) ?? []
        if !templatesList.contains(where: { $0.id == activeTemplateID }) {
            activeTemplateID = templatesList.first?.id ?? activeTemplateID
        }
        if !templatesList.contains(where: { $0.id == editTemplateID }) {
            editTemplateID = templatesList.first?.id ?? editTemplateID
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.reloadLibrary()
        }
    }

    var libraryFooter: String {
        let gb = Double(libraryDiskBytes) / 1_073_741_824
        return "\(meetings.count) recordings · " + String(format: "%.2f GB on disk", gb)
    }

    // MARK: Theme / menu bar

    func toggleTheme() { dark.toggle(); services.settings.darkAppearance = dark }
    func toggleAgent() { agentOpen.toggle() }

    // MARK: Recording controls

    func recordNow() {
        pendingApp = ("Manual", "manual")
        startRecording(label: "Manual", bundleId: nil)
    }

    private func startRecording(label: String, bundleId: String?) {
        elapsed = 0
        liveLines = []
        liveSub = .noSpeech
        screen = .live
        agentOpen = false
        consentOpen = false
        finalizeWarning = nil
        hudPreview = false   // a live session drives the bar; drop any Settings position-preview
        rec = .recording   // optimistic; flips to .captureError below if start fails

        recordingTask?.cancel()
        recordingTask = Task { [weak self] in
            guard let self else { return }
            // Create the row and start capture FIRST so recording begins
            // immediately. A failure here means there is nothing to record, so
            // surface it rather than silently losing the session.
            do {
                let row = try await self.services.store.createMeeting(
                    app: label, title: "\(label) meeting", startedAt: Date())
                self.activeMeetingID = row.id
                try self.services.capture.start(meetingId: row.id, targetBundleId: bundleId)
            } catch {
                self.log.error("Recording start failed: \(error.localizedDescription, privacy: .public)")
                self.activeMeetingID = nil
                self.rec = .captureError
                return
            }
            // STT readiness is independent of capture — prepare/start it in the
            // background. If models aren't ready the audio is still recorded and
            // the batch (refine) pass at finalize produces the transcript; we just
            // won't have a live preview. Progress/errors are reflected in
            // `modelState` (same state the Settings download UI binds to) instead
            // of being discarded, but capture is never blocked on the download.
            if !self.services.stt.isReady {
                do {
                    if case .downloading = self.modelState {} else { self.modelState = .downloading(0) }
                    try await self.services.stt.prepare { [weak self] fraction in
                        Task { @MainActor in self?.modelState = .downloading(fraction) }
                    }
                    self.modelState = .ready
                } catch {
                    self.log.error("STT prepare failed: \(error.localizedDescription, privacy: .public)")
                    self.modelState = .failed(error.localizedDescription)
                    self.liveSub = .error
                    return
                }
            } else {
                self.modelState = .ready
            }
            try? await self.services.stt.startLive()
        }
    }

    func pauseOrResume() {
        if rec == .paused { rec = .recording; services.capture.resume() }
        else { rec = .paused; services.capture.pause() }
    }

    func resumeRec() {
        rec = .recording
        liveSub = .recording
        services.capture.resume()
    }

    func stopRec() {
        rec = .processing
        agentOpen = false
        recordingTask?.cancel()
        // Finish live STT (flush its buffered tail) BEFORE stopping capture, so
        // the two don't race and the live fallback transcript is complete. Capture
        // stop then emits `.stopped`, which drives finalizeRecording(...).
        Task { [weak self] in
            guard let self else { return }
            do { try await self.services.stt.finishLive() }
            catch { self.log.error("finishLive failed: \(error.localizedDescription, privacy: .public)") }
            self.services.capture.stop()
        }
    }

    /// Build the final transcript (refine + diarization) and persist, then open Detail.
    private func finalizeRecording(durationSec: Int, audioFar: String?, audioMic: String?) async {
        guard let id = activeMeetingID else { liveLines = []; rec = .idle; return }
        screen = .detail
        selectedMeetingID = id
        detailState = .processing
        finalizeWarning = nil

        var drafts: [TranscriptDraft] = []
        var degraded = false

        // Mic track = "You" (s1). Transcribe and force the speaker key.
        if let micPath = audioMic {
            do {
                let micDrafts = try await withTimeout(120) {
                    try await self.services.stt.transcribeFile(URL(fileURLWithPath: micPath))
                }
                drafts += micDrafts.map { var d = $0; d.speakerKey = "s1"; return d }
            } catch {
                log.error("Mic refine failed: \(error.localizedDescription, privacy: .public)")
                degraded = true
            }
        }

        // Far-end track = other participants. Transcribe the far-end file (NOT the
        // mic file), then relabel by diarization (s2, s3, …). If diarization is
        // unavailable the whole far end collapses to a single "Speaker 2".
        if let farPath = audioFar {
            do {
                let farDrafts = try await withTimeout(120) {
                    try await self.services.stt.transcribeFile(URL(fileURLWithPath: farPath))
                }
                if let segs = try? await withTimeout(120, operation: {
                       try await self.services.diar.diarize(fileURL: URL(fileURLWithPath: farPath))
                   }),
                   !segs.isEmpty {
                    drafts += mergeDiarization(farDrafts, segs)
                } else {
                    drafts += farDrafts.map { var d = $0; d.speakerKey = "s2"; return d }
                }
            } catch {
                log.error("Far-end refine failed: \(error.localizedDescription, privacy: .public)")
                degraded = true
            }
        }

        // Fall back to whatever the live pass produced if no file refined.
        if drafts.isEmpty {
            drafts = liveLines.enumerated().map { i, l in
                TranscriptDraft(tStart: Double(i * secondsPerLine), tEnd: Double(i * secondsPerLine + 11),
                                text: l.text, speakerKey: l.speakerKey)
            }
        }

        // One timeline, ordered by start time, re-id'd sequentially.
        drafts.sort { $0.tStart < $1.tStart }
        let segments = drafts.enumerated().map { i, d in
            SegmentRow(id: "\(id)-seg\(i)", meetingId: id, speakerKey: d.speakerKey,
                       tStart: d.tStart, tEnd: d.tEnd, text: d.text, isFinal: true, isGap: false)
        }

        do {
            try await services.store.replaceSegments(meetingId: id, segments)
            // Auto-title from the first non-empty segment so the library doesn't
            // fill with identical "<App> meeting" rows. Nil means nothing usable
            // to derive from, so the createMeeting-time "<App> meeting" stands.
            if let title = derivedTitle(from: segments) {
                try? await services.store.renameMeeting(id: id, title: title)
            }
            // Persist the speaker roster so Detail shows real, renameable names
            // (including 4th+ speakers) instead of raw "s4" keys.
            for key in Set(segments.map(\.speakerKey)).sorted() {
                try? await services.store.upsertSpeaker(
                    SpeakerRow(meetingId: id, key: key, label: defaultLabel(for: key), displayName: nil))
            }
            try await services.store.finalizeMeeting(id: id, durationSec: durationSec, status: .ready,
                                                     audioFarPath: audioFar, audioMicPath: audioMic)
        } catch {
            log.error("Finalize persist failed: \(error.localizedDescription, privacy: .public)")
            try? await services.store.finalizeMeeting(id: id, durationSec: durationSec, status: .failed,
                                                      audioFarPath: audioFar, audioMicPath: audioMic)
            finalizeWarning = "This recording couldn't be saved completely. Its audio is still on disk."
        }

        if degraded && segments.isEmpty {
            finalizeWarning = "Transcription didn't produce any text for this recording."
        } else if degraded && finalizeWarning == nil {
            // A track timed out or failed but we still saved something (often the
            // live-pass fallback) — be honest about what was kept.
            finalizeWarning = "Transcription timed out; saved the live transcript."
        }

        activeMeetingID = nil
        rec = .idle
        // Don't let the finished meeting's transcript outlive the session in
        // memory — the saved transcript lives in `transcriptLines` / the store.
        liveLines = []
        await loadDetail(id: id)
        detailState = .ready
        await reloadLibrary()
    }

    /// Relabel far-end drafts by speaker using diarization segments. Each draft
    /// takes the diar speaker with the largest temporal overlap with its span;
    /// far-end speakers map to s2, s3, … in order of first appearance (the mic
    /// track's "You" = s1 is assigned by the caller). No overlap → "s2".
    private func mergeDiarization(_ drafts: [TranscriptDraft], _ segs: [DiarSegment]) -> [TranscriptDraft] {
        var labelToKey: [String: String] = [:]
        var next = 2
        func key(for speakerId: String) -> String {
            if let k = labelToKey[speakerId] { return k }
            let k = "s\(next)"; labelToKey[speakerId] = k; next += 1; return k
        }
        return drafts.map { d in
            var best: DiarSegment?
            var bestOverlap = 0.0
            for s in segs {
                let overlap = min(d.tEnd, s.end) - max(d.tStart, s.start)
                if overlap > bestOverlap { bestOverlap = overlap; best = s }
            }
            var copy = d
            if let best, bestOverlap > 0 { copy.speakerKey = key(for: best.speakerId) }
            else { copy.speakerKey = "s2" }
            return copy
        }
    }

    /// Concise auto-title from the first non-empty segment: first ~6 words,
    /// trimmed, trailing punctuation removed. Returns nil when there's no usable
    /// text so the caller keeps the existing "<App> meeting" fallback.
    private func derivedTitle(from segments: [SegmentRow]) -> String? {
        guard let first = segments.first(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        let words = first.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(6)
        let joined = words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:…-"))
        return joined.isEmpty ? nil : joined
    }

    /// System label for a speaker key: s1 → "You", s2 → "Speaker 2", …
    private func defaultLabel(for key: String) -> String {
        if key == "s1" { return "You" }
        if key.hasPrefix("s"), let n = Int(key.dropFirst()) { return "Speaker \(n)" }
        return key
    }

    func openLive() { screen = .live; agentOpen = false }
    func openWindow() { agentOpen = false }

    // MARK: Floating recording bar (HUD)

    /// Show the bar while capturing (or in the Settings position-preview), hide it
    /// otherwise. Called from `rec` / `hudEnabled` / `hudPreview` changes.
    private func syncHUDPresentation() {
        if hudEnabled && (isCapturing || hudPreview) {
            hud.show()
        } else {
            hud.hide()
            if hudExpanded { hudExpanded = false }
        }
    }

    func toggleHUDEnabled() { hudEnabled.toggle() }
    func toggleHUDExpanded() { hudExpanded.toggle() }
    func setHUDPreview(_ on: Bool) { hudPreview = on }

    /// Jump the bar to one of the six preset anchors (Settings quick-jump grid),
    /// persisting the position and repositioning the live panel if it's showing.
    func moveHUD(to anchor: HUDAnchor) {
        hudPosX = anchor.normX
        hudPosY = anchor.normY
        hud.restorePosition()
    }

    /// The preset whose anchor is closest to the current stored position — used to
    /// highlight the active cell in the Settings grid.
    var hudNearestAnchor: HUDAnchor {
        HUDAnchor.allCases.min {
            hypot($0.normX - hudPosX, $0.normY - hudPosY) < hypot($1.normX - hudPosX, $1.normY - hudPosY)
        } ?? .topRight
    }

    func toggleDetection() {
        detection.toggle()
        services.settings.detectionEnabled = detection
        if detection { services.detector.start() } else { services.detector.stop() }
    }

    func simulateDetect() {
        pendingApp = ("Zoom", "us.zoom.xos")
        consentOpen = true
        agentOpen = false
    }

    func simulateCaptureError() {
        rec = .captureError
        screen = .live
        agentOpen = false
    }

    // MARK: Navigation

    func goLibrary() { screen = .library; Task { await reloadLibrary() } }
    func goSettings() { screen = .settings }
    func goAISettings() { screen = .settings; settingsSection = .ai }

    func openMeeting(_ meeting: Meeting) {
        screen = .detail
        selectedMeetingID = meeting.id
        detailState = .ready
        playing = false
        playPos = 0
        player?.stop()
        player = nil   // drop the previous meeting's player; loadDetail reloads it
        finalizeWarning = nil   // warning is scoped to the just-finalized recording
        Task { await loadDetail(id: meeting.id) }
    }

    private func loadDetail(id: String) async {
        selectedMeetingRow = try? await services.store.meeting(id: id)

        let segs = (try? await services.store.segments(meetingId: id)) ?? []
        transcriptLines = segs.map {
            TranscriptLine(speakerKey: $0.speakerKey, time: TimeFmt.mmss(Int($0.tStart)), text: $0.text)
        }
        // Real per-line time ranges (parallel to transcriptLines) drive the
        // playback highlight instead of the fixed 12s stride.
        segmentTimes = segs.map { (start: $0.tStart, end: $0.tEnd) }

        // Load the saved audio for real playback. The two tracks are separate
        // files (mic = "you", far = other participants); AVAudioPlayer plays a
        // single file, so we play whichever exists, preferring the mic track.
        // No file (mocks/preview or older rows) → player stays nil and Detail
        // falls back to the simulated ticker.
        player = nil
        let row = selectedMeetingRow
        if let path = row?.audioMicPath ?? row?.audioFarPath {
            do {
                let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
                p.prepareToPlay()
                player = p
            } catch {
                log.error("Audio load failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // Duration from the player when we have one, else the stored row duration.
        detailDurationSeconds = max(1, player.map { Int($0.duration) } ?? row?.durationSec ?? 1)
        let speakers = (try? await services.store.speakers(meetingId: id)) ?? []
        // Build a FRESH name map per meeting — never carry a rename over from the
        // previously-opened meeting. Seed "You", overlay stored speakers, then
        // fill any remaining transcript keys with default labels (s4+ included).
        var names: [String: String] = ["s1": "You"]
        for s in speakers { names[s.key] = s.displayName ?? s.label }
        for key in Set(transcriptLines.map(\.speakerKey)) where names[key] == nil {
            names[key] = defaultLabel(for: key)
        }
        speakerNames = names

        detailSummaries = (try? await services.store.summaries(meetingId: id)) ?? []
        if let s = detailSummaries.first {
            summaryState = .ready
            streamText = s.contentMD
        } else {
            summaryState = aiConfigured ? .empty : .notConfigured
            streamText = ""
        }
    }

    // MARK: Playback

    func togglePlay() {
        playing.toggle()
        guard let player else { return }   // simulated fallback: flag is enough
        if playing {
            // Restart from the top once we've hit the end (player paused at 0).
            if player.currentTime >= player.duration { player.currentTime = 0 }
            player.play()
        } else {
            player.pause()
        }
    }

    func seek(toLineIndex index: Int) {
        playing = true
        // Seek to the real start time of the tapped line when we have timings,
        // else the simulated stride.
        let target: Double = segmentTimes.indices.contains(index) ? segmentTimes[index].start
                                                                  : Double(index * secondsPerLine)
        playPos = Int(target)
        if let player {
            player.currentTime = target
            player.play()
        }
    }

    // MARK: Detail title

    /// Rename the open meeting. Updates the in-memory row immediately (so the
    /// Detail title reflects the edit without a round-trip), persists via the
    /// store (which keeps FTS in sync), then refreshes the library list.
    func renameMeeting(to title: String) {
        let id = selectedMeetingID
        guard !id.isEmpty else { return }
        selectedMeetingRow?.title = title
        Task {
            try? await services.store.renameMeeting(id: id, title: title)
            await reloadLibrary()
        }
    }

    // MARK: Speakers

    func renameSpeaker(_ key: String, to name: String) {
        speakerNames[key] = name
        let id = selectedMeetingID
        guard !id.isEmpty else { return }
        Task {
            try? await services.store.renameSpeaker(meetingId: id, key: key,
                                                    displayName: name.isEmpty ? nil : name)
            try? await services.store.markSummariesStale(meetingId: id)
            detailSummaries = (try? await services.store.summaries(meetingId: id)) ?? []
            if detailSummaries.contains(where: { $0.isStale }) { summaryState = .ready }
        }
    }

    // MARK: Summary generation (real streaming LLM)

    func generate() {
        guard aiConfigured else { summaryState = .notConfigured; return }
        let id = selectedMeetingID
        guard !id.isEmpty else { return }
        summaryState = .generating
        streamText = ""

        let template = templatesList.first { $0.id == activeTemplateID }
            ?? templatesList.first
        guard let template else { summaryState = .error; return }

        let transcript = transcriptLines
            .map { "\(speakerName($0.speakerKey)): \($0.text)" }
            .joined(separator: "\n")
        let participants = detailSpeakerKeys.map(speakerName).joined(separator: ", ")
        let prompt = TemplateEngine.render(template.prompt, transcript: transcript,
                                           participants: participants,
                                           date: selectedMeeting.date,
                                           duration: selectedMeeting.duration)

        let baseURL = services.settings.aiBaseURL
        let model = services.settings.aiModel
        let key = services.secrets.apiKey()

        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            guard let self else { return }
            do {
                var acc = ""
                for try await chunk in self.services.llm.summarize(prompt: prompt, baseURL: baseURL,
                                                                   apiKey: key, model: model) {
                    acc = chunk
                    self.streamText = chunk
                }
                let summary = SummaryRow(id: id + "-" + String(UUID().uuidString.prefix(8)),
                                         meetingId: id, templateId: template.id,
                                         templateName: template.name, model: model,
                                         contentMD: acc, createdAt: Date(), isStale: false)
                do {
                    try await self.services.store.saveSummary(summary)
                    self.detailSummaries = (try? await self.services.store.summaries(meetingId: id)) ?? []
                    self.summaryState = .ready
                    await self.reloadLibrary()
                } catch {
                    // Persisting failed — keep streamText on screen (so it can be
                    // copied) but report the failure rather than a false "ready".
                    self.log.error("saveSummary failed: \(error.localizedDescription, privacy: .public)")
                    self.summaryState = .error
                }
            } catch is CancellationError {
                // user cancelled
            } catch {
                self.summaryState = .error
            }
        }
    }

    func cancelSummary() { summaryTask?.cancel(); summaryState = streamText.isEmpty ? .empty : .ready }

    // MARK: AI settings

    func toggleMask() { aiMasked.toggle() }

    private func refreshAIConfigured() async {
        let hasURL = !services.settings.aiBaseURL.isEmpty
        let hasModel = !services.settings.aiModel.isEmpty
        let hasKey = (services.secrets.apiKey()?.isEmpty == false)
        aiConfigured = hasURL && hasModel
        aiStatus = aiConfigured ? .connected : .unconfigured
        _ = hasKey
    }

    func testAIConnection() {
        aiStatus = .testing
        let baseURL = services.settings.aiBaseURL
        let model = services.settings.aiModel
        let key = services.secrets.apiKey()
        Task {
            do {
                try await services.llm.testConnection(baseURL: baseURL, apiKey: key, model: model)
                aiStatus = .connected
                aiConfigured = true
            } catch {
                aiStatus = .error
            }
        }
    }

    func loadAIModels() {
        let baseURL = services.settings.aiBaseURL
        let key = services.secrets.apiKey()
        Task {
            do {
                aiModelsAvailable = try await services.llm.listModels(baseURL: baseURL, apiKey: key)
            } catch {
                // Don't leave a silently-empty picker with a stale "connected"
                // status — reflect that the endpoint didn't answer.
                aiModelsAvailable = []
                aiStatus = .error
            }
        }
    }

    // MARK: Templates

    func selectTemplateForEditing(_ id: String) { editTemplateID = id; teUnsaved = false }
    func markTemplateDirty() { teUnsaved = true }
    func saveTemplate() { teUnsaved = false; Task { await reloadTemplates() } }
    func discardTemplate() { teUnsaved = false }
    func newTemplate() { teUnsaved = true }

    // MARK: Settings misc

    func setSettingsSection(_ s: SettingsSection) { settingsSection = s }

    // MARK: Diagnostics self-test
    //
    // One-click on-device validation: run each subsystem and record pass/fail
    // with the exact error. Be honest — a synthetic-audio check that merely RAN
    // without throwing is "passed (ran)", NOT "transcription correct". Mocks
    // never throw, so under `.preview()` every check shows green.

    func runDiagnostics() async {
        guard !diagnosticsRunning else { return }
        diagnosticsRunning = true
        defer { diagnosticsRunning = false }

        // Seed the checklist as pending (⏳) so the rows render immediately and
        // flip to ✅/⚠️ in place as each step completes.
        var checks: [DiagnosticCheck] = [
            DiagnosticCheck(id: "mic",  name: "Microphone permission", passed: nil, detail: "Checking…"),
            DiagnosticCheck(id: "stt",  name: "Transcription model",   passed: nil, detail: "Checking…"),
            DiagnosticCheck(id: "diar", name: "Diarization model",      passed: nil, detail: "Checking…"),
            DiagnosticCheck(id: "sttRun",  name: "Transcription pipeline", passed: nil, detail: "Checking…"),
            DiagnosticCheck(id: "diarRun", name: "Diarization pipeline",   passed: nil, detail: "Checking…"),
            DiagnosticCheck(id: "ai",   name: "AI endpoint",            passed: nil, detail: "Checking…"),
        ]
        diagnostics = checks

        func set(_ id: String, _ passed: Bool, _ detail: String) {
            if let i = checks.firstIndex(where: { $0.id == id }) {
                checks[i].passed = passed
                checks[i].detail = detail
                diagnostics = checks
            }
        }

        // 1. Microphone permission.
        switch services.permissions.micStatus() {
        case .granted:      set("mic", true,  "Granted")
        case .denied:       set("mic", false, "Denied — enable Microphone in System Settings")
        case .undetermined: set("mic", false, "Not yet requested — start a recording to prompt")
        case .unknown:      set("mic", false, "Status unavailable")
        }

        // 2. Model readiness — prepare both engines (no-op progress handler).
        do { try await services.stt.prepare { _ in }; set("stt", true, "Loaded") }
        catch { set("stt", false, error.localizedDescription) }
        do { try await services.diar.prepare(); set("diar", true, "Loaded") }
        catch { set("diar", false, error.localizedDescription) }

        // Build one synthetic 16 kHz mono test clip shared by checks 3 and 4.
        var testURL: URL?
        do { testURL = try Self.makeSyntheticTestClip() }
        catch {
            let reason = "Couldn't create test audio: \(error.localizedDescription)"
            set("sttRun", false, reason)
            set("diarRun", false, reason)
        }

        // 3. STT pipeline self-test — ran without throwing is the bar here.
        if let url = testURL {
            do {
                let drafts = try await services.stt.transcribeFile(url)
                set("sttRun", true, "Passed (ran) · \(drafts.count) segment(s)")
            } catch {
                set("sttRun", false, error.localizedDescription)
            }
            // 4. Diarization self-test — same temp file, ran/threw.
            do {
                let segs = try await services.diar.diarize(fileURL: url)
                set("diarRun", true, "Passed (ran) · \(segs.count) segment(s)")
            } catch {
                set("diarRun", false, error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: url)
        }

        // 5. AI endpoint — only if configured; otherwise honestly skipped.
        let baseURL = services.settings.aiBaseURL
        let model = services.settings.aiModel
        if baseURL.isEmpty || model.isEmpty {
            set("ai", true, "Skipped (not configured)")
        } else {
            do {
                try await services.llm.testConnection(baseURL: baseURL,
                                                      apiKey: services.secrets.apiKey(),
                                                      model: model)
                set("ai", true, "Connected · \(model)")
            } catch {
                set("ai", false, error.localizedDescription)
            }
        }
    }

    /// Synthesize ~0.5 s of low-amplitude noise as a 16 kHz mono buffer and write
    /// it to a temp `.m4a` via `AVAudioFile`. Returns the file URL (caller deletes
    /// it). Used only by the diagnostics self-test; never crashes on the mocks
    /// (they ignore the URL's contents).
    private static func makeSyntheticTestClip() throws -> URL {
        let sampleRate = 16_000.0
        let frameCount = AVAudioFrameCount(sampleRate * 0.5)   // 0.5 s
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "Locus.Diagnostics", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate test buffer."])
        }
        buffer.frameLength = frameCount
        if let ch = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                // Low-amplitude noise + faint tone — enough signal to exercise the
                // pipeline without asserting any particular transcription.
                let tone = 0.02 * sin(2.0 * .pi * 220.0 * Double(i) / sampleRate)
                let noise = Double.random(in: -0.01...0.01)
                ch[i] = Float(tone + noise)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("locus-selftest-\(UUID().uuidString).m4a")
        let outFile = try AVAudioFile(forWriting: url,
                                      settings: [
                                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                                        AVSampleRateKey: sampleRate,
                                        AVNumberOfChannelsKey: 1,
                                      ])
        try outFile.write(from: buffer)
        return url
    }
    func setRetention(_ r: Retention) {
        retention = r
        services.settings.retentionForever = (r == .forever)
    }
    func setConsentMode(app: String, mode: ConsentMode) {
        consentMode[app] = mode
        if let bundle = Self.bundleForApp[app] {
            Task { try? await services.store.setConsentMode(bundleId: bundle, mode: mode) }
        }
    }

    // MARK: Consent prompt

    func toggleAlways() { alwaysRecord.toggle() }
    func consentIgnore() { consentOpen = false; pendingApp = nil }

    func consentRecord() {
        consentOpen = false
        let label = pendingApp?.label ?? "Zoom"
        let bundleId = pendingApp?.bundleId ?? "us.zoom.xos"
        if alwaysRecord {
            consentMode[label] = .always
            Task { try? await services.store.setConsentMode(bundleId: bundleId, mode: .always) }
        }
        startRecording(label: label, bundleId: bundleId == "manual" ? nil : bundleId)
    }

    // MARK: AI status presentation

    func aiStatusStyle(_ theme: Theme) -> (label: String, dot: Color, bg: Color, border: Color, fg: Color) {
        switch aiStatus {
        case .unconfigured:
            return ("Not configured", theme.text3, theme.card2, theme.border2, theme.text2)
        case .testing:
            return ("Testing connection…", theme.warn, theme.recSoft, theme.warn, theme.warn)
        case .connected:
            let model = services.settings.aiModel
            return ("Connected · \(model.isEmpty ? "ready" : model)", theme.ok, theme.okSoft, theme.ok, theme.ok)
        case .error:
            return ("Connection failed — endpoint unreachable", theme.rec, theme.recSoft, theme.rec, theme.rec)
        }
    }

    // MARK: Storage settings

    var storagePath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("Locus").path ?? "~/Library/Application Support/Locus"
    }

    func revealStorage() {
        let url = URL(fileURLWithPath: storagePath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func deleteAllRecordings() {
        Task {
            try? await services.store.deleteAllMeetings()
            await reloadLibrary()
            if screen == .detail { screen = .library }
        }
    }

    // MARK: Permissions

    var permissionItems: [PermissionItem] {
        let mic = services.permissions.micStatus() == .granted
        return [
            PermissionItem(name: "Microphone", detail: "Capture your voice", icon: "🎙", granted: mic),
            // System-audio (process-tap) auth can't be queried — shown as needs-attention.
            PermissionItem(name: "System Audio", detail: "Capture meeting / far-end audio",
                           icon: "🔊", granted: false),
        ]
    }

    func fixPermission(_ name: String) {
        if name == "Microphone" {
            Task {
                let status = await services.permissions.requestMic()
                if status != .granted { services.permissions.openSystemSettings(.microphone) }
            }
        } else {
            services.permissions.openSystemSettings(.screenRecording)
        }
    }

    // MARK: Model readiness

    /// True while a download/load is in flight — used to disable the action button.
    var modelStateIsBusy: Bool {
        if case .downloading = modelState { return true }
        return false
    }

    /// Download + load the on-device model bundle (Parakeet STT, then FluidAudio
    /// diarization). Forwards STT download fraction into `modelState`; diarization
    /// has no progress so it runs after STT under the same `.downloading` state.
    /// `.ready` on success, `.failed(message)` on the first throw. Capture never
    /// waits on this — it's safe to trigger from Settings at any time, and is a
    /// no-op if already downloading or ready.
    func prepareModels() {
        if modelStateIsBusy { return }
        if case .ready = modelState, services.stt.isReady { return }
        modelState = .downloading(0)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.services.stt.prepare { [weak self] fraction in
                    // FluidAudio's progress handler may run off the main thread;
                    // hop to the main actor before mutating @Published state.
                    Task { @MainActor in self?.modelState = .downloading(fraction) }
                }
                // Diarization models have no progress callback; prepare after STT.
                try await self.services.diar.prepare()
                self.modelState = .ready
            } catch {
                self.log.error("Model prepare failed: \(error.localizedDescription, privacy: .public)")
                self.modelState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Transcription models

    let detectionApps: [DetectionApp] = [
        DetectionApp(id: "Zoom", app: .zoom),
        DetectionApp(id: "Slack", app: .slack),
    ]

    var sttModels: [STTModel] {
        func model(_ name: String, _ version: String, _ detail: String) -> STTModel {
            let active = sttVersion == version
            return STTModel(name: name, tag: active ? "Active" : "Ready", detail: detail,
                            status: active ? .active : .ready, progress: 0)
        }
        return [
            model("Parakeet TDT v3", "v3", "Multilingual (25 languages) · on-device, fast"),
            model("Parakeet TDT v2", "v2", "English-only · highest recall"),
        ]
    }

    func selectSTTModel(_ name: String) {
        sttVersion = name.contains("v2") ? "v2" : "v3"
    }

    // MARK: Template editing

    func saveEditedTemplate(name: String, body: String) -> String? {
        let validation = TemplateEngine.validate(name: name, body: body)
        guard validation.isValid else { return validation.reason }
        let id = editTemplateID
        let isBuiltin = templatesList.first { $0.id == id }?.isBuiltin ?? false
        let row = TemplateRow(id: id, name: name, prompt: body, isBuiltin: isBuiltin)
        teUnsaved = false
        Task { try? await services.store.saveTemplate(row); await reloadTemplates() }
        return nil
    }

    func createTemplate() {
        let id = "t" + String(UUID().uuidString.prefix(6))
        let row = TemplateRow(id: id, name: "New template", prompt: "{transcript}", isBuiltin: false)
        teUnsaved = false
        Task {
            try? await services.store.saveTemplate(row)
            await reloadTemplates()
            editTemplateID = id
        }
    }

    func duplicateTemplate(name: String, body: String) {
        let id = "t" + String(UUID().uuidString.prefix(6))
        let row = TemplateRow(id: id, name: name + " copy", prompt: body, isBuiltin: false)
        Task {
            try? await services.store.saveTemplate(row)
            await reloadTemplates()
            editTemplateID = id
        }
    }

    // MARK: Row → UI mapping

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    private static func uiMeeting(_ r: MeetingRow) -> Meeting {
        Meeting(id: r.id, title: r.title, app: MeetingApp(rawValue: r.app) ?? .manual,
                date: dateFmt.string(from: r.startedAt), duration: TimeFmt.mmss(r.durationSec),
                people: r.people, hasSummary: r.hasSummary, body: "", status: r.status)
    }
}
