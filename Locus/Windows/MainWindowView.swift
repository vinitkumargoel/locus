import SwiftUI

/// The main app window: sidebar (nav + always-visible recording status) and the
/// screen router. Consent prompt is overlaid top-trailing (a notification-style
/// panel; production would float it as an NSPanel near the menu bar).
struct MainWindowView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                sidebar
                content
            }
            .background(theme.win)

            if app.consentOpen {
                ConsentPromptView()
                    .padding(.top, 14)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.18), value: app.consentOpen)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let sc = app.statusCardPresentation(theme)
        let dot = app.agentPresentation(theme).dotColor
        return VStack(alignment: .leading, spacing: 0) {
            // Reserve space for the system traffic-light controls.
            Color.clear.frame(height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text("LOCUS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text3)
                    .tracking(0.7)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                navRow(icon: "▦", title: "Library", active: app.screen == .library) { app.goLibrary() }

                if app.liveAvailable {
                    navRow(icon: "●", title: "Live transcript", active: app.screen == .live,
                           iconColor: theme.rec, trailing: app.elapsedString) { app.openLive() }
                }

                navRow(icon: "⚙", title: "Settings", active: app.screen == .settings) { app.goSettings() }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 0)

            // Always-visible recording status card.
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    StatusDot(color: dot, pulsing: app.recording)
                    Text(sc.label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(sc.text)
                        .tracking(0.2)
                }
                Text(sc.sub)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 9).fill(sc.bg))
            .hairline(sc.border, cornerRadius: 9)
            .padding(12)
        }
        .frame(width: 212)
        .frame(maxHeight: .infinity)
        .background(theme.side)
        .overlay(alignment: .trailing) { Rectangle().fill(theme.border).frame(width: 0.5) }
    }

    private func navRow(icon: String, title: String, active: Bool,
                        iconColor: Color? = nil, trailing: String? = nil,
                        action: @escaping () -> Void) -> some View {
        HStack(spacing: 11) {
            Text(icon)
                .font(.system(size: 13))
                .foregroundStyle(iconColor ?? (active ? theme.text : theme.text2))
                .frame(width: 18, alignment: .center)
            Text(title)
                .font(.system(size: 13.5))
                .foregroundStyle(active ? theme.text : theme.text2)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.rec)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(active ? theme.sideActive : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    // MARK: Content router

    @ViewBuilder private var content: some View {
        Group {
            switch app.screen {
            case .library:  LibraryView()
            case .live:     LiveTranscriptView()
            case .detail:   RecordingDetailView()
            case .settings: SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.win)
    }
}
