import Foundation
import Combine
import AVFoundation
import CoreAudio
import OSLog
import AppKit

/// Live dual-track audio capture for Locus.
///
/// Conforms to `CaptureService`. Mirrors `MockCaptureService`'s contract — emits
/// `.started` on start, ~10 Hz `.level(you:farEnd:)` updates, `.farEndSilent`
/// when the far-end track produces no frames, `.deviceChanged` on configuration
/// changes, and `.stopped(paths,duration)` on stop — but for real:
///
/// - **Track A (far-end):** a CoreAudio *process tap* on the meeting app's
///   process. `bundleId → pid` (NSRunningApplication) → CoreAudio process object
///   (`kAudioHardwarePropertyTranslatePIDToProcessObject`) →
///   `CATapDescription(stereoMixdownOfProcesses:)` →
///   `AudioHardwareCreateProcessTap` → a *private aggregate device* that contains
///   the tap (`kAudioAggregateDeviceTapListKey` / `kAudioSubTapUIDKey`) →
///   `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart` to pull frames.
///   Mirrors the Insidegui/AudioCap and RecapAI/Recap reference implementations.
/// - **Track B (you):** an `AVAudioEngine` input-node tap on the default mic.
///
/// Both tracks are resampled to **16 kHz mono Float32** and published on `audio`
/// tagged `.farEnd` / `.you` for the live STT pipeline, and persisted
/// incrementally to compressed `.m4a` files under
/// `~/Library/Application Support/Locus/audio/<meetingId>-{far,mic}.m4a`.
///
/// Design alignment:
/// - **R6 (silent capture):** system-audio tap auth cannot be queried, so far-end
///   loss is detected *behaviorally* — no Track-A frames for ~8 s → `.farEndSilent`.
/// - **R7 (data loss):** audio is flushed to disk as it arrives (no whole-meeting
///   in-memory buffer), so a crash leaves a salvageable file.
/// - **R8 (stability):** an `AVAudioEngineConfigurationChange` notification or a
///   device-list change emits `.deviceChanged` and rebuilds the affected track.
///
/// Graceful degradation: if the process tap can't be created (no permission,
/// wrong OS, target not running) the service logs, emits `.farEndSilent`, and
/// continues **mic-only** — it never crashes.
final class CoreAudioCaptureService: CaptureService {

    // MARK: Publishers (Contracts)

    private let eventsSubject = PassthroughSubject<CaptureEvent, Never>()
    private let audioSubject = PassthroughSubject<(AVAudioPCMBuffer, AudioTrackTag), Never>()

    var events: AnyPublisher<CaptureEvent, Never> { eventsSubject.eraseToAnyPublisher() }
    var audio: AnyPublisher<(AVAudioPCMBuffer, AudioTrackTag), Never> { audioSubject.eraseToAnyPublisher() }

    private(set) var isRunning = false

    // MARK: Infrastructure

    private let log = Logger(subsystem: "com.locus.app", category: "Capture")

    /// Serializes all start/stop/rebuild mutation so the CoreAudio teardown is
    /// never racing the IOProc callbacks. The IOProc/mic-tap callbacks themselves
    /// run on their own real-time threads and only touch thread-safe primitives.
    private let queue = DispatchQueue(label: "com.locus.app.capture")

    /// Target STT format: 16 kHz mono Float32.
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!

    // MARK: Track B — microphone (AVAudioEngine)

    private var engine: AVAudioEngine?
    private var micConverter: AVAudioConverter?
    private var micFile: AVAudioFile?

    // MARK: Track A — far-end (CoreAudio process tap + aggregate device)

    private var processTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var tapIOProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var farConverter: AVAudioConverter?
    private var farFile: AVAudioFile?
    private var farTapStarted = false

    // MARK: Run state

    private var meetingId = ""
    private var targetBundleId: String?
    private var farPath: URL?
    private var micPath: URL?
    private var startDate = Date()

    private var paused = false { didSet { } }

    /// Latest RMS per track, written from the audio callbacks (atomic-ish via the
    /// lock) and sampled by the ~10 Hz level timer.
    private let levelLock = NSLock()
    private var lastYouRMS: Float = 0
    private var lastFarRMS: Float = 0

