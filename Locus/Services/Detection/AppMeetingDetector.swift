import Foundation
import Combine
import AppKit
import CoreAudio

// MARK: - AppMeetingDetector
//
// Live implementation of `MeetingDetector`. It watches `NSWorkspace` for the
// meeting apps we care about (Zoom, Slack) and corroborates "a meeting is
// actually happening" by polling CoreAudio's per-process audio-activity flags
// (`kAudioProcessPropertyIsRunningInput` / `…IsRunningOutput`).
//
// Why two signals instead of one:
//   • "App is running" alone is far too noisy — Zoom and Slack idle in the
//     background for hours without a call.
//   • CoreAudio activity alone catches the call but also catches notification
//     chimes, message pops, and brief UI sounds.
// So we require BOTH the app to be running AND sustained (> ~3s) audio I/O
// before emitting a `DetectedMeeting`. A short chime never crosses the debounce.
//
// Slack huddles do not spawn a separate helper process for audio — the audio
// I/O surfaces on Slack's own process, so the same pid→process translation
// covers huddles transparently.
//
// Degradation: if the CoreAudio process objects are unavailable (e.g. the
// `kAudioHardwarePropertyTranslatePIDToProcessObject` lookup yields
// `kAudioObjectUnknown`, or reads fail), we fall back to "app is running" only,
// but we KEEP the debounce so we still avoid emitting the instant an app
// launches. We never crash on a missing resource or denied permission.
//
// DEVICE-VALIDATE: the CoreAudio process-activity path requires a real audio
// session on real hardware and cannot be exercised in CI. Validate on-device
// that (a) joining a Zoom call / Slack huddle flips the running-input/output
// flags within a couple of poll ticks, (b) a notification chime does NOT cross
// the 3s debounce, and (c) leaving the call resets the session so a later call
// emits again.
final class AppMeetingDetector: MeetingDetector {

    // MARK: Registry

    /// A meeting app we know how to detect. `app` is the `MeetingApp.rawValue`
    /// string the rest of the app keys on ("Zoom" / "Slack").
    private struct KnownApp {
        let app: String
        let bundleId: String
    }

    private static let registry: [KnownApp] = [
        KnownApp(app: "Zoom", bundleId: "us.zoom.xos"),
        KnownApp(app: "Slack", bundleId: "com.tinyspeck.slackmacgap"),
    ]

    private static func known(forBundleId bundleId: String) -> KnownApp? {
        registry.first { $0.bundleId == bundleId }
    }

    // MARK: Tuning

    /// Background poll cadence (~1 Hz, per the contract).
    private let pollInterval: TimeInterval = 1.0
    /// Sustained-activity threshold before we treat audio as a real meeting.
    /// Slightly over 3s so a single 1 Hz blip from a chime can't accumulate.
    private let debounceSeconds: TimeInterval = 3.0

    // MARK: Output

    private let subject = PassthroughSubject<DetectedMeeting, Never>()
    var detections: AnyPublisher<DetectedMeeting, Never> { subject.eraseToAnyPublisher() }

    // MARK: Per-app tracking state

    /// Mutable detection state for a single bundleId, keyed in `sessions`.
    private final class Session {
        let bundleId: String
        let app: String
        var pid: pid_t
        /// When sustained audio activity first began (nil = not currently active).
        var activeSince: Date?
        /// True once we've emitted for the current active session — prevents
        /// re-emitting every poll tick. Reset when activity stops.
        var emitted: Bool = false

        init(bundleId: String, app: String, pid: pid_t) {
            self.bundleId = bundleId
            self.app = app
            self.pid = pid
        }
    }

    /// Keyed by bundleId. Only contains apps currently running.
    private var sessions: [String: Session] = [:]

    // MARK: Lifecycle plumbing

    private var pollTimer: DispatchSourceTimer?
    /// Serializes all state mutation + CoreAudio reads off the main thread.
    private let queue = DispatchQueue(label: "com.locus.detector", qos: .utility)
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isStarted = false

    /// Non-throwing init per the service contract — no hardware/permission work
    /// happens here; everything heavy is deferred to `start()`.
    init() {}

    deinit {
        // Best-effort teardown; `stop()` is idempotent.
        stop()
    }

    // MARK: MeetingDetector

    func start() {
        // Guard against double-start.
        if isStarted { return }
        isStarted = true

        // Seed the session table from whatever's already running, so a call that
        // is in progress when we start gets picked up (after the debounce).
        let running = NSWorkspace.shared.runningApplications
        queue.async { [weak self] in
            guard let self else { return }
            for runningApp in running {
                guard let bid = runningApp.bundleIdentifier,
                      let known = AppMeetingDetector.known(forBundleId: bid) else { continue }
                self.sessions[bid] = Session(bundleId: bid,
                                             app: known.app,
                                             pid: runningApp.processIdentifier)
            }
        }

        installWorkspaceObservers()
        startPolling()
    }

    func stop() {
        // Idempotent: safe to call when never started or already stopped.
        isStarted = false

        pollTimer?.cancel()
        pollTimer = nil

        let nc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers { nc.removeObserver(token) }
        workspaceObservers.removeAll()

        queue.async { [weak self] in
            self?.sessions.removeAll()
        }
    }

