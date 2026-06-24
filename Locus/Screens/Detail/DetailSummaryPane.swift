import SwiftUI

/// Right summary column of the detail view. Parent supplies the 300-pt width
/// and card2 background; this view fills it with a header (template picker +
/// generate button) and a body that switches across every summary state.
struct DetailSummaryPane: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.border)
            body_
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Summary")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(theme.text)

            HStack(spacing: 8) {
                Picker("", selection: $app.activeTemplateID) {
                    ForEach(app.templatesList) { t in
                        Text(t.name).tag(t.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity)

                Button { app.generate() } label: {
                    Text(app.summaryState == .ready ? "Regenerate" : "Generate")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.accent))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
        }
        .padding(.top, 18)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: Body

    private var body_: some View {
        ScrollView {
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch app.summaryState {
        case .notConfigured: notConfigured
        case .empty:         empty
        case .generating:    generating
        case .error:         errorState
        case .ready:         ready
        }
    }

    // MARK: States

    private var notConfigured: some View {
        VStack(spacing: 6) {
            Text("⚙")
                .font(.system(size: 24))
                .foregroundStyle(theme.text2)
                .opacity(0.4)
            Text("Summaries need an AI endpoint")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Connect your own local or hosted model to generate templated summaries. Transcription works without it.")
                .font(.system(size: 12))
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            Button { app.goAISettings() } label: {
                Text("Configure in Settings")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("✦")
                .font(.system(size: 24))
                .foregroundStyle(theme.text2)
                .opacity(0.4)
            Text("No summary yet")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("Pick a template and generate a summary of this conversation.")
                .font(.system(size: 12))
                .foregroundStyle(theme.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var generating: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GENERATING…")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.streamText)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                    .lineSpacing(3)
                BlinkingCaret()
            }
        }
    }

    private var errorState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Couldn't generate summary")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(theme.rec)
            Text("The AI endpoint at your configured URL didn't respond. Check that your local model is running.")
                .font(.system(size: 12))
                .foregroundStyle(theme.text2)
                .lineSpacing(2)
                .padding(.top, 6)
            HStack(spacing: 8) {
                Button { app.generate() } label: {
                    Text("Retry")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.accent))
                }
                .buttonStyle(.plain)
                Button { app.goAISettings() } label: {
                    Text("Open settings")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.win))
                        .hairline(theme.border, cornerRadius: 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.recSoft))
        .hairline(theme.rec, cornerRadius: 10)
    }

    private var ready: some View {
        let latest = app.detailSummaries.first
        let meta = latest.map { "\($0.templateName) · \($0.model)" } ?? "Summary"
        let isStale = latest?.isStale ?? false
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text2)
                Spacer()
                Text("↻ Regenerate")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .contentShape(Rectangle())
                    .onTapGesture { app.generate() }
            }
            .padding(.bottom, isStale ? 8 : 14)

            if isStale {
                Text("Transcript changed since this was generated — regenerate to refresh.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.warnFg)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.warn))
                    .padding(.bottom, 14)
            }

            // Real generated summary (Markdown text from the LLM).
            Text(markdown(app.streamText))
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Render the summary as lightweight Markdown, falling back to plain text.
    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: - Blinking caret

/// A blinking text caret shown while a summary is streaming in.
private struct BlinkingCaret: View {
    @Environment(\.theme) private var theme
    @State private var visible = false

    var body: some View {
        Rectangle()
            .fill(theme.accent)
            .frame(width: 7, height: 14)
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: visible)
            .onAppear { visible = true }
    }
}
