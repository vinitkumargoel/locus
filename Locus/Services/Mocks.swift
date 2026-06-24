import Foundation
@preconcurrency import Combine
import AVFoundation

// MARK: - Mock services
//
// Backed by SampleData. These preserve the prototype's demo behavior so the app
// runs end-to-end with zero backend, and they document the expected semantics of
// each protocol for the real implementations.

private func parseDuration(_ s: String) -> Int {
    let parts = s.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return 0 }
    return parts[0] * 60 + parts[1]
}

private func sampleMeetingRows() -> [MeetingRow] {
    SampleData.meetings.map { m in
        MeetingRow(id: m.id, title: m.title, app: m.app.rawValue, startedAt: Date(),
                   durationSec: parseDuration(m.duration), people: m.people,
                   hasSummary: m.hasSummary, status: .ready,
                   audioFarPath: nil, audioMicPath: nil)
    }
}

final class MockMeetingStore: MeetingStore {
    private var meetings = sampleMeetingRows()
    private var summaryStore: [String: [SummaryRow]] = [:]
    private var renamed: [String: [String: String]] = [:]   // meetingId -> key -> displayName
    private var templateStore: [TemplateRow] = SampleData.templates.map {
        TemplateRow(id: $0.id, name: $0.name, prompt: SampleData.templateBody($0.id), isBuiltin: $0.builtin)
    }
    private var consent: [String: ConsentMode] = ["us.zoom.xos": .ask, "com.tinyspeck.slackmacgap": .ask]

    func bootstrap() async throws {}

    func allMeetings() async throws -> [MeetingRow] { meetings }

    func searchMeetings(_ query: String) async throws -> [MeetingRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return meetings }
        return meetings.filter { row in
            row.title.lowercased().contains(q)
                || (SampleData.meetings.first { $0.id == row.id }?.body.contains(q) ?? false)
        }
    }

    func meeting(id: String) async throws -> MeetingRow? { meetings.first { $0.id == id } }

    func segments(meetingId: String) async throws -> [SegmentRow] {
        SampleData.transcript.enumerated().map { i, line in
            SegmentRow(id: "\(meetingId)-seg\(i)", meetingId: meetingId, speakerKey: line.speakerKey,
                       tStart: Double(i * 12), tEnd: Double(i * 12 + 11), text: line.text,
                       isFinal: true, isGap: false)
        }
    }

    func speakers(meetingId: String) async throws -> [SpeakerRow] {
        let names = renamed[meetingId] ?? [:]
        return [("s1", "You"), ("s2", "Speaker 2"), ("s3", "Speaker 3")].map { key, label in
            SpeakerRow(meetingId: meetingId, key: key, label: label, displayName: names[key])
        }
    }

    func summaries(meetingId: String) async throws -> [SummaryRow] {
        if let s = summaryStore[meetingId] { return s }
        guard let m = meetings.first(where: { $0.id == meetingId }), m.hasSummary else { return [] }
        return [SummaryRow(id: meetingId + "-sum", meetingId: meetingId, templateId: "t3",
                           templateName: "Action Items & Decisions", model: "llama-3.1-8b",
                           contentMD: SampleData.summaryStreamText, createdAt: Date(), isStale: false)]
    }

    func createMeeting(app: String, title: String, startedAt: Date) async throws -> MeetingRow {
        let row = MeetingRow(id: "m\(meetings.count + 1)-\(Int(startedAt.timeIntervalSince1970))",
                             title: title, app: app, startedAt: startedAt, durationSec: 0,
                             people: 0, hasSummary: false, status: .recording,
                             audioFarPath: nil, audioMicPath: nil)
        meetings.insert(row, at: 0)
        return row
    }

    func appendSegment(_ segment: SegmentRow) async throws {}
    func replaceSegments(meetingId: String, _ segments: [SegmentRow]) async throws {}
    func upsertSpeaker(_ speaker: SpeakerRow) async throws {}

    func finalizeMeeting(id: String, durationSec: Int, status: MeetingStatus,
                         audioFarPath: String?, audioMicPath: String?) async throws {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[i].durationSec = durationSec
        meetings[i].status = status
        meetings[i].audioFarPath = audioFarPath
        meetings[i].audioMicPath = audioMicPath
    }

    func renameMeeting(id: String, title: String) async throws {
        if let i = meetings.firstIndex(where: { $0.id == id }) { meetings[i].title = title }
    }

    func renameSpeaker(meetingId: String, key: String, displayName: String?) async throws {
        renamed[meetingId, default: [:]][key] = displayName
    }

    func updateSegmentText(id: String, text: String) async throws {}
    func markSummariesStale(meetingId: String) async throws {
        summaryStore[meetingId] = (summaryStore[meetingId] ?? []).map {
            var s = $0; s.isStale = true; return s
        }
    }

    func saveSummary(_ summary: SummaryRow) async throws {
        summaryStore[summary.meetingId, default: []].append(summary)
        if let i = meetings.firstIndex(where: { $0.id == summary.meetingId }) { meetings[i].hasSummary = true }
    }

    func deleteMeeting(id: String) async throws { meetings.removeAll { $0.id == id } }
    func deleteAllMeetings() async throws { meetings.removeAll() }

    func templates() async throws -> [TemplateRow] { templateStore }
    func saveTemplate(_ template: TemplateRow) async throws {
        if let i = templateStore.firstIndex(where: { $0.id == template.id }) { templateStore[i] = template }
        else { templateStore.append(template) }
    }
    func deleteTemplate(id: String) async throws { templateStore.removeAll { $0.id == id } }

    func consentMode(bundleId: String) async throws -> ConsentMode? { consent[bundleId] }
    func setConsentMode(bundleId: String, mode: ConsentMode) async throws { consent[bundleId] = mode }

    func recoverableMeetings() async throws -> [MeetingRow] { [] }
    func diskUsageBytes() async throws -> Int64 { 1_975_684_300 }
}

