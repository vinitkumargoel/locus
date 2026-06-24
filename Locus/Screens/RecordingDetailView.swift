import SwiftUI

/// Recording detail — shell that owns the toolbar and the two-column layout.
/// Left column = transcript + playback (`DetailTranscriptPane`).
/// Right column = templated summary (`DetailSummaryPane`).
struct RecordingDetailView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(theme.border)

            HStack(spacing: 0) {
                DetailTranscriptPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .trailing) { Rectangle().fill(theme.border).frame(width: 0.5) }

                DetailSummaryPane()
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
                    .background(theme.card2)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: { app.goLibrary() }) {
                Text("‹ Library").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)

            Spacer()

            toolbarButton("Copy") {}
            toolbarButton("Export ▾") {}
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
    }

    private func toolbarButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.card2))
                .hairline(theme.border, cornerRadius: 7)
        }
        .buttonStyle(.plain)
    }
}