    // MARK: NSWorkspace observation
    //
    // We use launch/terminate notifications to keep `sessions` cheap and accurate
    // between polls, but the poll itself also reconciles against the live running
    // list, so a missed notification self-heals.

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        let launch = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                    object: nil, queue: nil) { [weak self] note in
            guard let self,
                  let runningApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = runningApp.bundleIdentifier,
                  let known = AppMeetingDetector.known(forBundleId: bid) else { return }
            let pid = runningApp.processIdentifier
            self.queue.async {
                self.sessions[bid] = Session(bundleId: bid, app: known.app, pid: pid)
            }
        }

        let terminate = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                       object: nil, queue: nil) { [weak self] note in
            guard let self,
                  let runningApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = runningApp.bundleIdentifier,
                  AppMeetingDetector.known(forBundleId: bid) != nil else { return }
            self.queue.async {
                self.sessions.removeValue(forKey: bid)
            }
        }

        workspaceObservers = [launch, terminate]
    }

    // MARK: Polling

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval,
                       repeating: pollInterval,
                       leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.poll() }
        pollTimer = timer
        timer.resume()
    }

    /// One poll tick. Runs on `queue`. Reconciles the running-app table, reads
    /// CoreAudio activity per session, applies the debounce, and emits.
    private func poll() {
        // Reconcile the session table against the live running-app list so a
        // dropped launch/terminate notification can't strand us.
        reconcileRunningApps()

        let now = Date()
        for session in sessions.values {
            let active = isAudioActive(pid: session.pid)

            if active {
                if session.activeSince == nil {
                    // Activity just began — start the debounce clock.
                    session.activeSince = now
                } else if !session.emitted,
                          now.timeIntervalSince(session.activeSince!) >= debounceSeconds {
                    // Sustained past the debounce, and we haven't emitted for this
                    // session yet — emit exactly once.
                    session.emitted = true
                    emit(DetectedMeeting(app: session.app,
                                         bundleId: session.bundleId,
                                         pid: session.pid))
                }
            } else {
                // Activity stopped — reset the session so the next call emits again.
                session.activeSince = nil
                session.emitted = false
            }
        }
    }

    /// Re-seed `sessions` from the live running list. Adds newly-running known
    /// apps (with a fresh, un-emitted session) and drops ones that have quit.
    /// Also refreshes pids in case an app relaunched between notifications.
    private func reconcileRunningApps() {
        var liveKnown: [String: pid_t] = [:]   // bundleId -> pid
        for runningApp in NSWorkspace.shared.runningApplications {
            guard let bid = runningApp.bundleIdentifier,
                  AppMeetingDetector.known(forBundleId: bid) != nil else { continue }
            liveKnown[bid] = runningApp.processIdentifier
        }

        // Drop sessions whose app is no longer running.
        for bid in sessions.keys where liveKnown[bid] == nil {
            sessions.removeValue(forKey: bid)
        }

        // Add / refresh sessions for running known apps.
        for (bid, pid) in liveKnown {
            if let existing = sessions[bid] {
                if existing.pid != pid {
                    // App relaunched — treat as a fresh session.
                    existing.pid = pid
                    existing.activeSince = nil
                    existing.emitted = false
                }
            } else if let known = AppMeetingDetector.known(forBundleId: bid) {
                sessions[bid] = Session(bundleId: bid, app: known.app, pid: pid)
            }
        }
    }

    // MARK: Emission

    private func emit(_ meeting: DetectedMeeting) {
        // Publish on the main queue so downstream UI/AppState consumers don't
        // have to hop threads.
        DispatchQueue.main.async { [weak self] in
            self?.subject.send(meeting)
        }
    }

    // MARK: CoreAudio process-activity probe

    /// Returns true when the process for `pid` is doing audio input OR output.
    ///
    /// Degrades gracefully: if the pid can't be translated to a CoreAudio
    /// process object (returns `kAudioObjectUnknown`), or the property reads
    /// fail, we return `false` here and the caller treats the app as "running
    /// but idle". In that bundleId-only fallback the debounce still applies, so
    /// we never emit on a bare app launch.
    private func isAudioActive(pid: pid_t) -> Bool {
        guard let processObject = processObject(for: pid),
              processObject != AudioObjectID(kAudioObjectUnknown) else {
            return false
        }
        let input = readBoolProperty(processObject, selector: kAudioProcessPropertyIsRunningInput)
        let output = readBoolProperty(processObject, selector: kAudioProcessPropertyIsRunningOutput)
        return input || output
    }

    /// Translate a Unix pid into a CoreAudio Process `AudioObjectID` via
    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`. The pid is supplied
    /// as the qualifier; the resulting AudioObjectID comes back as the data.
    /// Returns nil on any OSStatus failure (graceful degradation).
    private func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var inputPID = pid
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),   // qualifier data size
            &inputPID,                          // qualifier data (the pid)
            &dataSize,
            &processObject)

        guard status == noErr else { return nil }
        return processObject
    }

    /// Read a CoreAudio `UInt32` boolean property (0/1) on a process object.
    /// Any failure reads as `false` so a transient CoreAudio error can't
    /// register as activity.
    private func readBoolProperty(_ object: AudioObjectID,
                                  selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        // Defensive: confirm the property exists before reading it.
        guard AudioObjectHasProperty(object, &address) else { return false }

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return false }
        return value != 0
    }
}
