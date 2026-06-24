import SwiftUI

/// Live transcript — the full-screen view shown while a recording is in
/// progress. Mirrors the prototype's live screen: a controls header, a body
/// that swaps between the listening / capture-error / streaming-lines states,
/// and a paused banner pinned to the bottom.
struct LiveTranscriptView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.border)

            bodyContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if app.paused {
                pausedBanner
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        let badgeColor = app.paused ? theme.warn : theme.rec
        let label = app.paused ? "PAUSED" : (app.rec == .captureError ? "ERROR" : "RECORDING")
        return HStack(spacing: 12) {
            HStack(spacing: 7) {
                StatusDot(color: badgeColor, pulsing: app.recording, size: 8)
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(badgeColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(theme.recSoft))

            Text("Zoom meeting")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(theme.text)

            Text(app.elapsedString)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(theme.text2)

            Spacer()

            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Text("You").font(.system(size: 11)).foregroundStyle(theme.text2)
                    MeterBars(count: 5, active: app.recording, seed: 0)
                }
                HStack(spacing: 6) {
                    Text("Far end").font(.system(size: 11)).foregroundStyle(theme.text2)
                    MeterBars(count: 5, active: app.recording, seed: 2.5)
                }
            }

            Button { app.pauseOrResume() } label: {
                Text(app.paused ? "Resume" : "Pause")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.card2))
                    .hairline(theme.border, cornerRadius: 7)
            }
            .buttonStyle(.plain)

            Button { app.stopRec() } label: {
                Text("Stop")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.rec))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
    }

    // MARK: Body

    @ViewBuilder
    private var bodyContent: some View {
        if app.rec == .recording && app.liveSub == .noSpeech {
            listening
        } else if app.rec == .captureError {
            captureError
        } else {
            lines
        }
    }

    // MARK: Listening (no speech yet)

    private var listening: some View {
        VStack(spacing: 10) {
            MeterBars(count: 9, active: true, maxHeight: 30)
            Text("Listening…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Recording has started. Transcript will appear as people speak.")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Capture error

    private var captureError: some View {
        VStack(spacing: 6) {
            Text("⚠").font(.system(size: 24)).foregroundStyle(theme.rec)
            Text("Audio capture was interrupted")
                .font(.system(size: 14.5, weight: .bold))
                .foregroundStyle(theme.text)
            Text("Locus lost the system-audio stream. Your transcript up to this point is safe. You can resume capture or stop and save what you have.")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            HStack(spacing: 10) {
                Button { app.resumeRec() } label: {
                    Text("Retry capture")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.accent))
                }
                .buttonStyle(.plain)

                Button { app.stopRec() } label: {
                    Text("Stop & save")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.card2))
                        .hairline(theme.border, cornerRadius: 7)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(maxWidth: 440)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.recSoft))
        .hairline(theme.rec, cornerRadius: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Streaming lines

    private var lines: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("ⓘ Live transcript is provisional — speakers and lines are refined when you stop.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.card2))
                .hairline(theme.border2, cornerRadius: 20)
                .padding(.bottom, 18)

                ForEach(app.liveLines) { ln in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(ln.speaker)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(theme.speakerColor(ln.speakerKey))
                            Text(ln.time)
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                                .foregroundStyle(theme.text3)
                        }
                        .frame(width: 74, alignment: .trailing)

                        Text(ln.text + (ln.isFinal ? "" : " ▍"))
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .foregroundStyle(ln.isFinal ? theme.text : theme.text2)
                    }
                    .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
    }

    // MARK: Paused banner

    private var pausedBanner: some View {
        Text("Paused — audio is not being captured. Resume to continue transcribing.")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(theme.warnFg)
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(theme.warn)
    }
}
