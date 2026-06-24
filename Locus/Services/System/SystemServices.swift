import Foundation
import AVFoundation
import AppKit
import Security
import OSLog

// MARK: - System services
//
// Three small, fully-testable live services that back the "infrastructure"
// seam of the app: OS permissions, user settings, and the API-key secret.
//
//   • SystemPermissionsService — wraps AVFoundation mic authorization and the
//     System Settings deep-links.
//   • UserDefaultsSettingsStore — backs every SettingsStore property with
//     UserDefaults.standard, with defaults that match MockSettingsStore.
//   • KeychainSecretStore     — stores the AI API key in the macOS Keychain.
//
// All three degrade gracefully: a denied permission, a missing default, or a
// Keychain failure produces a sensible value rather than a crash.

// MARK: - Permissions

/// Live `PermissionsService`. Microphone auth goes through AVFoundation; the
/// system-audio (process-tap) path has no queryable status so it is reported as
/// `.unknown`, exactly as the contract documents.
final class SystemPermissionsService: PermissionsService {

    init() {}

    /// Current microphone authorization, mapped from `AVAuthorizationStatus`.
    func micStatus() -> PermState {
        Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Prompt for microphone access (no-op re-prompt if already decided) and
    /// return the resulting state. Bridges the completion-handler API to async.
    func requestMic() async -> PermState {
        // If the user already decided, `requestAccess` returns the existing
        // answer immediately without showing a prompt — so we can always call it.
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        // After the system resolves the request, re-read the authoritative
        // status: this distinguishes `.denied` from `.restricted`, etc.
        let status = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        // Defensive: if the status read somehow lags, fall back to the boolean.
        if status == .undetermined { return granted ? .granted : .denied }
        return status
    }

    /// Process-tap / system-audio authorization cannot be queried on macOS, so
    /// this is always `.unknown` (the UI treats it as "ask on first use").
    func systemAudioStatus() -> PermState { .unknown }

    /// Open the relevant pane of System Settings via the documented
    /// `x-apple.systempreferences` URL scheme.
    func openSystemSettings(_ pane: SettingsPane) {
        let anchor: String
        switch pane {
        case .microphone:      anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Helpers

    private static func map(_ status: AVAuthorizationStatus) -> PermState {
        switch status {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .denied   // restricted == cannot use, surface as denied
        case .notDetermined: return .undetermined
        @unknown default:    return .unknown
        }
    }
}

// MARK: - Settings

/// Live `SettingsStore` backed by `UserDefaults.standard`. Every property reads
/// through to the defaults database; defaults (when a key was never written)
/// match `MockSettingsStore` so the live and preview builds behave identically.
///
/// Keys are namespaced under `locus.` to avoid collisions with framework keys.
final class UserDefaultsSettingsStore: SettingsStore {

    private let defaults: UserDefaults

    /// Injectable for tests; production uses `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let aiBaseURL          = "locus.aiBaseURL"
        static let aiModel            = "locus.aiModel"
        static let sttModelVersion    = "locus.sttModelVersion"
        static let detectionEnabled   = "locus.detectionEnabled"
        static let retentionForever   = "locus.retentionForever"
        static let retentionDays      = "locus.retentionDays"
        static let disclaimerAccepted = "locus.disclaimerAccepted"
        static let darkAppearance     = "locus.darkAppearance"
        static let hudEnabled         = "locus.hudEnabled"
        static let hudPosX            = "locus.hudPosX"
        static let hudPosY            = "locus.hudPosY"
    }

    // Default values applied when the key has never been written. These mirror
    // MockSettingsStore so first-run behavior is identical to previews.
    private enum Default {
        static let aiBaseURL          = "http://localhost:11434/v1"
        static let aiModel            = ""
        static let sttModelVersion    = "v3"
        static let detectionEnabled   = true
        static let retentionForever   = true
        static let retentionDays      = 30
        static let disclaimerAccepted = false
        static let darkAppearance     = false
        static let hudEnabled         = true
        static let hudPosX            = 1.0   // right
        static let hudPosY            = 0.0   // top  → defaults to top-right
    }

    var aiBaseURL: String {
        // `string(forKey:)` returns nil when unset; coalesce to the default.
        get { defaults.string(forKey: Key.aiBaseURL) ?? Default.aiBaseURL }
        set { defaults.set(newValue, forKey: Key.aiBaseURL) }
    }

    var aiModel: String {
        get { defaults.string(forKey: Key.aiModel) ?? Default.aiModel }
        set { defaults.set(newValue, forKey: Key.aiModel) }
    }

    var sttModelVersion: String {
        get { defaults.string(forKey: Key.sttModelVersion) ?? Default.sttModelVersion }
        set { defaults.set(newValue, forKey: Key.sttModelVersion) }
    }

    var detectionEnabled: Bool {
        // For Bools we must check presence explicitly: `bool(forKey:)` returns
        // `false` for a missing key, which would clobber a `true` default.
        get { defaults.object(forKey: Key.detectionEnabled) as? Bool ?? Default.detectionEnabled }
        set { defaults.set(newValue, forKey: Key.detectionEnabled) }
    }

    var retentionForever: Bool {
        get { defaults.object(forKey: Key.retentionForever) as? Bool ?? Default.retentionForever }
        set { defaults.set(newValue, forKey: Key.retentionForever) }
    }

    var retentionDays: Int {
        // Likewise `integer(forKey:)` returns 0 for a missing key; coalesce the
        // absent case to the 30-day default.
        get { defaults.object(forKey: Key.retentionDays) as? Int ?? Default.retentionDays }
        set { defaults.set(newValue, forKey: Key.retentionDays) }
    }

    var disclaimerAccepted: Bool {
        get { defaults.object(forKey: Key.disclaimerAccepted) as? Bool ?? Default.disclaimerAccepted }
        set { defaults.set(newValue, forKey: Key.disclaimerAccepted) }
    }

    var darkAppearance: Bool {
        get { defaults.object(forKey: Key.darkAppearance) as? Bool ?? Default.darkAppearance }
        set { defaults.set(newValue, forKey: Key.darkAppearance) }
    }

    var hudEnabled: Bool {
        get { defaults.object(forKey: Key.hudEnabled) as? Bool ?? Default.hudEnabled }
        set { defaults.set(newValue, forKey: Key.hudEnabled) }
    }

    var hudPosX: Double {
        get { defaults.object(forKey: Key.hudPosX) as? Double ?? Default.hudPosX }
        set { defaults.set(newValue, forKey: Key.hudPosX) }
    }

    var hudPosY: Double {
        get { defaults.object(forKey: Key.hudPosY) as? Double ?? Default.hudPosY }
        set { defaults.set(newValue, forKey: Key.hudPosY) }
    }
}

// MARK: - Secrets

/// Live `SecretStore` that keeps the AI API key in the macOS Keychain as a
/// generic password (`kSecClassGenericPassword`). The key is identified by a
/// fixed service/account pair so reads, upserts, and deletes all target the
/// same item.
///
/// Every operation handles `errSecItemNotFound` (and other OSStatus errors)
/// gracefully — a read returns `nil`, a delete of a missing item is a no-op.
final class KeychainSecretStore: SecretStore {

    private let service: String
    private let account: String
    private let log = Logger(subsystem: "com.locus.app", category: "Keychain")

    /// Accessibility class for the stored key. `WhenUnlockedThisDeviceOnly` means
    /// the key is readable only while the screen is unlocked (not merely after
    /// first boot-unlock) and never syncs to iCloud or migrates to another Mac —
    /// the right posture for a desktop app that only needs the key during active,
    /// user-initiated summary generation.
    private let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    /// Service/account default to the app's fixed identifiers; injectable so
    /// tests can use an isolated item.
    init(service: String = "com.locus.app", account: String = "ai-api-key") {
        self.service = service
        self.account = account
    }

    /// Read the stored key, or `nil` if none is set (or on any Keychain error).
    func apiKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String]  = true
        query[kSecMatchLimit as String]  = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess else {
            // errSecItemNotFound (and anything else) → treat as "no key set".
            return nil
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Upsert (`value != nil`) or delete (`value == nil`) the stored key.
    func setApiKey(_ value: String?) {
        guard let value, !value.isEmpty else {
            delete()
            return
        }

        let data = Data(value.utf8)

        // Try to update an existing item first; if there is none, add it.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            add(data)
        default:
            // Some other failure (e.g. the item exists but is inaccessible).
            // Best-effort recover: delete and re-add so the new value sticks.
            delete()
            add(data)
        }
    }

    /// Add the key with our accessibility class, logging (never echoing the key)
    /// if the Keychain rejects it — otherwise the user thinks the key saved while
    /// `apiKey()` will return nil on the next launch.
    private func add(_ data: Data) {
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = accessibility
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("Keychain add failed (OSStatus \(status, privacy: .public)); API key was not saved")
        }
    }

    // MARK: Helpers

    /// The query that uniquely identifies our single Keychain item.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Remove the item if present; `errSecItemNotFound` is fine.
    private func delete() {
        let status = SecItemDelete(baseQuery as CFDictionary)
        _ = status // errSecItemNotFound and errSecSuccess are both acceptable.
    }
}
