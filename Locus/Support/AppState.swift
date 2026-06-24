import SwiftUI
import Combine
import AVFoundation
import AppKit

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

enum ConsentMode: String, Codable { case ask, always, never }

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
    @Published var rec: RecState = .idle
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

    // Settings
    @Published var settingsSection: SettingsSection = .general
    @Published var templatesList: [TemplateRow] = []
    @Published var activeTemplateID = "t3"
    @Published var editTemplateID = "t1"
    @Published var teUnsaved = false
    @Published var retention: Retention = .forever
    @Published var consentMode: [String: ConsentMode] = ["Zoom": .ask, "Slack": .ask]

    let retentionDays = 30
    /// Stable, ordered speaker roster — single source of truth for chips + colors.
    let speakerKeys = ["s1", "s2", "s3"]
    /// Approximate seconds-per-line stride for the simulated playback highlight.
    private let secondsPerLine = 12

    private var cancellables = Set<AnyCancellable>()
    private var ticker: AnyCancellable?
    private var searchTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var activeMeetingID: String?

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

        // 1 Hz clock for elapsed (recording) + playback position (detail).
        ticker = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }

        subscribeCapture()
        subscribeLiveTranscript()
        subscribeDetection()

        Task { await bootstrap() }
    }

    deinit { ticker?.cancel() }

    private func bootstrap() async {
        try? await services.store.bootstrap()
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
        // Crash recovery: finalize anything left mid-flight.
        if let stuck = try? await services.store.recoverableMeetings() {
            for m in stuck {
                try? await services.store.finalizeMeeting(id: m.id, durationSec: m.durationSec,
                                                          status: .recovered,
                                                          audioFarPath: m.audioFarPath,
                                                          audioMicPath: m.audioMicPath)
            }
            if !stuck.isEmpty { await reloadLibrary() }
        }
    }

    private func tick() {
        if rec == .recording { elapsed += 1 }
        if playing { playPos = min(playPos + 1, max(1, detailDurationSeconds)) }
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

    func speakerName(_ key: String) -> String { speakerNames[key] ?? key }

    var currentLineIndex: Int {
        guard !transcriptLines.isEmpty else { return 0 }
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
        rec = .recording
        Task {
            let row = try? await services.store.createMeeting(app: label, title: "\(label) meeting",
                                                              startedAt: Date())
            activeMeetingID = row?.id
            if !services.stt.isReady { try? await services.stt.prepare { _ in } }
            try? await services.stt.startLive()
            do {
                try services.capture.start(meetingId: row?.id ?? "live", targetBundleId: bundleId)
            } catch {
                rec = .captureError
            }
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
        services.capture.stop()           // → .stopped event → finalizeRecording(...)
        Task { try? await services.stt.finishLive() }
    }

    /// Build the final transcript (refine + diarization) and persist, then open Detail.
    private func finalizeRecording(durationSec: Int, audioFar: String?, audioMic: String?) async {
        guard let id = activeMeetingID else { rec = .idle; return }
        screen = .detail
        selectedMeetingID = id
        detailState = .processing

        var drafts: [TranscriptDraft] = []
        if let micPath = audioMic {
            let url = URL(fileURLWithPath: micPath)
            drafts = (try? await services.stt.transcribeFile(url)) ?? []
            // Merge diarization speaker labels into far-end drafts.
            if let far = audioFar,
               let segs = try? await services.diar.diarize(fileURL: URL(fileURLWithPath: far)) {
                drafts = mergeDiarization(drafts, segs)
            }
        }
        if drafts.isEmpty {
            // Fall back to whatever the live pass produced.
            drafts = liveLines.enumerated().map { i, l in
                TranscriptDraft(tStart: Double(i * secondsPerLine), tEnd: Double(i * secondsPerLine + 11),
                                text: l.text, speakerKey: l.speakerKey)
            }
        }

        let segments = drafts.enumerated().map { i, d in
            SegmentRow(id: "\(id)-seg\(i)", meetingId: id, speakerKey: d.speakerKey,
                       tStart: d.tStart, tEnd: d.tEnd, text: d.text, isFinal: true, isGap: false)
        }
        try? await services.store.replaceSegments(meetingId: id, segments)
        try? await services.store.finalizeMeeting(id: id, durationSec: durationSec, status: .ready,
                                                  audioFarPath: audioFar, audioMicPath: audioMic)
        activeMeetingID = nil
        rec = .idle
        await loadDetail(id: id)
        detailState = .ready
        await reloadLibrary()
    }

    private func mergeDiarization(_ drafts: [TranscriptDraft], _ segs: [DiarSegment]) -> [TranscriptDraft] {
        // Assign each draft the diarization speaker whose segment overlaps its midpoint.
        // Far-end speakers map to s2, s3, … in order of first appearance ("You" stays s1 = mic).
        var labelToKey: [String: String] = [:]
        var next = 2
        return drafts.map { d in
            let mid = (d.tStart + d.tEnd) / 2
            guard let seg = segs.first(where: { $0.start <= mid && mid <= $0.end }) else { return d }
            let key: String
            if let k = labelToKey[seg.speakerId] { key = k }
            else { key = "s\(next)"; labelToKey[seg.speakerId] = key; next += 1 }
            var copy = d; copy.speakerKey = key; return copy
        }
    }

    func openLive() { screen = .live; agentOpen = false }
    func openWindow() { agentOpen = false }

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
        Task { await loadDetail(id: meeting.id) }
    }

    private func loadDetail(id: String) async {
        selectedMeetingRow = try? await services.store.meeting(id: id)
        detailDurationSeconds = max(1, selectedMeetingRow?.durationSec ?? 1)

        let segs = (try? await services.store.segments(meetingId: id)) ?? []
        transcriptLines = segs.map {
            TranscriptLine(speakerKey: $0.speakerKey, time: TimeFmt.mmss(Int($0.tStart)), text: $0.text)
        }
        let speakers = (try? await services.store.speakers(meetingId: id)) ?? []
        var names = speakerNames
        for s in speakers { names[s.key] = s.displayName ?? s.label }
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

    func togglePlay() { playing.toggle() }

    func seek(toLineIndex index: Int) {
        playing = true
        playPos = index * secondsPerLine
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
        let participants = speakerKeys.map(speakerName).joined(separator: ", ")
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
                try? await self.services.store.saveSummary(summary)
                self.detailSummaries = (try? await self.services.store.summaries(meetingId: id)) ?? []
                self.summaryState = .ready
                await self.reloadLibrary()
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
            aiModelsAvailable = (try? await services.llm.listModels(baseURL: baseURL, apiKey: key)) ?? []
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
                people: r.people, hasSummary: r.hasSummary, body: "")
    }
}
