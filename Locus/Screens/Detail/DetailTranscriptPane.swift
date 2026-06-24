import SwiftUI

/// Detail — transcript column. Lives inside the detail layout (the parent gives
/// it its frame): a header block (title / meta / editable speaker chips), a
/// scrolling transcript that either shows a finalizing state or the saved lines,
/// and a playback bar pinned to the bottom.
struct DetailTranscriptPane: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            topBlock
            transcript
            playbackBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Top block

    private var topBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(app.selectedMeeting.title)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(theme.text)

            Text(app.selectedMeeting.detailMeta)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text2)
                .padding(.top, 5)

            HStack(spacing: 8) {
                ForEach(app.speakerKeys, id: \.self) { key in
                    speakerChip(key)
                }
            }
            .padding(.top, 14)
        }
        .padding(.top, 18)
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    private func speakerChip(_ key: String) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(theme.speakerColor(key))
                .frame(width: 8, height: 8)

            TextField("", text: Binding(
                get: { app.speakerName(key) },
                set: { app.renameSpeaker(key, to: $0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(theme.text)
            .frame(width: max(28, Double(app.speakerName(key).count) * 7.5))

            Text("✎")
                .font(.system(size: 11))
                .foregroundStyle(theme.text3)
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.card2))
        .hairline(theme.border2, cornerRadius: 20)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollView {
            if app.detailState == .processing {
                processing
            } else {
                lines
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 26)
    }

    private var processing: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Finalizing transcript…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Re-grouping speakers and cleaning up the live transcript.")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lines: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(SampleData.transcript.enumerated()), id: \.element.id) { pair in
                let i = pair.offset
                let line = pair.element
                row(line, i)
            }
        }
    }

    private func row(_ line: TranscriptLine, _ i: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(app.speakerName(line.speakerKey))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.speakerColor(line.speakerKey))
                Text(line.time)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(theme.text3)
            }
            .frame(width: 56, alignment: .trailing)

            Text(line.text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(app.playing && i == app.currentLineIndex ? theme.accentSoft : Color.clear)
        )
        .hoverHighlight(cornerRadius: 8)
        .contentShape(Rectangle())
        .onTapGesture { app.seek(toLineIndex: i) }
        .padding(.bottom, 4)
    }

    // MARK: Playback bar

    private var playbackBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(theme.border)

            HStack(spacing: 14) {
                Button { app.togglePlay() } label: {
                    Text(app.playing ? "❚❚" : "▶")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(theme.accent))
                }
                .buttonStyle(.plain)

                Text(TimeFmt.mmss(app.playPos))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(theme.text2)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.border)
                        Capsule()
                            .fill(theme.accent)
                            .frame(width: geo.size.width * CGFloat(min(1.0, Double(app.playPos) / Double(SampleData.detailDurationSeconds))))
                    }
                }
                .frame(height: 4)

                Text(app.selectedMeeting.duration)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(theme.text2)
            }
            .padding(.horizontal, 22)
            .frame(height: 54)
        }
    }
}