    /// Wall-clock of the last far-end frame; `nil` until the first frame arrives.
    /// Drives the behavioral `.farEndSilent` detection (R6).
    private var lastFarFrameAt: Date?
    private var farEndSilentEmitted = false

    private var levelTimer: DispatchSourceTimer?

    /// Threshold (seconds) of no far-end audio before warning. DESIGN §18 item 5
    /// flags the exact value as an open tuning item; 8 s tolerates genuine quiet
    /// stretches without false alarms.
    private let farEndSilenceThreshold: TimeInterval = 8.0

    // MARK: Lifecycle

    /// Non-throwing init. Heavy/throwing setup happens in `start(...)`.
    init() {}

    // MARK: CaptureService

    /// Begin dual-track capture for `meetingId`, optionally tapping
    /// `targetBundleId`'s process for far-end audio.
    ///
    /// Always starts the mic track (Track B). Far-end (Track A) is best-effort:
    /// any failure degrades to mic-only with a `.farEndSilent` signal rather than
    /// throwing — the contract `throws` only for a hard mic failure, which is the
    /// one path where there is nothing left to capture.
    func start(meetingId: String, targetBundleId: String?) throws {
        try queue.sync {
            guard !isRunning else { return }
            self.meetingId = meetingId
            self.targetBundleId = targetBundleId
            self.startDate = Date()
            self.paused = false
            self.farEndSilentEmitted = false
            self.lastFarFrameAt = nil
            self.farTapStarted = false

            let dir = Self.audioDirectory()
            self.farPath = dir.appendingPathComponent("\(meetingId)-far.m4a")
            self.micPath = dir.appendingPathComponent("\(meetingId)-mic.m4a")

            // Track B (mic) is the floor: if it fails there is nothing to record.
            do {
                try startMicTrack()
            } catch {
                log.error("Mic track failed to start: \(error.localizedDescription, privacy: .public)")
                tearDownLocked()
                throw error
            }

            // Track A (far-end) is best-effort. Failure -> mic-only + farEndSilent.
            startFarEndTrack(targetBundleId: targetBundleId)

            isRunning = true
            registerConfigurationObservers()
            startLevelTimer()

            eventsSubject.send(.started)
            log.info("Capture started for meeting \(meetingId, privacy: .public)")

            // If the tap never came up, we already know the far end is silent.
            if !farTapStarted {
                emitFarEndSilentOnce()
            }
        }
    }

    /// Gate writing + publishing without tearing down the hardware graph, so
    /// resume() is instant and the tap/engine keep their handles.
    func pause() {
        queue.sync {
            guard isRunning else { return }
            paused = true
            log.info("Capture paused")
        }
    }

    func resume() {
        queue.sync {
            guard isRunning else { return }
            paused = false
            // Reset the far-end silence clock so a long pause doesn't instantly
            // trip farEndSilent on resume.
            lastFarFrameAt = nil
            farEndSilentEmitted = false
            log.info("Capture resumed")
        }
    }

    /// Stop both tracks, flush + close the files, and emit the terminal
    /// `.stopped(paths, duration)` event.
    func stop() {
        queue.sync {
            guard isRunning else { return }
            let duration = Int(Date().timeIntervalSince(startDate).rounded())
            let far = farFile != nil ? farPath?.path : nil
            let mic = micFile != nil ? micPath?.path : nil
            tearDownLocked()
            isRunning = false
            eventsSubject.send(.stopped(audioFarPath: far, audioMicPath: mic, durationSec: duration))
            log.info("Capture stopped (\(duration, privacy: .public)s)")
        }
    }

    // MARK: - Track B: microphone via AVAudioEngine

