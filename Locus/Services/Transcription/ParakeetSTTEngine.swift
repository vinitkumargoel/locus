import Foundation
import Combine
import AVFoundation
import FluidAudio

// MARK: - ParakeetSTTEngine
//
// Real `STTEngine` backed by FluidAudio's Parakeet TDT models (Apple Neural
// Engine, on-device, no network at inference time — only the one-time model
// download hits the network).
//
// Two complementary paths, mirroring `MockSTTEngine`'s semantics:
//
// 1. Live  — two `SlidingWindowAsrManager` instances (one per audio track:
//            `.you` → microphone, `.farEnd` → system / far-end). `feed(_:track:)`
//            routes each buffer to the matching manager; every manager's
//            `transcriptionUpdates` stream is bridged into the shared
//            `liveUpdates` Combine subject, tagged with its track and with the
//            confirmed/volatile distinction mapped onto `LiveUpdate.isFinal`.
//
// 2. Batch — `transcribeFile(_:)` resamples the file to 16 kHz mono, runs the
//            single-shot `AsrManager.transcribe`, and groups the returned
//            `tokenTimings` into `TranscriptDraft` utterances (split on pauses
//            and sentence punctuation). Diarization is merged separately by the
//            integrator, so every draft defaults to far-end speaker key "s2".
//
// Everything degrades gracefully: if models never loaded, `isReady` stays false
// and the live/batch entry points throw `ASRError.notInitialized` rather than
// crashing, and the live audio feed silently no-ops.

/// Speech-to-text engine wrapping FluidAudio Parakeet (TDT) models.
final class ParakeetSTTEngine: STTEngine {

    // MARK: Configuration

    /// Configured model version string ("v2" = English-only, "v3" = multilingual).
    private let versionString: String

    /// Resolved FluidAudio model version derived from `versionString`.
    private let modelVersion: AsrModelVersion

    // MARK: Published / observable surface

    private let liveSubject = PassthroughSubject<LiveUpdate, Never>()
    var liveUpdates: AnyPublisher<LiveUpdate, Never> { liveSubject.eraseToAnyPublisher() }

    /// `true` once `prepare(progress:)` has downloaded + loaded models.
    /// Mutated only on the main actor; read freely from the UI thread.
    private(set) var isReady = false

    // MARK: FluidAudio model + manager state

    /// Loaded models, shared by the batch manager and both live managers.
    private var models: AsrModels?

    /// Batch (whole-file) transcription manager. Lazily created in `prepare`.
    private var batchManager: AsrManager?

    /// Live sliding-window managers, one per track.
    private var youManager: SlidingWindowAsrManager?
    private var farEndManager: SlidingWindowAsrManager?

    /// Tasks bridging each manager's `transcriptionUpdates` stream into `liveSubject`.
    private var youBridge: Task<Void, Never>?
    private var farEndBridge: Task<Void, Never>?

    /// Guards against feeding audio before `startLive()` has wired up managers.
    private var liveRunning = false

    /// Non-throwing init. Heavy work (download + load) happens in `prepare`.
    /// - Parameter version: "v2" (English-only) or "v3" (multilingual, default).
    init(version: String = "v3") {
        self.versionString = version
        self.modelVersion = version.lowercased() == "v2" ? .v2 : .v3
    }

    // MARK: - Preparation

    /// Download + load the Parakeet models for the configured version.
    ///
    /// Reports 0...1 progress via `progress`. FluidAudio surfaces real download
    /// progress through its `ProgressHandler`; we forward `fractionCompleted`
    /// and always emit a terminal `1.0` once models are loaded. Safe to call
    /// repeatedly — a second call simply re-confirms readiness.
    func prepare(progress: @escaping (Double) -> Void) async throws {
        if isReady, models != nil {
            progress(1)
            return
        }

        progress(0)

        // FluidAudio's progress handler is `@Sendable` and may be called off the
        // main thread; forward straight through (callers marshal to UI as needed).
        let handler: DownloadUtils.ProgressHandler = { dp in
            // Clamp to [0, 1] for safety against any phase-relative values.
            progress(min(max(dp.fractionCompleted, 0), 1))
        }

        // Download (if needed) and load. DEVICE-VALIDATE: requires Apple Silicon +
        // network for first run; on CI / unsupported hardware this throws and we
        // propagate so the UI can show a model-unavailable state (isReady stays false).
        let loaded = try await AsrModels.downloadAndLoad(
            version: modelVersion,
            progressHandler: handler
        )

        // Pre-build the batch manager so `transcribeFile` is ready immediately.
        let manager = AsrManager(config: .default)
        try await manager.loadModels(loaded)

        self.models = loaded
        self.batchManager = manager

        await MainActor.run { self.isReady = true }
        progress(1)
    }

