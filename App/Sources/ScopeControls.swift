import AppKit
import PitotCore
import SwiftUI

/// The project menu and the User | Project | Local picker that chooses where edits are written.
struct ScopeControls: View {
    let model: SettingsModel

    var body: some View {
        HStack(spacing: 8) {
            if model.showsProjectMenu {
                ProjectMenu(model: model)
            }
            if model.showsScopePicker {
                Picker("Scope", selection: Binding(get: { model.scope }, set: select)) {
                    ForEach(SettingsLayerKind.allCases, id: \.self) { kind in
                        Text(kind == .local ? "Local" : kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(model.isWriting)
                .help("The settings file your changes go to")
                .accessibilityLabel("Settings scope")
            }
        }
    }

    /// Project and Local need a folder, so picking them without one asks for it first.
    private func select(_ kind: SettingsLayerKind) {
        if model.selectScope(kind) { return }
        guard let folder = ProjectPanel.chooseFolder() else { return }
        Task {
            await model.selectProject(folder)
            model.selectScope(kind)
        }
    }
}

private struct ProjectMenu: View {
    let model: SettingsModel

    var body: some View {
        let choices = model.projectChoices
        let recent = choices.filter { $0.source == .recent }
        let suggested = choices.filter { $0.source == .claudeCode }
        Menu {
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent) { choice in
                        Button(choice.name) { Task { await model.selectProject(choice.url) } }.help(choice.url.path)
                    }
                }
            }
            if !suggested.isEmpty {
                Section("Claude Code Projects") {
                    ForEach(suggested) { choice in
                        Button(choice.name) { Task { await model.selectProject(choice.url) } }.help(choice.url.path)
                    }
                }
            }
            Divider()
            Button("Choose Folder…") {
                if let folder = ProjectPanel.chooseFolder() { Task { await model.selectProject(folder) } }
            }
            if model.projectFolder != nil {
                Button("Close Project") { model.closeProject() }
            }
        } label: {
            Label(model.projectFolder?.lastPathComponent ?? "No Project", systemImage: "folder")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .disabled(model.isWriting)
        .help(model.projectFolder?.path ?? "Choose a project folder to edit its settings")
        .accessibilityLabel(model.projectFolder.map { "Project \($0.lastPathComponent)" } ?? "Choose a project")
    }
}

enum ProjectPanel {
    @MainActor
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose a project folder. Pitot edits the settings files in its .claude folder."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
