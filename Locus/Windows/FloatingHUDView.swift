import SwiftUI

// MARK: - Floating recording bar UI
//
// Hosted inside `FloatingHUDController`'s NSPanel. Two states:
//   • collapsed — a compact pill: status dot + elapsed + pause/stop + expand
//   • expanded  — the pill header above a scrolling LIVE transcript so you can
//                 verify capture mid-call without switching to the Locus window.
//
// Everything binds to existing AppState: `rec`/`paused`, `elapsedString`,
// `liveLines`, and the real `pauseOrResume()` / `stopRec()` controls. The bar is
// dragged by its body/header (free placement) via the controller, which moves the
// underlying panel; the explicit buttons take precedence over the drag gesture.

private enum HUD {
    /// Padding around the card so its drop shadow isn't clipped by the panel edge.
    static let pad: CGFloat = 14
    static let corner: CGFloat = 14
    static let bottomID = "hud.bottom"
}

struct FloatingHUDView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    let controller: FloatingHUDController

    var body: some View {
        Group {
            if app.hudExpanded { expanded } else { collapsed }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(HUD.pad)
    }

    // MARK: Collapsed pill

    private var collapsed: some View {
        HStack(spacing: 10) {
            StatusDot(color: statusColor, pulsing: app.recording, size: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusLabel)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.3)
                    .foregroundStyle(statusColor)
                Text(elapsedText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(theme.text2)
            }
            Spacer(minLength: 8)
            controlButtons
            expandButton
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .floatingSurface(theme, cornerRadius: HUD.corner)
        .contentShape(RoundedRectangle(cornerRadius: HUD.corner))
        .gesture(dragGesture)
    }

    // MARK: Expanded panel

    private var expanded: some View {
        VStack(spacing: 0) {
            // Header doubles as the drag region (so the transcript stays scrollable).
            HStack(spacing: 9) {
                StatusDot(color: statusColor, pulsing: app.recording, size: 8)
                Text(statusLabel)
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(0.3)
                    .foregroundStyle(statusColor)
                Text(elapsedText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(theme.text2)
                Spacer(minLength: 6)
                controlButtons
                expandButton
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .contentShape(Rectangle())
            .gesture(dragGesture)

            Divider().overlay(theme.border2)

            transcriptList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .floatingSurface(theme, cornerRadius: HUD.corner)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if displayLines.isEmpty {
                        Text(app.isCapturing ? "Listening… transcript appears as people speak." : "No transcript yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    ForEach(displayLines) { ln in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(ln.speaker)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(theme.speakerColor(ln.speakerKey))
                                Text(ln.time)
                                    .font(.system(size: 9.5))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.text3)
                            }
                            Text(ln.text + (ln.isFinal ? "" : " ▍"))
                                .font(.system(size: 12.5))
                                .lineSpacing(2)
                                .foregroundStyle(ln.isFinal ? theme.text : theme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(ln.id)
                    }
                    Color.clear.frame(height: 1).id(HUD.bottomID)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: app.liveLines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(HUD.bottomID, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(HUD.bottomID, anchor: .bottom) }
        }
    }

    // MARK: Controls

    @ViewBuilder private var controlButtons: some View {
        // Pause / resume — real capture pause (CaptureService.pause/resume).
        Button { app.pauseOrResume() } label: {
            Text(app.paused ? "▶" : "❚❚")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.text)
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.card2))
                .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!app.isCapturing)
        .help(app.paused ? "Resume" : "Pause")

        // Stop & save.
        Button { app.stopRec() } label: {
            Text("◼")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.rec))
        }
        .buttonStyle(.plain)
        .disabled(!app.isCapturing)
        .help("Stop & save")
    }

    private var expandButton: some View {
        Button { app.toggleHUDExpanded() } label: {
            Text(app.hudExpanded ? "✕" : "☰")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text2)
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.card2))
                .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(app.hudExpanded ? "Hide transcript" : "Show live transcript")
    }

    // MARK: Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { _ in controller.dragChanged() }
            .onEnded { _ in controller.dragEnded() }
    }

    // MARK: Derived

    /// Real live lines while capturing; sample lines only in the Settings
    /// "Position on screen" preview (when not actually recording).
    private var displayLines: [LiveLine] {
        app.isCapturing ? app.liveLines : SampleData.liveLines
    }

    private var statusColor: Color {
        guard app.isCapturing else { return theme.accent }
        if app.paused { return theme.warn }
        return theme.rec
    }

    private var statusLabel: String {
        guard app.isCapturing else { return "Recording bar" }
        switch app.rec {
        case .paused:       return "PAUSED"
        case .captureError: return "ERROR"
        default:            return "REC"
        }
    }

    private var elapsedText: String {
        app.isCapturing ? app.elapsedString : "Drag to position"
    }
}

#Preview("Collapsed") {
    let app = AppState(services: .preview())
    return FloatingHUDView(controller: FloatingHUDController(app: app))
        .environmentObject(app)
        .environment(\.theme, .dark)
        .frame(width: 256, height: 78)
}

#Preview("Expanded") {
    let app = AppState(services: .preview())
    app.hudExpanded = true
    return FloatingHUDView(controller: FloatingHUDController(app: app))
        .environmentObject(app)
        .environment(\.theme, .light)
        .frame(width: 400, height: 470)
}
