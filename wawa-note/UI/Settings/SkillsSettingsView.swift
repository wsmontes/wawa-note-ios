import SwiftUI

// Related JIRA: KAN-10, KAN-33

/// Manage analysis skills — view, edit prompts, change templates.
///
/// Skills are configurable resources that define HOW the agent analyzes content.
/// Each skill links to a Meetily template that defines WHAT output to produce.
struct SkillsSettingsView: View {
    @StateObject private var store = AnalysisSkillStore.shared
    @State private var selectedSkill: AnalysisSkill?
    @State private var showingEditor = false
    @State private var editingPrompt = ""
    @State private var editingTemplateID = ""

    var body: some View {
        List {
            ForEach(Array(store.skills.values).sorted(by: { $0.displayName < $1.displayName })) { skill in
                Button {
                    selectedSkill = skill
                    editingPrompt = skill.systemPrompt
                    editingTemplateID = skill.templateID
                    showingEditor = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(skill.displayName)
                                .font(.headline)
                            if skill.isUserEdited {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                        }
                        Text(skill.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Label(skill.category, systemImage: "folder")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Label("\(skill.maxIterations) iter", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Label(skill.defaultModel, systemImage: "brain")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if !skill.templateID.isEmpty {
                                Label(skill.templateID, systemImage: "doc.text")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Analysis Skills")
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                SkillEditorView(
                    skill: selectedSkill,
                    prompt: $editingPrompt,
                    templateID: $editingTemplateID,
                    onSave: {
                        guard let skill = selectedSkill else { return }
                        store.updateSkill(named: skill.name, systemPrompt: editingPrompt, templateID: editingTemplateID)
                        showingEditor = false
                    },
                    onReset: {
                        guard let skill = selectedSkill else { return }
                        store.resetSkill(named: skill.name)
                        showingEditor = false
                    }
                )
            }
        }
    }
}

// MARK: - Skill Editor

private struct SkillEditorView: View {
    let skill: AnalysisSkill?
    @Binding var prompt: String
    @Binding var templateID: String
    let onSave: () -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill?.displayName ?? "")
                        .font(.headline)
                    Text(skill?.description ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                TextEditor(text: $prompt)
                    .font(.caption.monospaced())
                    .frame(minHeight: 200)
            } header: {
                Text("System Prompt")
            } footer: {
                Text("This prompt defines the procedure the agent follows.")
            }

            Section {
                Picker("Template", selection: $templateID) {
                    ForEach(MeetilyTemplateService.shared.templates) { tpl in
                        Text(tpl.name).tag(tpl.id)
                    }
                }
            } header: {
                Text("Linked Template")
            } footer: {
                Text("The template defines the output format (sections, fields).")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if let proc = skill?.procedure {
                        Text("Procedure").font(.subheadline.weight(.medium))
                        ForEach(proc.steps, id: \.step) { step in
                            HStack {
                                Text("\(step.step).")
                                    .foregroundStyle(.secondary)
                                Text(step.description)
                            }
                            .font(.caption)
                        }
                    }

                    if let validation = skill?.validation, let required = validation.requiredFields {
                        Text("Required Fields").font(.subheadline.weight(.medium))
                        Text(required.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Default Model:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(skill?.defaultModel ?? "")
                            .font(.caption)
                    }
                    HStack {
                        Text("Max Iterations:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(skill?.maxIterations ?? 0)")
                            .font(.caption)
                    }
                }
            } header: {
                Text("Skill Details (read-only)")
            }

            Section {
                Button("Reset to Default") {
                    showResetConfirmation = true
                }
                .foregroundStyle(.red)
                .disabled(!(skill?.isUserEdited ?? false))
            }
        }
        .navigationTitle("Edit Skill")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: onSave)
            }
        }
        .alert("Reset Skill", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive, action: onReset)
        } message: {
            Text("This will restore the original built-in prompt and template for this skill.")
        }
    }
}
