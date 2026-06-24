import SwiftUI

/// General settings — auto-detect toggle and per-app consent modes.
struct GeneralSettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            autoDetectCard

            Text("DETECTED APPS")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.text3)
                .padding(.top, 24)
                .padding(.bottom, 10)

            detectedAppsBox
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Auto-detect card

    private var autoDetectCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Auto-detect meetings")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("Watch for known apps and offer to record.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2)
                    .padding(.top, 3)
            }
            Spacer()
            PillToggle(isOn: app.detection, large: true) { app.toggleDetection() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.card2))
        .hairline(theme.border2, cornerRadius: 10)
    }

    // MARK: Detected apps box

    private var detectedAppsBox: some View {
        VStack(spacing: 0) {
            ForEach(Array(app.detectionApps.enumerated()), id: \.element.id) { pair in
                row(pair.element)
                if pair.offset < app.detectionApps.count - 1 {
                    Divider().overlay(theme.border2)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.card))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .hairline(theme.border2, cornerRadius: 10)
    }

    private func row(_ r: DetectionApp) -> some View {
        HStack(spacing: 12) {
            Text(r.app.short)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(r.app.color(theme))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.card2))

            Text(r.id)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(theme.text)

            Spacer()

            HStack(spacing: 2) {
                ForEach([(ConsentMode.ask, "Ask"), (ConsentMode.always, "Always"), (ConsentMode.never, "Never")], id: \.1) { pairMode in
                    let mode = pairMode.0
                    let label = pairMode.1
                    let active = app.consentMode[r.id] == mode
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(active ? theme.accent : theme.text2)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(active ? theme.win : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture { app.setConsentMode(app: r.id, mode: mode) }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.card2))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