    // MARK: - Live transcription

    /// Stand up two sliding-window managers (microphone + system) and begin
    /// streaming. Each manager's update stream is bridged into `liveUpdates`.
    func startLive() async throws {
        guard let models else { throw ASRError.notInitialized }

        // Tear down any prior session first (idempotent restart).
        await teardownLive()

        let you = SlidingWindowAsrManager(config: .default)
        let farEnd = SlidingWindowAsrManager(config: .default)

        try await you.loadModels(models)
        try await farEnd.loadModels(models)

        try await you.startStreaming(source: .microphone)
        try await farEnd.startStreaming(source: .system)

        self.youManager = you
        self.farEndManager = farEnd

        // Bridge each manager's async update stream into the Combine subject,
        // tagging the track and mapping confirmed→isFinal / volatile→!isFinal.
        youBridge = bridge(manager: you, track: .you)
        farEndBridge = bridge(manager: farEnd, track: .farEnd)

        liveRunning = true
    }

    /// Route a captured buffer to the manager for its track. No-ops (never
    /// crashes) if live isn't running yet — buffers may arrive before/after the
    /// streaming window. `SlidingWindowAsrManager.streamAudio` handles any input
    /// format (it resamples to 16 kHz mono internally).
    func feed(_ buffer: AVAudioPCMBuffer, track: AudioTrackTag) async {
        guard liveRunning else { return }
        switch track {
        case .you:    await youManager?.streamAudio(buffer)
        case .farEnd: await farEndManager?.streamAudio(buffer)
        }
    }

    /// Finish both managers, flush remaining audio, and tear the session down.
    func finishLive() async throws {
        defer { liveRunning = false }

        // `finish()` flushes remaining buffered audio through the decoder and
        // returns the final text; we don't need the return value here because the
        // bridged stream has already delivered the incremental updates. We still
        // call it so the recognition task completes cleanly. Failures from one
        // track shouldn't block finishing the other.
        var firstError: Error?
        if let you = youManager {
            do { _ = try await you.finish() } catch { firstError = firstError ?? error }
        }
        if let farEnd = farEndManager {
            do { _ = try await farEnd.finish() } catch { firstError = firstError ?? error }
        }

        await teardownLive()

        if let firstError { throw firstError }
    }

    /// Bridge a sliding-window manager's `transcriptionUpdates` stream into the
    /// shared `liveUpdates` subject. Runs until the stream terminates (on
    /// `finish()`/`cancel()`), then exits.
    private func bridge(manager: SlidingWindowAsrManager, track: AudioTrackTag) -> Task<Void, Never> {
        Task {
            // `transcriptionUpdates` is an `AsyncStream`; awaiting it on the actor
            // yields the live sequence for this manager.
            let stream = await manager.transcriptionUpdates
            for await update in stream {
                if Task.isCancelled { break }
                // Derive a timeline position from the latest token timing when
                // available; fall back to 0 for confidence-only updates.
                let timeSec = update.tokenTimings.last?.endTime ?? 0
                let live = LiveUpdate(
                    track: track,
                    text: update.text,
                    isFinal: update.isConfirmed,   // confirmed → final; volatile → provisional
                    timeSec: timeSec
                )
                // Deliver on the main actor: downstream consumers are
                // `@MainActor` `ObservableObject`s and must not be poked from the
                // ASR actor's executor (matches MockSTTEngine, which sends on main).
                await MainActor.run { self.liveSubject.send(live) }
            }
        }
    }

    /// Cancel bridge tasks and release live managers. Safe to call repeatedly.
    private func teardownLive() async {
        youBridge?.cancel()
        farEndBridge?.cancel()
        youBridge = nil
        farEndBridge = nil

        await youManager?.cancel()
        await farEndManager?.cancel()
        youManager = nil
        farEndManager = nil
    }

    // MARK: - Batch (refine) transcription

