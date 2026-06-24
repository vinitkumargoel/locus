import SwiftUI

/// Permissions settings section — lists each macOS permission Locus needs,
/// with its grant status and a shortcut into System Settings when missing.
struct PermissionsSettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SampleData.permissions) { p in
                row(p)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ p: PermissionItem) -> some View {
        HStack(spacing: 14) {
            Text(p.icon)
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(p.granted ? theme.okSoft : theme.recSoft)
                )
                .foregroundStyle(p.granted ? theme.ok : theme.rec)

            VStack(alignment: .leading, spacing: 2) {
                Text(p.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(p.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(p.status)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(p.granted ? theme.ok : theme.rec)

            if !p.granted {
                Button {} label: {
                    Text("Open System Settings")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(theme.accent)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.card)
        )
        .hairline(theme.border2, cornerRadius: 10)
    }
}
