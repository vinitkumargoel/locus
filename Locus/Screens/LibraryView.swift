import SwiftUI

/// Library — the recordings list with search and a manual "Record now" entry.
/// Serves as the worked exemplar for the screen idiom (header bar + scrolling
/// body + footer, all states handled).
struct LibraryView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.border)

            if let err = app.storeError {
                HStack(spacing: 8) {
                    Text("⚠").font(.system(size: 13))
                    Text(err).font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(theme.warnFg)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(theme.warn)
            }

            if app.noMatches {
                noMatches
            } else if app.meetings.isEmpty {
                emptyState
            } else {
                list
            }

            Divider().overlay(theme.border2)
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Library").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.text)
            Spacer()

            HStack(spacing: 7) {
                Text("⌕").font(.system(size: 13)).foregroundStyle(theme.text3)
                TextField("Search titles and transcripts", text: $app.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 240)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.card2))
            .hairline(theme.border2, cornerRadius: 7)

            Button(action: { app.recordNow() }) {
                HStack(spacing: 7) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Text("Record now").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.rec))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(app.filteredMeetings) { m in
                    row(m)
                    Divider().overlay(theme.border2)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func row(_ m: Meeting) -> some View {
        HStack(spacing: 14) {
            Text(m.app.short)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(m.app.color(theme))
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(theme.card2))
                .hairline(theme.border2, cornerRadius: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(m.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text(m.sub)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            statusBadge(m.status)

            if m.hasSummary {
                Text("Summary")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.accentSoft))
            }

            Text(m.duration)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(theme.text3)
                .frame(width: 54, alignment: .trailing)

            Text("›").font(.system(size: 15)).foregroundStyle(theme.text3)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 0)
        .onTapGesture { app.openMeeting(m) }
    }

    /// Small status chip for non-clean recordings. `.ready`/`.recording` show
    /// nothing; `.processing` gets a subtle neutral pill.
    @ViewBuilder
    private func statusBadge(_ status: MeetingStatus) -> some View {
        switch status {
        case .recovered:
            pill("Interrupted", fg: theme.warnFg, bg: theme.warn)
        case .failed:
            pill("Failed", fg: theme.recSoft, bg: theme.rec)
        case .processing:
            pill("Processing", fg: theme.text2, bg: theme.card2)
        case .ready, .recording:
            EmptyView()
        }
    }

    private func pill(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(bg))
    }

    // MARK: Empty / no-match state

    private var noMatches: some View {
        VStack(spacing: 8) {
            Text("⌕").font(.system(size: 30)).foregroundStyle(theme.text2).opacity(0.4)
            Text("No recordings match “\(app.search)”")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Try a different title, name, or phrase from a conversation.")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Empty state (no recordings yet)

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("◎").font(.system(size: 30)).foregroundStyle(theme.text2).opacity(0.4)
            Text("No recordings yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Start a meeting in Zoom or a Slack huddle — or hit Record now — and Locus will capture and transcribe it here.")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(app.libraryFooter)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.text3)
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 30)
    }
}
