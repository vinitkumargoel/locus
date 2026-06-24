import SwiftUI

// MARK: - Agent status presentation
//
// Centralized port of the prototype's menu-bar agent + sidebar status-card
// derivations, so the menu-bar item, popover, and sidebar all stay in sync.

struct AgentPresentation {
    var dotColor: Color
    var pulsing: Bool
    var barLabel: String
    var barText: Color
    var barBg: Color
    var glyph: String
    var title: String
    var sub: String
    var ring: Bool
}

struct StatusCardPresentation {
    var bg: Color
    var border: Color
    var text: Color
    var label: String
    var sub: String
}

extension AppState {
    func agentPresentation(_ t: Theme) -> AgentPresentation {
        switch rec {
        case .recording:
            return AgentPresentation(dotColor: t.rec, pulsing: true,
                barLabel: menuBarLabelText, barText: t.rec, barBg: t.recSoft,
                glyph: "●", title: "Recording", sub: "Zoom · " + TimeFmt.mmss(elapsed), ring: true)
        case .paused:
            return AgentPresentation(dotColor: t.warn, pulsing: false,
                barLabel: menuBarLabelText, barText: t.warn, barBg: t.recSoft,
                glyph: "❚❚", title: "Paused", sub: "Capture paused", ring: false)
        case .processing:
            return AgentPresentation(dotColor: t.accent, pulsing: true,
                barLabel: menuBarLabelText, barText: t.menubarText, barBg: .clear,
                glyph: "◌", title: "Finalizing", sub: "Saving recording", ring: false)
        case .captureError:
            return AgentPresentation(dotColor: t.rec, pulsing: false,
                barLabel: menuBarLabelText, barText: t.rec, barBg: t.recSoft,
                glyph: "⚠", title: "Capture error", sub: "Audio interrupted", ring: false)
        case .idle:
            return AgentPresentation(dotColor: t.text3, pulsing: false,
                barLabel: menuBarLabelText, barText: t.menubarText, barBg: .clear,
                glyph: "●", title: "Not recording",
                sub: detection ? "Auto-detection is on" : "Auto-detection is off", ring: false)
        }
    }

    func statusCardPresentation(_ t: Theme) -> StatusCardPresentation {
        switch rec {
        case .recording:
            return StatusCardPresentation(bg: t.recSoft, border: t.rec, text: t.rec,
                label: "RECORDING", sub: "Zoom · " + TimeFmt.mmss(elapsed) + " elapsed")
        case .paused:
            return StatusCardPresentation(bg: t.card2, border: t.border2, text: t.warn,
                label: "PAUSED", sub: "Capture paused at " + TimeFmt.mmss(elapsed))
        case .processing:
            return StatusCardPresentation(bg: t.card2, border: t.border2, text: t.accent,
                label: "PROCESSING", sub: "Finalizing transcript…")
        case .captureError:
            return StatusCardPresentation(bg: t.recSoft, border: t.rec, text: t.rec,
                label: "CAPTURE ERROR", sub: "Audio stream interrupted")
        case .idle:
            return StatusCardPresentation(bg: t.card2, border: t.border2, text: t.text,
                label: detection ? "Idle" : "IDLE",
                sub: detection ? "Detection on · waiting for a meeting" : "Auto-detection off · manual only")
        }
    }
}

// MARK: - Menu-bar status item label

struct MenuBarLabel: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: app.recording ? "record.circle.fill" : "waveform")
            if app.isCapturing || app.rec == .processing {
                Text(app.menuBarLabelText)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Menu-bar popover

struct MenuBarPopover: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let p = app.agentPresentation(theme)
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 11) {
                Text(p.glyph)
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9).fill(p.dotColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(p.ring ? p.dotColor.opacity(0.5) : .clear, lineWidth: 2)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(.system(size: 14, weight: .bold)).foregroundStyle(theme.text)
                    Text(p.sub).font(.system(size: 12)).foregroundStyle(theme.text2)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border2).frame(height: 1) }

            // Actions
            VStack(spacing: 0) {
                if app.rec == .idle || app.rec == .processing {
                    PopoverRow(leadingDot: theme.rec, label: "Start recording") { app.recordNow() }
                }
                if app.isCapturing {
                    PopoverRow(glyph: app.paused ? "▶" : "❚❚",
                               label: app.paused ? "Resume" : "Pause") { app.pauseOrResume() }
                    PopoverRow(square: true, label: "Stop & save") { app.stopRec() }
                    PopoverRow(glyph: "≣", label: "Open live transcript") { app.openLive() }
                }

                Divider().overlay(theme.border2).padding(.horizontal, 4).padding(.vertical, 6)

                // Auto-detection toggle row
                HStack {
                    Text("Auto-detection").font(.system(size: 13)).foregroundStyle(theme.text)
                    Spacer()
                    PillToggle(isOn: app.detection) { app.toggleDetection() }
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .hoverHighlight()
                .onTapGesture { app.toggleDetection() }

                PopoverRow(glyph: "⌥", label: "Simulate Zoom detected", muted: true) { app.simulateDetect() }
                PopoverRow(glyph: "⚠", label: "Simulate capture error", muted: true) { app.simulateCaptureError() }
                PopoverRow(glyph: "◳", label: "Open Locus window") {
                    app.openWindow()
                    openWindow(id: "main")
                }
            }
            .padding(8)
        }
        .frame(width: 300)
        .background(theme.card)
    }
}

/// One tappable row in the popover.
private struct PopoverRow: View {
    @Environment(\.theme) private var theme
    var glyph: String? = nil
    var leadingDot: Color? = nil
    var square: Bool = false
    let label: String
    var muted: Bool = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 14, alignment: .center)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(muted ? theme.text2 : theme.text)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .hoverHighlight()
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    @ViewBuilder private var leading: some View {
        if let leadingDot {
            Circle().fill(leadingDot).frame(width: 8, height: 8)
        } else if square {
            RoundedRectangle(cornerRadius: 2).fill(theme.text).frame(width: 9, height: 9)
        } else if let glyph {
            Text(glyph).font(.system(size: 13)).foregroundStyle(muted ? theme.text2 : theme.text)
        }
    }
}
