import SwiftUI

/// Transcription settings — the on-device speech-to-text model picker.
/// Each row is a radio-style card with a status tag, detail line, optional
/// download progress bar, and a contextual action button.
struct TranscriptionSettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("On-device speech-to-text. Runs fully offline once a model is downloaded.")
                .font(.system(size: 13))
                .foregroundStyle(theme.text2)
                .padding(.bottom, 16)

            readinessSection
                .padding(.bottom, 16)

            ForEach(app.sttModels) { m in
                modelCard(m)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Model readiness

    /// Real download/load state for the on-device model bundle, bound to
    /// `app.modelState`: a progress bar while downloading, a ready/failed line,
    /// and a Download / Retry button that triggers `app.prepareModels()`.
    @ViewBuilder private var readinessSection: some View {
        let (statusText, statusColor): (String, Color) = {
            switch app.modelState {
            case .unknown:               return ("Model not downloaded yet", theme.text2)
            case .downloading(let f):    return ("Downloading model… \(Int(f * 100))%", theme.warn)
            case .ready:                 return ("Models ready", theme.ok)
            case .failed(let msg):       return ("Download failed — \(msg)", theme.rec)
            }
        }()

        let showButton: Bool = {
            switch app.modelState {
            case .ready, .downloading: return false
            case .unknown, .failed:    return true
            }
        }()

        let buttonLabel: String = {
            if case .failed = app.modelState { return "Retry" }
            return "Download model"
        }()

        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                if case .downloading(let f) = app.modelState {
                    ProgressView(value: f)
                        .progressViewStyle(.linear)
                        .tint(theme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showButton {
                Button { app.prepareModels() } label: {
                    Text(buttonLabel)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.card2))
                        .hairline(theme.border, cornerRadius: 7)
                }
                .buttonStyle(.plain)
                .disabled(app.modelStateIsBusy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.card))
        .hairline(theme.border2, cornerRadius: 10)
    }

    // MARK: Model card

    private func modelCard(_ m: STTModel) -> some View {
        // Tag colors per status.
        let tagColor: Color
        let tagBg: Color
        switch m.status {
        case .active:      tagColor = theme.accent; tagBg = theme.accentSoft
        case .downloading: tagColor = theme.warn;   tagBg = theme.recSoft
        case .ready:       tagColor = theme.text2;  tagBg = theme.card2
        }

        // Action button per status.
        let btnLabel: String
        switch m.status {
        case .active:      btnLabel = "Active"
        case .ready:       btnLabel = "Switch"
        case .downloading: btnLabel = "Cancel"
        }
        let btnColor: Color = (m.status == .active) ? theme.text3 : theme.text
        let btnBg: Color = (m.status == .ready) ? theme.card2 : Color.clear
        let btnBorder: Color = (m.status == .active) ? Color.clear : theme.border

        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .strokeBorder(m.status == .active ? theme.accent : theme.text3, lineWidth: 2)
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(m.status == .active ? theme.accent : Color.clear)
                    .frame(width: 9, height: 9)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(m.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text(m.tag)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tagColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(tagBg))
                }
                Text(m.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2)
                    .padding(.top, 3)
                if m.status == .downloading {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.border)
                            Capsule()
                                .fill(theme.accent)
                                .frame(width: geo.size.width * m.progress)
                        }
                    }
                    .frame(height: 5)
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { if m.status != .active { app.selectSTTModel(m.name) } } label: {
                Text(btnLabel)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(btnColor)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(btnBg))
                    .hairline(btnBorder, cornerRadius: 7)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.card))
        .hairline(m.status == .active ? theme.accent : theme.border2, cornerRadius: 10)
    }
}
