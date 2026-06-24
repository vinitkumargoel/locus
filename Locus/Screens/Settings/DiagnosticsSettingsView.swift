import SwiftUI

/// Diagnostics settings section — one-click on-device validation. Lists each
/// subsystem check (mic permission, model readiness, STT/diarization pipeline,
/// AI endpoint) with a status icon and the exact pass/fail detail, driven by
/// `AppState.runDiagnostics()`. The visual idiom mirrors `PermissionsSettingsView`.
struct DiagnosticsSettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if app.diagnostics.isEmpty {
                emptyState
            } else {
                ForEach(app.diagnostics) { check in
                    row(check)
                        .padding(.bottom, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header + run button

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Self-test")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("Checks each subsystem and reports the exact error. Synthetic-audio checks confirm the pipeline runs, not that transcription is correct.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { Task { await app.runDiagnostics() } } label: {
                HStack(spacing: 6) {
                    if app.diagnosticsRunning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(app.diagnosticsRunning ? "Running…" : "Run self-test")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(app.diagnosticsRunning)
            .opacity(app.diagnosticsRunning ? 0.7 : 1)
        }
        .padding(.bottom, 16)
    }

    private var emptyState: some View {
        Text("Run the self-test to validate microphone access, on-device models, the transcription and diarization pipelines, and the AI endpoint.")
            .font(.system(size: 12.5))
            .foregroundStyle(theme.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.card2))
            .hairline(theme.border2, cornerRadius: 10)
    }

    // MARK: Check row

    private func row(_ c: DiagnosticCheck) -> some View {
        HStack(spacing: 14) {
            Text(icon(for: c.passed))
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(iconBackground(for: c.passed))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(c.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(c.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(detailColor(for: c.passed))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.card)
        )
        .hairline(theme.border2, cornerRadius: 10)
    }

    // MARK: Status presentation

    private func icon(for passed: Bool?) -> String {
        switch passed {
        case .none:        return "⏳"
        case .some(true):  return "✅"
        case .some(false): return "⚠️"
        }
    }

    private func iconBackground(for passed: Bool?) -> Color {
        switch passed {
        case .none:        return theme.card2
        case .some(true):  return theme.okSoft
        case .some(false): return theme.recSoft
        }
    }

    private func detailColor(for passed: Bool?) -> Color {
        switch passed {
        case .none:        return theme.text2
        case .some(true):  return theme.text2
        case .some(false): return theme.rec
        }
    }
}

#Preview {
    DiagnosticsSettingsView()
        .environmentObject(AppState(services: .preview()))
        .environment(\.theme, .light)
        .frame(width: 640, height: 480)
        .padding()
}
