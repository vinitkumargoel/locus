import SwiftUI

// MARK: - Domain models
//
// Faithful port of the data shapes in the Locus prototype's `renderVals()`.
// Static sample content lives in `SampleData`; mutable runtime state lives in
// `AppState`.

enum MeetingApp: String {
    case zoom = "Zoom"
    case slack = "Slack"
    case manual = "Manual"

    var short: String {
        switch self {
        case .zoom: return "Z"
        case .slack: return "S"
        case .manual: return "M"
        }
    }

    func color(_ theme: Theme) -> Color {
        switch self {
        case .zoom: return Color(hex: 0x2F86FF)
        case .slack: return Color(hex: 0xC0398F)
        case .manual: return theme.text2
        }
    }
}

struct Meeting: Identifiable {
    let id: String
    let title: String
    let app: MeetingApp
    let date: String
    let duration: String
    let people: Int
    let hasSummary: Bool
    /// Hidden searchable keywords (mirrors the prototype's `body`).
    let body: String
    /// Lifecycle state from the store; surfaced as a badge in the library.
    var status: MeetingStatus = .ready

    var sub: String { "\(app.rawValue) · \(date) · \(people) people" }
    var detailMeta: String { "\(app.rawValue) · \(date) · \(duration) · \(people) participants" }
}

/// A line in a saved transcript. `speakerKey` indexes `AppState.speakerNames`.
struct TranscriptLine: Identifiable {
    let id = UUID()
    let speakerKey: String
    let time: String
    let text: String
}

/// A provisional line in the live transcript view.
struct LiveLine: Identifiable {
    let id = UUID()
    let speakerKey: String
    let speaker: String
    let time: String
    let text: String
    /// `false` => still being recognized (dimmed + trailing caret).
    let isFinal: Bool
}

struct SummaryItem: Identifiable {
    let id = UUID()
    let bullet: String
    let text: String
}

struct SummarySection: Identifiable {
    let id = UUID()
    let heading: String
    let items: [SummaryItem]
}

struct Template: Identifiable {
    let id: String
    let name: String
    let builtin: Bool
    var badge: String { builtin ? "Built-in preset" : "Custom" }
}

struct DetectionApp: Identifiable {
    let id: String          // "Zoom" / "Slack"
    let app: MeetingApp
}

enum ModelStatus { case active, ready, downloading }

struct STTModel: Identifiable {
    let id = UUID()
    let name: String
    let tag: String
    let detail: String
    let status: ModelStatus
    let progress: Double    // 0...1, used when downloading
}

/// One of the six snap anchors for the floating recording bar. Drag is
/// free-placement; these are the Settings quick-jump presets. `normX`/`normY` are
/// the bar's normalized top-left position (0 = left/top, 1 = right/bottom),
/// matching `FloatingHUDController`'s placement math.
enum HUDAnchor: String, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft:      return "Top Left"
        case .topCenter:    return "Top Center"
        case .topRight:     return "Top Right"
        case .bottomLeft:   return "Bottom Left"
        case .bottomCenter: return "Bottom Center"
        case .bottomRight:  return "Bottom Right"
        }
    }

    var normX: Double {
        switch self {
        case .topLeft, .bottomLeft:     return 0
        case .topCenter, .bottomCenter: return 0.5
        case .topRight, .bottomRight:   return 1
        }
    }

    var normY: Double {
        switch self {
        case .topLeft, .topCenter, .topRight: return 0
        case .bottomLeft, .bottomCenter, .bottomRight: return 1
        }
    }

    /// 3×2 grid placement for the Settings picker (row 0 = top, row 1 = bottom).
    var gridRow: Int { normY == 0 ? 0 : 1 }
    var gridCol: Int { normX == 0 ? 0 : (normX == 0.5 ? 1 : 2) }
}

struct PermissionItem: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let icon: String
    let granted: Bool
    var status: String { granted ? "Granted" : "Not granted" }
}

// MARK: - Sample content

enum SampleData {
    static let meetings: [Meeting] = [
        Meeting(id: "m1", title: "Q3 Roadmap Review", app: .zoom, date: "Today, 9:30 AM",
                duration: "24:56", people: 5, hasSummary: true,
                body: "roadmap priorities capacity hiring"),
        Meeting(id: "m2", title: "Design Sync — Onboarding", app: .slack, date: "Yesterday, 2:15 PM",
                duration: "41:08", people: 3, hasSummary: true,
                body: "onboarding flow consent prompt empty states"),
        Meeting(id: "m3", title: "1:1 with Priya", app: .zoom, date: "Mon, 11:00 AM",
                duration: "18:22", people: 2, hasSummary: false,
                body: "career growth feedback goals"),
        Meeting(id: "m4", title: "Customer Call — Northwind", app: .zoom, date: "Fri, 4:30 PM",
                duration: "52:40", people: 6, hasSummary: true,
                body: "pricing security procurement timeline"),
        Meeting(id: "m5", title: "Standup", app: .slack, date: "Fri, 9:05 AM",
                duration: "08:14", people: 7, hasSummary: false,
                body: "blockers shipped today demo"),
    ]

    static func meeting(id: String) -> Meeting {
        meetings.first { $0.id == id } ?? meetings[0]
    }

    static let libraryFooter = "\(meetings.count) recordings · 1.84 GB on disk"

