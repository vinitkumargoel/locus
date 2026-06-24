import Foundation
import Combine
import AVFoundation

// MARK: - Service contracts
//
// These protocols are the seam between the SwiftUI front-end (AppState + views)
// and the real engine. Every action on AppState routes to one of these
// services; every screen reads data AppState fetched from them. Concrete `live`
// implementations live in their own files under Services/; `Mock*` impls (below,
// backed by SampleData) keep the whole app buildable and demoable at every step.
//
// Storage-agnostic value types ("rows") cross this boundary — never GRDB records
// or CoreML types — so the UI layer has zero knowledge of the backend.

// MARK: Domain rows

enum MeetingStatus: String, Codable { case recording, processing, ready, recovered, failed }

struct MeetingRow: Identifiable, Equatable {
    let id: String
    var title: String
    var app: String              // MeetingApp rawValue: "Zoom" / "Slack" / "Manual"
    var startedAt: Date
    var durationSec: Int
    var people: Int
    var hasSummary: Bool
    var status: MeetingStatus
    var audioFarPath: String?
    var audioMicPath: String?
}

struct SpeakerRow: Identifiable, Equatable {
    var id: String { meetingId + ":" + key }
    let meetingId: String
    let key: String              // "s1" = You, "s2"/"s3"… = Speaker N
    var label: String            // system label ("You" / "Speaker 2")
    var displayName: String?     // user-assigned
}

struct SegmentRow: Identifiable, Equatable {
    let id: String
    let meetingId: String
    var speakerKey: String
    var tStart: Double
    var tEnd: Double
    var text: String
    var isFinal: Bool
    var isGap: Bool
}

struct SummaryRow: Identifiable, Equatable {
    let id: String
    let meetingId: String
    let templateId: String
    let templateName: String     // snapshotted so deleting a template doesn't orphan it
    let model: String
    var contentMD: String
    let createdAt: Date
    var isStale: Bool
}

struct TemplateRow: Identifiable, Equatable {
    let id: String
    var name: String
    var prompt: String
    var isBuiltin: Bool
}

// MARK: Persistence

protocol MeetingStore: AnyObject {
    func bootstrap() async throws

    func allMeetings() async throws -> [MeetingRow]
    func searchMeetings(_ query: String) async throws -> [MeetingRow]
    func meeting(id: String) async throws -> MeetingRow?
    func segments(meetingId: String) async throws -> [SegmentRow]
    func speakers(meetingId: String) async throws -> [SpeakerRow]
    func summaries(meetingId: String) async throws -> [SummaryRow]

    @discardableResult
    func createMeeting(app: String, title: String, startedAt: Date) async throws -> MeetingRow
    func appendSegment(_ segment: SegmentRow) async throws
    func replaceSegments(meetingId: String, _ segments: [SegmentRow]) async throws
    func upsertSpeaker(_ speaker: SpeakerRow) async throws
    func finalizeMeeting(id: String, durationSec: Int, status: MeetingStatus,
                         audioFarPath: String?, audioMicPath: String?) async throws
    func renameMeeting(id: String, title: String) async throws
    func renameSpeaker(meetingId: String, key: String, displayName: String?) async throws
    func updateSegmentText(id: String, text: String) async throws
    func markSummariesStale(meetingId: String) async throws
    func saveSummary(_ summary: SummaryRow) async throws
    func deleteMeeting(id: String) async throws
    func deleteAllMeetings() async throws

    func templates() async throws -> [TemplateRow]
    func saveTemplate(_ template: TemplateRow) async throws
    func deleteTemplate(id: String) async throws

    func consentMode(bundleId: String) async throws -> ConsentMode?
    func setConsentMode(bundleId: String, mode: ConsentMode) async throws

    /// Rows left in `.recording`/`.processing` at launch — crash-recovery candidates.
    func recoverableMeetings() async throws -> [MeetingRow]
    func diskUsageBytes() async throws -> Int64
}

// MARK: Capture

enum AudioTrackTag { case you, farEnd }

enum CaptureEvent {
    case started
    case level(you: Float, farEnd: Float)
    case farEndSilent
    case deviceChanged
    case diskFull
    case error(String)
    /// Terminal: capture stopped and audio files are flushed.
    case stopped(audioFarPath: String?, audioMicPath: String?, durationSec: Int)
}

protocol CaptureService: AnyObject {
    var events: AnyPublisher<CaptureEvent, Never> { get }
    /// 16 kHz mono Float buffers tagged by track, for the live STT pipeline.
    var audio: AnyPublisher<(AVAudioPCMBuffer, AudioTrackTag), Never> { get }
    var isRunning: Bool { get }

    /// Begin dual-track capture for `meetingId`, optionally tapping `targetBundleId`'s process.
    func start(meetingId: String, targetBundleId: String?) throws
    func pause()
    func resume()
    func stop()
}

// MARK: Transcription (STT)

struct LiveUpdate: Equatable {
    let track: AudioTrackTag
    let text: String
    let isFinal: Bool
    let timeSec: Double
}

/// One utterance produced by a batch (refine) pass over a saved file.
struct TranscriptDraft: Equatable {
    var tStart: Double
    var tEnd: Double
    var text: String
    /// Speaker key once diarization is merged in (defaults to far-end "s2").
    var speakerKey: String
}

protocol STTEngine: AnyObject {
    var isReady: Bool { get }
    var liveUpdates: AnyPublisher<LiveUpdate, Never> { get }

