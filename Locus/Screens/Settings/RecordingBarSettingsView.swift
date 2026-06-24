import SwiftUI

/// Settings → Recording Bar. Enables the floating recording bar and lets the user
/// drop it onto one of six anchor positions (the bar can also be dragged anywhere
/// while it's on screen). "Position on screen" shows the bar over the desktop so
/// the user can drag-position it without being in a meeting.
struct RecordingBarSettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            enableRow
            positionSection
            tip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Leaving this tab (or Settings) ends the transient "position on screen"
        // preview, so the bar can't be stranded on screen with no way to dismiss it.
        .onDisappear { app.setHUDPreview(false) }
    }

    // MARK: Enable

    private var enableRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Floating recording bar")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text("Shows a small always-on-top bar while recording so you can pause, stop, and watch the live transcript right over your meeting.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PillToggle(isOn: app.hudEnabled, large: true) { app.toggleHUDEnabled() }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.card))
        .hairline(theme.border2, cornerRadius: 10)
    }

    // MARK: Position

    private var positionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Position")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text("Pick a corner or edge below. You can also drag the bar anywhere while it's on screen.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { app.setHUDPreview(!app.hudPreview) } label: {
                    Text(app.hudPreview ? "Done" : "Position on screen")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(app.hudPreview ? .white : theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(app.hudPreview ? theme.accent : theme.accentSoft))
                }
                .buttonStyle(.plain)
                .disabled(!app.hudEnabled)
            }

            grid
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.card))
        .hairline(theme.border2, cornerRadius: 10)
        .opacity(app.hudEnabled ? 1 : 0.5)
    }

    private var grid: some View {
        VStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(rowAnchors(row)) { anchor in
                        anchorCell(anchor)
                    }
                }
            }
        }
    }

    private func rowAnchors(_ row: Int) -> [HUDAnchor] {
        HUDAnchor.allCases.filter { $0.gridRow == row }.sorted { $0.gridCol < $1.gridCol }
    }

    private func anchorCell(_ anchor: HUDAnchor) -> some View {
        let active = app.hudEnabled && app.hudNearestAnchor == anchor
        return Button { app.moveHUD(to: anchor) } label: {
            VStack(spacing: 6) {
                miniScreen(anchor: anchor, active: active)
                Text(anchor.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(active ? theme.accent : theme.text2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9).fill(active ? theme.accentSoft : theme.card2))
            .hairline(active ? theme.accent : theme.border2, cornerRadius: 9)
        }
        .buttonStyle(.plain)
        .disabled(!app.hudEnabled)
    }

    /// A tiny "screen" with a bar glyph in the matching corner/edge.
    private func miniScreen(anchor: HUDAnchor, active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(theme.win)
            .frame(width: 56, height: 34)
            .hairline(theme.border, cornerRadius: 4)
            .overlay(alignment: alignment(for: anchor)) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(active ? theme.accent : theme.text3)
                    .frame(width: 18, height: 5)
                    .padding(4)
            }
    }

    private func alignment(for anchor: HUDAnchor) -> Alignment {
        switch anchor {
        case .topLeft:      return .topLeading
        case .topCenter:    return .top
        case .topRight:     return .topTrailing
        case .bottomLeft:   return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight:  return .bottomTrailing
        }
    }

    private var tip: some View {
        Text("The bar floats above other apps — including full-screen meetings — and never steals keyboard focus.")
            .font(.system(size: 11.5))
            .foregroundStyle(theme.text3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    RecordingBarSettingsView()
        .environmentObject(AppState(services: .preview()))
        .environment(\.theme, .light)
        .frame(width: 640, height: 540)
        .padding()
}