    /// Full-file transcription with word timings, split into utterance-level
    /// `TranscriptDraft`s. Resamples the file to 16 kHz mono, runs the single-shot
    /// Parakeet path, then groups the result's `tokenTimings` into lines on
    /// sentence punctuation and silence gaps.
    ///
    /// `speakerKey` defaults to far-end "s2"; the integrator overlays diarization.
    func transcribeFile(_ url: URL) async throws -> [TranscriptDraft] {
        guard let manager = batchManager else { throw ASRError.notInitialized }

        // 1. Resample to the model's required 16 kHz mono float samples.
        //    DEVICE-VALIDATE: real decoding requires loaded CoreML models on
        //    Apple Silicon; conversion itself is portable.
        let samples = try AudioConverter().resampleAudioFile(url)

        // 2. Run batch transcription. The `[Float]` overload returns an ASRResult
        //    carrying `tokenTimings`, which we need for line splitting.
        var decoderState = TdtDecoderState.make(decoderLayers: modelVersion.decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)

        // 3. Group token timings into utterances.
        return Self.makeDrafts(from: result)
    }

    // MARK: - Draft assembly

    /// Group a result's token timings into utterance-level drafts.
    ///
    /// Tokens are accumulated into a line; a new line is started when either
    /// (a) the gap between the previous token's end and this token's start
    /// exceeds `pauseThreshold`, or (b) the previous token ended with sentence
    /// punctuation. Word-boundary markers (SentencePiece "▁" / leading spaces)
    /// are normalized to plain spaces so the reconstructed text reads naturally.
    static func makeDrafts(from result: ASRResult) -> [TranscriptDraft] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No timings (e.g. empty/short audio): fall back to a single draft
            // covering the whole result so the transcript is never silently lost.
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [TranscriptDraft(tStart: 0, tEnd: result.duration, text: text, speakerKey: defaultSpeakerKey)]
        }

        /// Seconds of silence between tokens that forces an utterance break.
        let pauseThreshold: TimeInterval = 0.8

        var drafts: [TranscriptDraft] = []
        var lineText = ""
        var lineStart: TimeInterval = timings[0].startTime
        var lineEnd: TimeInterval = timings[0].endTime
        var previousEnd: TimeInterval = timings[0].startTime
        var hasContent = false

        func flush() {
            let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            drafts.append(TranscriptDraft(tStart: lineStart, tEnd: lineEnd,
                                          text: trimmed, speakerKey: defaultSpeakerKey))
        }

        for timing in timings {
            let piece = normalize(timing.token)
            // Skip control/empty tokens entirely.
            if piece.trimmingCharacters(in: .whitespaces).isEmpty && piece != " " { continue }

            let gap = timing.startTime - previousEnd
            let brokeOnPause = hasContent && gap > pauseThreshold
            let brokeOnPunct = hasContent && endsSentence(lineText)

            if brokeOnPause || brokeOnPunct {
                flush()
                lineText = ""
                lineStart = timing.startTime
                hasContent = false
            }

            if lineText.isEmpty {
                lineStart = timing.startTime
                // A leading word-boundary marker becomes a no-op space at line start.
                lineText = piece.hasPrefix(" ") ? String(piece.dropFirst()) : piece
            } else {
                lineText += piece
            }
            lineEnd = timing.endTime
            previousEnd = timing.endTime
            hasContent = true
        }
        flush()

        // Guard against pathological all-skipped input: still surface the text.
        if drafts.isEmpty {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                drafts.append(TranscriptDraft(tStart: lineStart, tEnd: lineEnd,
                                              text: text, speakerKey: defaultSpeakerKey))
            }
        }

        return drafts
    }

    /// Default speaker key for un-diarized drafts (far-end "Speaker 2").
    private static let defaultSpeakerKey = "s2"

    /// Normalize a SentencePiece token to display text: the word-boundary marker
    /// "▁" (U+2581) becomes a leading space.
    private static func normalize(_ token: String) -> String {
        token.replacingOccurrences(of: "\u{2581}", with: " ")
    }

    /// Whether the accumulated line currently ends a sentence (so the next token
    /// should begin a new utterance). Looks at the last non-space character.
    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.reversed().first(where: { !$0.isWhitespace }) else { return false }
        return last == "." || last == "?" || last == "!"
    }
}
