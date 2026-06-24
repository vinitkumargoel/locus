import SwiftUI

/// Notification-style consent prompt shown when a meeting is detected.
/// Default-deny: nothing records until the user taps **Record**.
struct ConsentPromptView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Text("Z")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentSoft))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Zoom meeting detected")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(theme.text)
                    Text("Started just now · Locus can record it")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.text2)
                }
                Spacer(minLength: 0)
            }

            Text("Recording will capture your mic and the meeting audio, transcribed on-device. You're responsible for participant consent.")
                .font(.system(size: 12))
                .foregroundStyle(theme.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            // "Always record" opt-in
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(app.alwaysRecord ? theme.accent : theme.text3, lineWidth: 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(app.alwaysRecord ? theme.accent : .clear))
                        .frame(width: 16, height: 16)
                    if app.alwaysRecord {
                        Text("✓").font(.system(size: 10)).foregroundStyle(.white)
                    }
                }
                Text("Always record Zoom without asking")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
            }
            .contentShape(Rectangle())
            .onTapGesture { app.toggleAlways() }
            .padding(.top, 12)

            // Actions
            HStack(spacing: 8) {
                Button(action: { app.consentIgnore() }) {
                    Text("Ignore")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.card2))
                        .hairline(theme.border, cornerRadius: 8)
                }
                .buttonStyle(.plain)

                Button(action: { app.consentRecord() }) {
                    Text("Record")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.rec))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 12)
        .frame(width: 330)
        .floatingSurface(theme, cornerRadius: 13)
    }
}
