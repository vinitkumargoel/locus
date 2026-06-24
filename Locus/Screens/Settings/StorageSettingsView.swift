import SwiftUI

/// Storage settings — retention policy, on-disk location, and a destructive
/// "delete all" action.
struct StorageSettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme
    @State private var confirmDeleteAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            retentionCard
            storageLocationRow
            deleteAllRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Delete all recordings?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete all recordings", role: .destructive) { app.deleteAllRecordings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every recording, transcript, and summary. This can't be undone.")
        }
    }

    // MARK: Retention

    private var retentionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Retention")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(theme.text)

            HStack(spacing: 10) {
                segment("Keep forever", active: app.retention == .forever) {
                    app.setRetention(.forever)
                }
                segment("Auto-delete after \(app.retentionDays) days", active: app.retention == .auto) {
                    app.setRetention(.auto)
                }
            }
            .padding(.top, 12)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.card2))
        .hairline(theme.border2, cornerRadius: 10)
        .padding(.bottom, 16)
    }

    private func segment(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Text(label)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(active ? theme.accent : theme.text2)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? theme.accentSoft : theme.card))
            .hairline(theme.border, cornerRadius: 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    // MARK: Storage location

    private var storageLocationRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Storage location")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(app.storagePath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.text3)
                    .padding(.top, 3)
            }
            Spacer()
            Button { app.revealStorage() } label: {
                Text("Reveal")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.card2))
                    .hairline(theme.border, cornerRadius: 7)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.clear))
        .hairline(theme.border2, cornerRadius: 10)
        .padding(.bottom, 10)
    }

    // MARK: Delete all

    private var deleteAllRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Delete all recordings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.rec)
                Text(app.libraryFooter)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.text2)
                    .padding(.top, 3)
            }
            Spacer()
            Button { confirmDeleteAll = true } label: {
                Text("Delete all…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.rec))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .hairline(theme.rec, cornerRadius: 10)
    }
}