    /// Saved-transcript lines for the detail view.
    static let transcript: [TranscriptLine] = [
        TranscriptLine(speakerKey: "s1", time: "00:04",
                       text: "Alright, thanks everyone for joining. Let's start with where we landed on the Q3 priorities."),
        TranscriptLine(speakerKey: "s2", time: "00:19",
                       text: "Sounds good. So the headline is we're committing to the onboarding rework and the offline mode — those two are locked."),
        TranscriptLine(speakerKey: "s1", time: "00:38",
                       text: "And capacity? Last time we were worried about the mobile team being stretched."),
        TranscriptLine(speakerKey: "s3", time: "00:52",
                       text: "Mobile has room now that the billing migration shipped. I'd say we're comfortable taking on onboarding."),
        TranscriptLine(speakerKey: "s2", time: "01:14",
                       text: "Great. The open question is whether summaries make it in this quarter or slip to Q4."),
        TranscriptLine(speakerKey: "s1", time: "01:33",
                       text: "Let's mark that as a decision for next week once we hear back from the model team."),
    ]

    /// Duration of the detail recording, in seconds (24:56 = 1496).
    static let detailDurationSeconds = 1496

    /// Provisional live-transcript lines.
    static let liveLines: [LiveLine] = [
        LiveLine(speakerKey: "s1", speaker: "You", time: "00:04",
                 text: "Alright, thanks everyone for joining. Let's start with where we landed on the Q3 priorities.", isFinal: true),
        LiveLine(speakerKey: "s2", speaker: "Speaker 2", time: "00:19",
                 text: "Sounds good. The headline is we're committing to the onboarding rework and offline mode.", isFinal: true),
        LiveLine(speakerKey: "s1", speaker: "You", time: "00:38",
                 text: "And capacity? Last time we were worried about the mobile team being stretched.", isFinal: true),
        LiveLine(speakerKey: "s3", speaker: "Speaker 3", time: "00:52",
                 text: "Mobile has room now that the billing migration shipped — comfortable taking on onboarding", isFinal: false),
    ]

    static let summarySections: [SummarySection] = [
        SummarySection(heading: "Decisions", items: [
            SummaryItem(bullet: "•", text: "Onboarding rework and offline mode are committed for Q3."),
            SummaryItem(bullet: "•", text: "Summaries feature deferred pending the model team's response."),
        ]),
        SummarySection(heading: "Action items", items: [
            SummaryItem(bullet: "☐", text: "Priya to confirm mobile capacity by Friday."),
            SummaryItem(bullet: "☐", text: "Follow up with model team re: summary timeline next week."),
        ]),
        SummarySection(heading: "Notes", items: [
            SummaryItem(bullet: "•", text: "Billing migration shipped, freeing mobile bandwidth."),
        ]),
    ]

    static let summaryMeta = "Action Items & Decisions · llama-3.1-8b"

    /// Text streamed out during a simulated summary generation.
    static let summaryStreamText = "The team confirmed Q3 priorities: the onboarding rework and offline mode are committed. Mobile capacity opened up after the billing migration shipped. The summaries feature is pending a decision from the model team next week…"

    static let templates: [Template] = [
        Template(id: "t1", name: "Long Summary", builtin: true),
        Template(id: "t2", name: "One-on-One", builtin: true),
        Template(id: "t3", name: "Action Items & Decisions", builtin: true),
        Template(id: "t4", name: "Quick Notes / Standup", builtin: true),
        Template(id: "t5", name: "Customer Call (custom)", builtin: false),
    ]

    static let templateBodies: [String: String] = [
        "t1": "Summarize the following meeting in detail.\n\nParticipants: {participants}\nDate: {date} ({duration})\n\nTranscript:\n{transcript}\n\nProduce an overview, key topics, decisions, and action items.",
        "t2": "This is a 1:1 between {participants} on {date}.\n\n{transcript}\n\nCapture: themes discussed, feedback given, growth areas, and follow-ups.",
        "t3": "From the transcript below, extract ONLY:\n1. Decisions made\n2. Action items (with owner if stated)\n\n{transcript}",
        "t4": "Give a 5-bullet standup-style recap of {transcript}. Keep it under 80 words.",
        "t5": "Summarize this customer call for the account team.\n\n{transcript}\n\nInclude: requirements, objections, next steps, deal risk.",
    ]

    static func templateBody(_ id: String) -> String { templateBodies[id] ?? "" }

    static let templateVariables = ["{transcript}", "{participants}", "{date}", "{duration}"]

    static let detectionApps: [DetectionApp] = [
        DetectionApp(id: "Zoom", app: .zoom),
        DetectionApp(id: "Slack", app: .slack),
    ]

    static let sttModels: [STTModel] = [
        STTModel(name: "Whisper Small", tag: "Active",
                 detail: "466 MB · fast, good for most calls", status: .active, progress: 0),
        STTModel(name: "Whisper Medium", tag: "Ready",
                 detail: "1.5 GB · slower, higher accuracy", status: .ready, progress: 0),
        STTModel(name: "Whisper Large v3", tag: "Downloading",
                 detail: "2.9 GB · best accuracy, needs more memory", status: .downloading, progress: 0.62),
    ]

    static let aiModels = ["llama-3.1-8b-instruct", "qwen2.5-7b", "mistral-7b"]

    static let permissions: [PermissionItem] = [
        PermissionItem(name: "Microphone", detail: "Capture your voice", icon: "🎙", granted: true),
        PermissionItem(name: "System Audio", detail: "Capture meeting / far-end audio", icon: "🔊", granted: false),
    ]

    static let storagePath = "~/Library/Application Support/Locus"
    static let aiBaseURL = "http://localhost:11434/v1"
    static let aiKeyPlain = "sk-local-9f2a8c4471be"
    static let aiKeyMasked = "••••••••••••sk"
}

// MARK: - Time helpers

enum TimeFmt {
    /// Seconds -> "m:ss".
    static func mmss(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return "\(m):" + String(format: "%02d", s)
    }
}