    /// Install an input-node tap on the default mic, resample to 16 kHz mono, and
    /// publish + persist. Throws if the engine can't start (mic unavailable /
    /// permission revoked) — the one fatal capture path.
    // DEVICE-VALIDATE: requires a real input device + granted microphone TCC;
    // the engine won't produce frames in CI / headless.
    private func startMicTrack() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // A zero sample-rate format means there is no usable input device.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        micConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
        micFile = try? makeAudioFile(at: micPath)

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleBuffer(buffer, tag: .you)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        log.info("Mic track started @ \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public)ch")
    }

    private func stopMicTrack() {
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        micConverter = nil
        micFile = nil   // closing AVAudioFile flushes + finalizes the .m4a
    }

    // MARK: - Track A: far-end via CoreAudio process tap + aggregate device

    /// Best-effort far-end setup. Logs and returns on any failure (leaving the
    /// far-end inactive) so capture continues mic-only. Never throws.
    // DEVICE-VALIDATE: process taps require macOS 14.4+, the NSAudioCaptureUsage
    // TCC grant, and the target app actually running + producing audio. None of
    // that exists in CI; this whole path is exercised only on-device.
    private func startFarEndTrack(targetBundleId: String?) {
        guard #available(macOS 14.2, *) else {
            log.notice("Process taps require macOS 14.2+; far-end disabled")
            return
        }
        guard let bundleId = targetBundleId else {
            log.notice("No target bundle id; far-end disabled (mic-only)")
            return
        }
        guard let pid = pid(forBundleId: bundleId) else {
            log.notice("Target app \(bundleId, privacy: .public) not running; far-end disabled")
            return
        }
        guard let processObject = processObject(forPID: pid),
              processObject != AudioObjectID(kAudioObjectUnknown) else {
            log.notice("No CoreAudio process object for pid \(pid, privacy: .public); far-end disabled")
            return
        }

        // 1. Build the tap description: a stereo mixdown of just this process.
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.name = "Locus-\(meetingId)"
        description.isPrivate = true
        description.muteBehavior = .unmuted   // never silence the user's meeting

        // 2. Create the tap.
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            log.error("AudioHardwareCreateProcessTap failed (\(tapStatus, privacy: .public)); far-end disabled")
            return
        }
        processTapID = tapID

        // 3. Read the tap's stream format so we can size the resampler + writer.
        guard let format = tapStreamFormat(tapID: tapID) else {
            log.error("Could not read tap format; far-end disabled")
            destroyTap()
            return
        }
        tapFormat = format
        farConverter = AVAudioConverter(from: format, to: targetFormat)
        farFile = try? makeAudioFile(at: farPath)

        // 4. Create a private aggregate device that hosts the tap.
        guard let aggID = createAggregateDevice(tapUUID: description.uuid),
              aggID != AudioObjectID(kAudioObjectUnknown) else {
            log.error("Aggregate device creation failed; far-end disabled")
            destroyTap()
            return
        }
        aggregateDeviceID = aggID

        // 5. Attach an IOProc that wraps the incoming buffer list and pulls frames.
        let asbd = format.streamDescription.pointee
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handleFarEndIO(inInputData, asbd: asbd)
        }
        guard procStatus == noErr, let proc = procID else {
            log.error("AudioDeviceCreateIOProcIDWithBlock failed (\(procStatus, privacy: .public)); far-end disabled")
            destroyAggregate()
            destroyTap()
            return
        }
        tapIOProcID = proc

        // 6. Start pulling.
        let startStatus = AudioDeviceStart(aggID, proc)
        guard startStatus == noErr else {
            log.error("AudioDeviceStart failed (\(startStatus, privacy: .public)); far-end disabled")
            destroyAggregate()
            destroyTap()
            return
        }

        farTapStarted = true
        lastFarFrameAt = nil   // arm the silence detector; frames will set it
        log.info("Far-end tap started on \(bundleId, privacy: .public) (pid \(pid, privacy: .public))")
    }

    private func stopFarEndTrack() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown), let proc = tapIOProcID {
            AudioDeviceStop(aggregateDeviceID, proc)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, proc)
        }
        tapIOProcID = nil
        destroyAggregate()
        destroyTap()
        tapFormat = nil
        farConverter = nil
        farFile = nil   // closing AVAudioFile flushes + finalizes the .m4a
        farTapStarted = false
    }

    private func destroyTap() {
        if processTapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(processTapID)
            }
            processTapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func destroyAggregate() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// IOProc callback (real-time CoreAudio thread, dispatched onto `queue`):
    /// wrap the raw buffer list as an `AVAudioPCMBuffer` in the tap's format,
    /// then run it through the shared handler.
    private func handleFarEndIO(_ inInputData: UnsafePointer<AudioBufferList>,
                                asbd: AudioStreamBasicDescription) {
        guard let format = tapFormat else { return }
        // bufferListNoCopy borrows the live buffer; handleBuffer copies the float
        // samples out (resample + write) synchronously before we return, so the
        // no-copy borrow is safe.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData) else { return }
        _ = asbd
        handleBuffer(buffer, tag: .farEnd)
    }

    // MARK: - Shared buffer handling

    /// Resample to 16 kHz mono, publish on `audio`, persist to the track's file,
    /// and record RMS. Skips publishing/writing while paused (but the far-end
    /// timestamp is still bumped so a paused-but-live far end isn't flagged silent).
    private func handleBuffer(_ buffer: AVAudioPCMBuffer, tag: AudioTrackTag) {
        if tag == .farEnd {
            // Mark "we are receiving far-end frames" regardless of pause, so the
            // silence detector reflects the tap, not the pause state.
            levelLock.lock(); lastFarFrameAt = Date(); levelLock.unlock()
        }

        guard !paused else { return }

        let converter = (tag == .you) ? micConverter : farConverter
        guard let resampled = resample(buffer, with: converter) else { return }

        // RMS for the level meter, computed on the 16 kHz mono output.
        let rms = Self.rms(of: resampled)
        levelLock.lock()
        if tag == .you { lastYouRMS = rms } else { lastFarRMS = rms }
        levelLock.unlock()

        // Publish for the live STT pipeline.
        audioSubject.send((resampled, tag))

        // Persist incrementally (R7) — flush as we go.
        let file = (tag == .you) ? micFile : farFile
        do {
            try file?.write(from: resampled)
        } catch {
            // A write failure mid-recording is almost always low/no disk space.
            log.error("Write failed for \(String(describing: tag), privacy: .public): \(error.localizedDescription, privacy: .public)")
            eventsSubject.send(.diskFull)
        }
    }

    /// Resample an arbitrary-format PCM buffer to the 16 kHz mono target.
    /// Returns `nil` on converter error; falls back to a fresh converter if the
    /// cached one is missing (e.g. format changed under us).
    private func resample(_ input: AVAudioPCMBuffer, with cached: AVAudioConverter?) -> AVAudioPCMBuffer? {
        // Fast path: already the target format.
        if input.format == targetFormat { return input }

        let converter = cached ?? AVAudioConverter(from: input.format, to: targetFormat)
        guard let converter = converter else { return nil }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        if let convError = convError {
            log.error("Resample error: \(convError.localizedDescription, privacy: .public)")
            return nil
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    // MARK: - Level + silence timer (~10 Hz)

    private func startLevelTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.tickLevels() }
        levelTimer = timer
        timer.resume()
    }

    private func tickLevels() {
        guard isRunning else { return }

        levelLock.lock()
        let you = lastYouRMS
        let far = lastFarRMS
        let lastFar = lastFarFrameAt
        levelLock.unlock()

        if !paused {
            eventsSubject.send(.level(you: you, farEnd: far))
        }

        // R6: behavioral far-end silence detection. If the tap was created but no
        // frames have arrived for the threshold, surface `.farEndSilent` once.
        guard !paused, farTapStarted, !farEndSilentEmitted else { return }
        let reference = lastFar ?? startDate
        if Date().timeIntervalSince(reference) >= farEndSilenceThreshold {
            emitFarEndSilentOnce()
        }
    }

    private func emitFarEndSilentOnce() {
        guard !farEndSilentEmitted else { return }
        farEndSilentEmitted = true
        log.notice("Far-end silent — no Track-A frames (mic-only)")
        eventsSubject.send(.farEndSilent)
    }

    // MARK: - Device / configuration changes (R8)

    private var configObserver: NSObjectProtocol?
    private var deviceListBlock: AudioObjectPropertyListenerBlock?
    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func registerConfigurationObservers() {
        // Mic engine reconfiguration (AirPods connect, output switch, route change).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil) { [weak self] _ in
                self?.queue.async { self?.handleConfigurationChange() }
            }

        // System device-list changes (e.g. far-end device topology shifts).
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.handleConfigurationChange() }
        }
        deviceListBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceListAddress, queue, block)
    }

    private func unregisterConfigurationObservers() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        if let block = deviceListBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &deviceListAddress, queue, block)
            deviceListBlock = nil
        }
    }

    /// Rebuild + continue on a device/route change (DESIGN §11a R8). Emits
    /// `.deviceChanged` and re-establishes the mic engine; the far-end tap is
    /// rebuilt too since the aggregate device may have been invalidated.
    // DEVICE-VALIDATE: route-change rebuild can only be validated by physically
    // toggling devices (e.g. connecting AirPods) on a real machine.
    private func handleConfigurationChange() {
        guard isRunning else { return }
        log.notice("Audio configuration changed — rebuilding tracks")
        eventsSubject.send(.deviceChanged)

        // Rebuild mic track on the new default input.
        stopMicTrack()
        do {
            try startMicTrack()
        } catch {
            log.error("Mic rebuild failed: \(error.localizedDescription, privacy: .public)")
            eventsSubject.send(.error("Microphone unavailable after device change"))
        }

        // Rebuild far-end track (aggregate device may be invalid after the change).
        if targetBundleId != nil {
            stopFarEndTrack()
            farEndSilentEmitted = false
            lastFarFrameAt = nil
            startFarEndTrack(targetBundleId: targetBundleId)
            if !farTapStarted { emitFarEndSilentOnce() }
        }
    }

    // MARK: - Teardown

    /// Tear down everything. Must be called on `queue`.
    private func tearDownLocked() {
        levelTimer?.cancel(); levelTimer = nil
        unregisterConfigurationObservers()
        stopFarEndTrack()
        stopMicTrack()
    }

    deinit {
        // Best-effort cleanup if the owner drops us without stop().
        levelTimer?.cancel()
        unregisterConfigurationObservers()
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown), let proc = tapIOProcID {
            AudioDeviceStop(aggregateDeviceID, proc)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, proc)
        }
        destroyAggregate()
        destroyTap()
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    // MARK: - CoreAudio helpers

    /// Resolve a bundle identifier to a running PID via AppKit.
    private func pid(forBundleId bundleId: String) -> pid_t? {
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        return matches.first?.processIdentifier
    }

    /// Translate a PID to a CoreAudio process `AudioObjectID`
    /// (`kAudioHardwarePropertyTranslatePIDToProcessObject`).
    private func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var inputPID = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &inputPID, &size, &object)
        guard status == noErr else {
            log.error("TranslatePIDToProcessObject failed (\(status, privacy: .public))")
            return nil
        }
        return object
    }

    /// Read the tap's audio stream format (`kAudioTapPropertyFormat`).
    @available(macOS 14.2, *)
    private func tapStreamFormat(tapID: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            log.error("Read kAudioTapPropertyFormat failed (\(status, privacy: .public))")
            return nil
        }
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// Create a private aggregate device that contains the given tap (referenced
    /// by its UID). Mirrors AudioCap/Recap: `kAudioAggregateDeviceTapListKey` is
    /// an array of `{ kAudioSubTapUIDKey: <tap-uuid-string> }`.
    @available(macOS 14.2, *)
    private func createAggregateDevice(tapUUID: UUID) -> AudioObjectID? {
        let aggUID = "com.locus.app.aggregate.\(meetingId).\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Locus Capture",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString]
            ],
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard status == noErr else {
            log.error("AudioHardwareCreateAggregateDevice failed (\(status, privacy: .public))")
            return nil
        }
        return aggID
    }

    // MARK: - File + math helpers

    /// `~/Library/Application Support/Locus/audio`, created if needed.
    private static func audioDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Locus/audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Open a compressed AAC `.m4a` for incremental writing at the 16 kHz mono
    /// target rate. Writing buffers as they arrive (R7) means a crash leaves a
    /// finalizable file. Returns `nil` (rather than throwing) so a file failure
    /// degrades to publish-only rather than killing the capture.
    private func makeAudioFile(at url: URL?) throws -> AVAudioFile? {
        guard let url = url else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        return try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Root-mean-square level of a mono Float32 buffer, in 0...1.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let samples = channel[0]
        for i in 0..<n {
            let v = samples[i]
            sum += v * v
        }
        let mean = sum / Float(n)
        return mean > 0 ? mean.squareRoot() : 0
    }

    // MARK: - Errors

    private enum CaptureError: LocalizedError {
        case noInputDevice
        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone input device is available."
            }
        }
    }
}
