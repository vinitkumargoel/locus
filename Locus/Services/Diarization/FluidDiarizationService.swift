import Foundation
import OSLog
import FluidAudio

/// Live speaker-diarization service backed by FluidAudio's offline pipeline
/// (pyannote community-1: segmentation + speaker embeddings + VBx clustering).
///
/// Conforms to `DiarizationService`. Mirrors `MockDiarizationService`'s contract:
/// `prepare()` loads the CoreML models (downloading + compiling on first run),
/// and `diarize(fileURL:)` resamples the file to 16 kHz mono and returns
/// "who spoke when" as `[DiarSegment]` with engine speaker labels.
///
/// The CoreML models, the model download, and the Neural Engine inference can
/// only be exercised on a real device — the offline pipeline is unavailable in
/// CI. The implementation is real and correct against the FluidAudio API, and
/// degrades gracefully: setup is deferred to async methods, all heavy work is
/// throwing, and `init()` never touches the model stack.
final class FluidDiarizationService: DiarizationService {

    private let log = Logger(subsystem: "com.locus.app", category: "Diarization")

    /// Default community-1 configuration. Cheap, non-throwing struct init.
    private let config = OfflineDiarizerConfig()

    /// FluidAudio offline manager. Constructed eagerly (its `init` is a cheap
    /// value copy and does NOT load models — model loading happens in
    /// `prepareModels()`), so it can be reused across multiple `diarize` calls.
    private let manager: OfflineDiarizerManager

    /// Resamples arbitrary audio files to the 16 kHz mono Float32 the diarizer
    /// models expect. Stateless; safe to reuse.
    private let converter = AudioConverter()

    /// Whether `prepareModels()` has completed successfully at least once.
    /// `process(audio:)` will lazily prepare models if this is still false, so
    /// callers that skip `prepare()` still get a working (if slower-first-call)
    /// path rather than a crash.
    private var didPrepareModels = false

    /// Non-throwing init: only constructs lightweight value/manager objects.
    /// All model download/compile/load work is deferred to `prepare()`.
    init() {
        self.manager = OfflineDiarizerManager(config: config)
    }

    /// Download (first run only), compile, and load the offline diarization
    /// CoreML models, then prewarm the Neural Engine. Idempotent — FluidAudio
    /// skips reloading if the models are already resident.
    ///
    /// Throws if the models cannot be fetched or compiled (e.g. no network on
    /// first run, or a corrupt cache that also fails the fallback re-download).
    // DEVICE-VALIDATE: requires network on first launch to fetch the ~model
    // bundle, and ANE/CoreML compilation that cannot run in CI.
    func prepare() async throws {
        log.info("Preparing FluidAudio offline diarizer models")
        try await manager.prepareModels()
        didPrepareModels = true
        log.info("FluidAudio diarizer models ready")
    }

    /// Diarize a saved audio file into speaker-tagged time segments.
    ///
    /// 1. Resamples the file to 16 kHz mono Float32 (`AudioConverter`).
    /// 2. Runs the offline pipeline (`OfflineDiarizerManager.process`).
    /// 3. Maps `result.segments` (`TimedSpeakerSegment`) → `[DiarSegment]`,
    ///    casting the engine's `Float` timestamps to `Double`.
    ///
    /// Graceful degradation:
    /// - If the file has no detectable speech, FluidAudio throws
    ///   `OfflineDiarizationError.noSpeechDetected`; we treat that as a normal
    ///   empty result (`[]`) rather than an error, matching the "diarization
    ///   found nobody" semantics the UI expects.
    /// - Any other failure (missing file, decode error, model load failure) is
    ///   rethrown so the caller can surface it.
    // DEVICE-VALIDATE: real CoreML inference on the Neural Engine; only the
    // resample step is exercisable without the model bundle.
    func diarize(fileURL: URL) async throws -> [DiarSegment] {
        // Lazily ensure models are loaded; `process` would do this internally
        // too, but doing it here keeps the failure surface explicit and lets us
        // record `didPrepareModels`.
        if !didPrepareModels {
            try await manager.prepareModels()
            didPrepareModels = true
        }

        // Resample to the 16 kHz mono Float32 the diarizer expects. This is the
        // one step that runs anywhere (no models needed) — pure AVFoundation.
        let samples = try converter.resampleAudioFile(fileURL)
        guard !samples.isEmpty else {
            log.notice("Diarization input produced no audio samples; returning empty result")
            return []
        }

        do {
            let result = try await manager.process(audio: samples)
            let segments = result.segments.map { seg in
                DiarSegment(
                    speakerId: seg.speakerId,
                    start: Double(seg.startTimeSeconds),
                    end: Double(seg.endTimeSeconds)
                )
            }
            log.info("Diarization produced \(segments.count, privacy: .public) segment(s)")
            return segments
        } catch let error as OfflineDiarizationError {
            // No speech is an expected, non-fatal outcome for silent/empty audio.
            if case .noSpeechDetected = error {
                log.notice("Diarization detected no speech; returning empty result")
                return []
            }
            log.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
