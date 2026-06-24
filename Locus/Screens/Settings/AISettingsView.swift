import SwiftUI

/// Summaries / AI settings — endpoint, API key, model picker, and a connection
/// test, with a status banner driven by `AppState.aiStatus`.
struct AISettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    private var modelChoices: [String] {
        var list = app.aiModelsAvailable
        if !app.aiModel.isEmpty && !list.contains(app.aiModel) { list.insert(app.aiModel, at: 0) }
        return list.isEmpty ? [app.aiModel] : list
    }

    var body: some View {
        let s = app.aiStatusStyle(theme)

        VStack(alignment: .leading, spacing: 0) {
            // Status banner
            HStack(spacing: 8) {
                Circle().fill(s.dot).frame(width: 8, height: 8)
                Text(s.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(s.fg)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9).fill(s.bg))
            .hairline(s.border, cornerRadius: 9)
            .padding(.bottom, 18)

            // Base URL
            Text("Base URL")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text2)
                .padding(.bottom, 6)
            TextField("http://localhost:11434/v1", text: $app.aiBaseURLField)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.card))
                .hairline(theme.border, cornerRadius: 8)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 14)

            // API key
            Text("API key")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text2)
                .padding(.bottom, 6)
            HStack(spacing: 8) {
                Group {
                    if app.aiMasked {
                        SecureField("sk-…", text: $app.aiKeyField)
                    } else {
                        TextField("sk-…", text: $app.aiKeyField)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.card))
                .hairline(theme.border, cornerRadius: 8)
                .frame(maxWidth: .infinity)
                Button { app.toggleMask() } label: {
                    Text(app.aiMasked ? "Show" : "Hide")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.card2))
                        .hairline(theme.border, cornerRadius: 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 14)

            // Model
            Text("Model")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text2)
                .padding(.bottom, 6)
            HStack(spacing: 8) {
                Picker("", selection: $app.aiModel) {
                    ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity)
                Button { app.loadAIModels() } label: {
                    Text("Load models")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.card2))
                        .hairline(theme.border, cornerRadius: 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 18)

            // Test connection
            Button { app.testAIConnection() } label: {
                Text(app.aiStatus == .testing ? "Testing…" : "Test connection")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent))
            }
            .buttonStyle(.plain)

            Text("Your key is stored locally and sent only to the endpoint you configure. Summaries are the only feature that contacts a network.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.text3)
                .lineSpacing(2)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
