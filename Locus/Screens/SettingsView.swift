import SwiftUI

/// Settings — shell that owns the horizontal tab bar and routes to one section
/// view at a time. Each section is its own file/leaf.
struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(theme.border)

            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    section
                        .frame(maxWidth: 640, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SettingsSection.allCases, id: \.self) { tab in
                    let active = app.settingsSection == tab
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(active ? theme.accent : theme.text2)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(active ? theme.accentSoft : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { app.setSettingsSection(tab) }
                }
            }
            .padding(.horizontal, 22)
        }
        .frame(height: 52)
    }

    @ViewBuilder private var section: some View {
        switch app.settingsSection {
        case .general:       GeneralSettingsView()
        case .transcription: TranscriptionSettingsView()
        case .ai:            AISettingsView()
        case .templates:     TemplatesSettingsView()
        case .storage:       StorageSettingsView()
        case .permissions:   PermissionsSettingsView()
        }
    }
}
