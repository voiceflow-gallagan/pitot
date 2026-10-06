import PitotCore
import SwiftUI

/// The keybindings editor: one collapsible group per context, with change, unbind and remove per row.
struct KeybindingsView: View {
    let model: SettingsModel
    @State private var isAdding = false
    @State private var changing: ChangeTarget?

    private var keybindings: KeybindingsModel { model.keybindings }

    var body: some View {
        let groups = keybindings.groups(search: model.searchText)
        VStack(spacing: 0) {
            KeybindingsHeader(model: model) { isAdding = true }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            if !keybindings.hasLoaded {
                ProgressView("Reading keybindings…").frame(maxHeight: .infinity)
            } else if keybindings.isMissing, !keybindings.hasPending {
                ContentUnavailableView {
                    Label("No keybindings file yet", systemImage: "keyboard")
                } description: {
                    Text("Pitot will create it with the documented header when you add the first binding.")
                } actions: {
                    Button("Add Binding") { isAdding = true }.disabled(!keybindings.canEdit)
                }
                .frame(maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "No bindings yet" : "No matching bindings", systemImage: "keyboard",
                    description: Text(model.searchText.isEmpty ? "Add a binding to change a shortcut." : "Try another search."))
                .frame(maxHeight: .infinity)
            } else {
                Form {
                    ForEach(groups) { group in
                        KeybindingGroupSection(model: keybindings, group: group) { changing = ChangeTarget(context: group.context, row: $0) }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Keybindings")
        .sheet(isPresented: $isAdding) {
            AddBindingSheet(model: keybindings)
        }
        .sheet(item: $changing) { target in
            ChangeActionSheet(model: keybindings, context: target.context, row: target.row)
        }
    }
}

struct ChangeTarget: Identifiable {
    let context: String
    let row: KeybindingGroup.Row

    var id: String { "\(context)|\(row.key)" }
}

private struct KeybindingsHeader: View {
    let model: SettingsModel
    let add: () -> Void

    var body: some View {
        @Bindable var keybindings = model.keybindings
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "keyboard").foregroundStyle(.purple).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(keybindings.url.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button("Add Binding", systemImage: "plus", action: add)
                    .disabled(!keybindings.canEdit)
                    .accessibilityLabel("Add a keybinding")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple.opacity(0.5)))
            .accessibilityElement(children: .contain)
            Text(KeybindingsModel.reloadNote).font(.caption).foregroundStyle(.secondary)
            if let problem = keybindings.problem {
                Banner(symbol: "exclamationmark.octagon", color: .red, text: problem, dismiss: nil)
            }
            if let message = keybindings.errorMessage {
                Banner(symbol: "xmark.octagon.fill", color: .red, text: message) { keybindings.errorMessage = nil }
            }
            if keybindings.externalChangeBanner {
                Banner(symbol: "arrow.triangle.2.circlepath", color: .blue, text: "Edited outside Pitot \u{2014} reloaded") {
                    keybindings.externalChangeBanner = false
                }
            }
        }
    }

    private var title: String {
        switch model.mode {
        case .copy: "Keybindings · working on a COPY"
        case .real: "Keybindings · REAL FILE"
        case .custom: "Keybindings · custom path"
        }
    }
}

private struct KeybindingGroupSection: View {
    let model: KeybindingsModel
    let group: KeybindingGroup
    let change: (KeybindingGroup.Row) -> Void
    @State private var isExpanded = true

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(group.rows) { row in
                    KeybindingRowView(model: model, context: group.context, row: row) { change(row) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.context).font(.headline)
                    Text(group.description ?? "A context the docs do not list. Claude Code ignores this block.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct KeybindingRowView: View {
    let model: KeybindingsModel
    let context: String
    let row: KeybindingGroup.Row
    let change: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(row.key)
                .font(.body.monospaced().weight(.semibold))
                .frame(minWidth: 120, alignment: .leading)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.action ?? "null (unbound)").font(.callout.monospaced())
                    if row.isPending {
                        Tag(text: "pending", symbol: "pencil", color: .orange).accessibilityLabel("Pending change")
                    }
                    ForEach(Array(row.issues.enumerated()), id: \.offset) { _, issue in
                        Tag(
                            text: issue.severity == .error ? "error" : "warning", symbol: "exclamationmark.triangle",
                            color: issue.severity == .error ? .red : .yellow)
                            .help(issue.message)
                            .accessibilityLabel("\(issue.severity == .error ? "Error" : "Warning"): \(issue.message)")
                    }
                }
                Text(row.description ?? (row.action == nil ? "Turns off the default shortcut for this key." : "No description in the docs."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(row.issues.enumerated()), id: \.offset) { _, issue in
                    Text(issue.message).font(.caption).foregroundStyle(issue.severity == .error ? .red : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if row.isLegacy {
                    Text("Legacy action name. Claude Code still reads it.\(row.replacedBy.map { " Replaced by \($0)." } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let defaultKey = row.defaultKey {
                    Text("Default key: \(defaultKey)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                Button("Change Action", systemImage: "pencil", action: change)
                    .accessibilityLabel("Change the action for \(row.key)")
                Button("Unbind", systemImage: "nosign") { model.request(.unbind(context: context, key: row.key)) }
                    .disabled(row.action == nil)
                    .accessibilityLabel("Unbind \(row.key), which writes null")
                Button("Remove", systemImage: "trash") { model.request(.remove(context: context, key: row.key)) }
                    .accessibilityLabel("Remove \(row.key) from the file")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(!model.canEdit)
        }
        .padding(.vertical, 3)
    }
}
