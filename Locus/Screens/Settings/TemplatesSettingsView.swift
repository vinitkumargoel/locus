import SwiftUI

/// Templates settings — a master list of prompt templates on the left and an
/// editor (name, variable inserts, body, save/discard) on the right.
struct TemplatesSettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    @State private var name = ""
    @State private var bodyText = ""
    // Suppresses the dirty flag while we programmatically reseed the editor.
    @State private var reseeding = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            left
            right
        }
        .frame(height: 420)
        .onAppear { reseed() }
        .onChange(of: app.editTemplateID) { reseed() }
    }

    private func reseed() {
        reseeding = true
        name = SampleData.templates.first { $0.id == app.editTemplateID }?.name ?? ""
        bodyText = SampleData.templateBody(app.editTemplateID)
        reseeding = false
    }

    // MARK: Left — template list

    private var left: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(SampleData.templates) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(t.id == app.editTemplateID ? theme.accent : theme.text)
                            Text(t.badge)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.text3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(t.id == app.editTemplateID ? theme.accentSoft : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { app.selectTemplateForEditing(t.id) }
                        Divider().overlay(theme.border2)
                    }
                }
            }

            Text("＋ New template")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    Divider().overlay(theme.border2)
                }
                .contentShape(Rectangle())
                .onTapGesture { app.newTemplate() }
        }
        .frame(width: 210)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.card))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .hairline(theme.border2, cornerRadius: 10)
    }

    // MARK: Right — editor

    private var right: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.card))
                    .hairline(theme.border, cornerRadius: 8)
                    .frame(maxWidth: .infinity)
                    .onChange(of: name) { if !reseeding { app.markTemplateDirty() } }

                Button { app.markTemplateDirty() } label: {
                    Text("Duplicate")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.card2))
                        .hairline(theme.border, cornerRadius: 7)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                Text("Insert:")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text2)
                ForEach(SampleData.templateVariables, id: \.self) { v in
                    Text(v)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.accentSoft))
                        .contentShape(Rectangle())
                        .onTapGesture { app.markTemplateDirty() }
                }
            }
            .padding(.bottom, 8)

            TextEditor(text: $bodyText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(theme.text)
                .scrollContentBackground(.hidden)
                .padding(13)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.card))
                .hairline(theme.border, cornerRadius: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: bodyText) { if !reseeding { app.markTemplateDirty() } }

            HStack(spacing: 8) {
                if app.teUnsaved {
                    Text("● Unsaved changes")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.warn)
                }
                Spacer()
                Button { app.discardTemplate() } label: {
                    Text("Discard")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.card2))
                        .hairline(theme.border, cornerRadius: 7)
                }
                .buttonStyle(.plain)
                Button { app.saveTemplate() } label: {
                    Text("Save")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(theme.accent))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
