import Foundation

// Wires the real engine. Kept separate from Contracts.swift so the mock
// container (`Services.preview()`) stays dependency-free for SwiftUI previews.

extension Services {
    static func live() -> Services {
        let settings = UserDefaultsSettingsStore()
        let secrets = KeychainSecretStore()
        return Services(
            store: GRDBMeetingStore(),
            capture: CoreAudioCaptureService(),
            stt: ParakeetSTTEngine(version: settings.sttModelVersion),
            diar: FluidDiarizationService(),
            llm: OpenAICompatibleLLM(),
            permissions: SystemPermissionsService(),
            settings: settings,
            secrets: secrets,
            detector: AppMeetingDetector()
        )
    }
}