    /// Download + load the active model. Reports 0...1 progress.
    func prepare(progress: @escaping (Double) -> Void) async throws

    func startLive() async throws
    func feed(_ buffer: AVAudioPCMBuffer, track: AudioTrackTag) async
    func finishLive() async throws

    /// Refine pass: full-file transcription with word timings.
    func transcribeFile(_ url: URL) async throws -> [TranscriptDraft]
}

// MARK: Diarization

struct DiarSegment: Equatable {
    let speakerId: String        // engine label, e.g. "Speaker 1"
    let start: Double
    let end: Double
}

protocol DiarizationService: AnyObject {
    func prepare() async throws
    func diarize(fileURL: URL) async throws -> [DiarSegment]
}

// MARK: Summarization (LLM)

enum LLMErrorKind: Equatable {
    case badURL, unreachable, authFailed, modelNotFound, timeout, contextOverflow, server, unknown
    /// Transient errors are safe to auto-retry; permanent ones need a settings fix.
    var isTransient: Bool {
        switch self {
        case .unreachable, .timeout, .server: return true
        case .badURL, .authFailed, .modelNotFound, .contextOverflow, .unknown: return false
        }
    }
}

struct LLMError: Error, Equatable {
    let kind: LLMErrorKind
    let message: String
}

protocol SummarizationService: AnyObject {
    func listModels(baseURL: String, apiKey: String?) async throws -> [String]
    func testConnection(baseURL: String, apiKey: String?, model: String) async throws
    /// Streams the summary text incrementally. Applies map-reduce internally for long input.
    func summarize(prompt: String, baseURL: String, apiKey: String?, model: String)
        -> AsyncThrowingStream<String, Error>
}

// MARK: Templates

struct TemplateValidation: Equatable {
    var isValid: Bool
    var reason: String?
}

enum TemplateEngine {
    static let variables = ["{transcript}", "{participants}", "{date}", "{duration}"]

    static func render(_ body: String, transcript: String, participants: String,
                       date: String, duration: String) -> String {
        body
            .replacingOccurrences(of: "{transcript}", with: transcript)
            .replacingOccurrences(of: "{participants}", with: participants)
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{duration}", with: duration)
    }

    static func validate(name: String, body: String) -> TemplateValidation {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            return .init(isValid: false, reason: "Name can't be empty.")
        }
        if !body.contains("{transcript}") {
            return .init(isValid: false, reason: "Template must include the {transcript} variable.")
        }
        // Reject unknown {tokens}.
        let known = Set(variables)
        var search = body[...]
        while let open = search.firstIndex(of: "{"), let close = search[open...].firstIndex(of: "}") {
            let token = String(search[open...close])
            if !known.contains(token) {
                return .init(isValid: false, reason: "Unknown variable \(token).")
            }
            search = search[search.index(after: close)...]
        }
        return .init(isValid: true, reason: nil)
    }
}

// MARK: Permissions

enum PermState: Equatable { case granted, denied, undetermined, unknown }

enum SettingsPane { case microphone, screenRecording }

protocol PermissionsService: AnyObject {
    func micStatus() -> PermState
    func requestMic() async -> PermState
    /// System-audio (process-tap) auth can't be queried — always `.unknown`.
    func systemAudioStatus() -> PermState
    func openSystemSettings(_ pane: SettingsPane)
}

// MARK: Settings + secrets

protocol SettingsStore: AnyObject {
    var aiBaseURL: String { get set }
    var aiModel: String { get set }
    var sttModelVersion: String { get set }   // "v2" | "v3"
    var detectionEnabled: Bool { get set }
    var retentionForever: Bool { get set }
    var retentionDays: Int { get set }
    var disclaimerAccepted: Bool { get set }
    var darkAppearance: Bool { get set }
    /// Floating recording bar: whether it shows while recording, and its
    /// normalized on-screen position (0…1 top-left within the placeable area).
    var hudEnabled: Bool { get set }
    var hudPosX: Double { get set }
    var hudPosY: Double { get set }
}

protocol SecretStore: AnyObject {
    func apiKey() -> String?
    func setApiKey(_ value: String?)
}

// MARK: Detection

struct DetectedMeeting: Equatable {
    let app: String              // "Zoom" / "Slack"
    let bundleId: String
    let pid: pid_t
}

protocol MeetingDetector: AnyObject {
    var detections: AnyPublisher<DetectedMeeting, Never> { get }
    func start()
    func stop()
}

// MARK: - Service container
//
// One value injected into AppState. `.preview()` wires the mocks below (used by
// SwiftUI previews and as the always-buildable default); `.live()` wires the
// real engine and is filled in as each concrete service lands.

struct Services {
    let store: MeetingStore
    let capture: CaptureService
    let stt: STTEngine
    let diar: DiarizationService
    let llm: SummarizationService
    let permissions: PermissionsService
    let settings: SettingsStore
    let secrets: SecretStore
    let detector: MeetingDetector

    static func preview() -> Services {
        Services(
            store: MockMeetingStore(),
            capture: MockCaptureService(),
            stt: MockSTTEngine(),
            diar: MockDiarizationService(),
            llm: MockSummarizationService(),
            permissions: MockPermissionsService(),
            settings: MockSettingsStore(),
            secrets: MockSecretStore(),
            detector: MockMeetingDetector()
        )
    }
}