final class MockCaptureService: CaptureService {
    private let eventsSubject = PassthroughSubject<CaptureEvent, Never>()
    private let audioSubject = PassthroughSubject<(AVAudioPCMBuffer, AudioTrackTag), Never>()
    var events: AnyPublisher<CaptureEvent, Never> { eventsSubject.eraseToAnyPublisher() }
    var audio: AnyPublisher<(AVAudioPCMBuffer, AudioTrackTag), Never> { audioSubject.eraseToAnyPublisher() }
    private(set) var isRunning = false
    private var timer: Timer?
    private var elapsed = 0

    func start(meetingId: String, targetBundleId: String?) throws {
        isRunning = true
        elapsed = 0
        eventsSubject.send(.started)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed += 1
            self.eventsSubject.send(.level(you: Float.random(in: 0.1...0.9),
                                           farEnd: Float.random(in: 0.1...0.9)))
        }
    }
    func pause() { timer?.invalidate() }
    func resume() { if isRunning { try? start(meetingId: "", targetBundleId: nil) } }
    func stop() {
        timer?.invalidate(); timer = nil; isRunning = false
        eventsSubject.send(.stopped(audioFarPath: nil, audioMicPath: nil, durationSec: elapsed))
    }
}

final class MockSTTEngine: STTEngine {
    private let updates = PassthroughSubject<LiveUpdate, Never>()
    var liveUpdates: AnyPublisher<LiveUpdate, Never> { updates.eraseToAnyPublisher() }
    private(set) var isReady = false

    func prepare(progress: @escaping (Double) -> Void) async throws { progress(1); isReady = true }
    func startLive() async throws {
        let subject = updates
        for (i, line) in SampleData.liveLines.enumerated() {
            let update = LiveUpdate(track: line.speakerKey == "s1" ? .you : .farEnd,
                                    text: line.text, isFinal: line.isFinal, timeSec: Double(i * 15))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i) * 2) {
                subject.send(update)
            }
        }
    }
    func feed(_ buffer: AVAudioPCMBuffer, track: AudioTrackTag) async {}
    func finishLive() async throws {}
    func transcribeFile(_ url: URL) async throws -> [TranscriptDraft] {
        SampleData.transcript.enumerated().map { i, line in
            TranscriptDraft(tStart: Double(i * 12), tEnd: Double(i * 12 + 11),
                            text: line.text, speakerKey: line.speakerKey)
        }
    }
}

final class MockDiarizationService: DiarizationService {
    func prepare() async throws {}
    func diarize(fileURL: URL) async throws -> [DiarSegment] {
        [DiarSegment(speakerId: "Speaker 1", start: 0, end: 30),
         DiarSegment(speakerId: "Speaker 2", start: 30, end: 60)]
    }
}

final class MockSummarizationService: SummarizationService {
    func listModels(baseURL: String, apiKey: String?) async throws -> [String] { SampleData.aiModels }
    func testConnection(baseURL: String, apiKey: String?, model: String) async throws {}
    func summarize(prompt: String, baseURL: String, apiKey: String?, model: String)
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let full = SampleData.summaryStreamText
            Task {
                var i = 0
                while i < full.count {
                    i = min(i + 4, full.count)
                    continuation.yield(String(full.prefix(i)))
                    try? await Task.sleep(nanoseconds: 45_000_000)
                }
                continuation.finish()
            }
        }
    }
}

final class MockPermissionsService: PermissionsService {
    func micStatus() -> PermState { .granted }
    func requestMic() async -> PermState { .granted }
    func systemAudioStatus() -> PermState { .unknown }
    func openSystemSettings(_ pane: SettingsPane) {}
}

final class MockSettingsStore: SettingsStore {
    var aiBaseURL = SampleData.aiBaseURL
    var aiModel = SampleData.aiModels.first ?? ""
    var sttModelVersion = "v3"
    var detectionEnabled = true
    var retentionForever = true
    var retentionDays = 30
    var disclaimerAccepted = true
    var darkAppearance = false
    var hudEnabled = true
    var hudPosX = 1.0
    var hudPosY = 0.0
}

final class MockSecretStore: SecretStore {
    private var key: String? = SampleData.aiKeyPlain
    func apiKey() -> String? { key }
    func setApiKey(_ value: String?) { key = value }
}

final class MockMeetingDetector: MeetingDetector {
    private let subject = PassthroughSubject<DetectedMeeting, Never>()
    var detections: AnyPublisher<DetectedMeeting, Never> { subject.eraseToAnyPublisher() }
    func start() {}
    func stop() {}
    /// Test hook used by the menu-bar "Simulate Zoom detected" affordance.
    func emit(_ meeting: DetectedMeeting) { subject.send(meeting) }
}
