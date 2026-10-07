import PitotCore
import SwiftUI

/// Adds one binding: a context, a key (typed or recorded) and an action, checked live by the editor.
struct AddBindingSheet: View {
    let model: KeybindingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var context = "Chat"
    @State private var key = ""
    @State private var action: String?

    var body: some View {
        let plan = action.flatMap { action in key.isEmpty ? nil : model.check(.add(context: context, key: key, action: action)) }
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a binding").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Picker("Context", selection: $context) {
                ForEach(model.catalog.contexts, id: \.name) { context in
                    Text(context.name).tag(context.name)
                }
            }
            .help(model.catalog.context(named: context)?.description ?? "")
            Text(model.catalog.context(named: context)?.description ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Key") {
                KeyCaptureField(key: $key)
            }
            ActionPicker(model: model, context: context, selection: $action)
                .frame(height: 220)
            IssueList(plan: plan)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    guard let action else { return }
                    model.request(.add(context: context, key: key, action: action))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.map(\.isRefused) ?? true)
                .accessibilityLabel("Add the binding to the pending changes")
            }
        }
        .padding(20)
        .frame(width: 560)
        .onChange(of: context) { action = nil }
    }
}

/// Picks an action for one context from a searchable list. Legacy names are never offered.
struct ActionPicker: View {
    let model: KeybindingsModel
    let context: String
    @Binding var selection: String?
    @State private var search = ""

    var body: some View {
        let actions = model.actions(for: context).filter { action in
            search.isEmpty || action.id.localizedCaseInsensitiveContains(search) || action.description.localizedCaseInsensitiveContains(search)
        }
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search actions", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search actions")
            List(actions, id: \.id, selection: $selection) { action in
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.id).font(.callout.monospaced())
                    Text(action.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .tag(Optional(action.id))
                .accessibilityElement(children: .combine)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .accessibilityLabel("Actions for \(context)")
            if actions.isEmpty {
                Text(search.isEmpty ? "The docs list no actions for this context." : "No action matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Changes the action of one binding, with the same picker.
struct ChangeActionSheet: View {
    let model: KeybindingsModel
    let context: String
    let row: KeybindingGroup.Row
    @Environment(\.dismiss) private var dismiss
    @State private var action: String?

    var body: some View {
        let plan = action.flatMap { model.check(.change(context: context, key: row.key, action: $0)) }
        VStack(alignment: .leading, spacing: 14) {
            Text("Change the action for \(row.key)").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Text("\(context). Now: \(row.action ?? "null (unbound)")").font(.callout).foregroundStyle(.secondary)
            ActionPicker(model: model, context: context, selection: $action)
                .frame(height: 260)
            IssueList(plan: plan)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Change") {
                    guard let action else { return }
                    model.request(.change(context: context, key: row.key, action: action))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.map(\.isRefused) ?? true)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct IssueList: View {
    let plan: KeybindingsEditor.Plan?

    var body: some View {
        if let plan {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(plan.issues.enumerated()), id: \.offset) { _, issue in
                    let blocking = plan.blockingIssues.contains(issue)
                    Label {
                        Text(issue.message).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: blocking ? "xmark.octagon" : "exclamationmark.triangle").foregroundStyle(blocking ? .red : .orange)
                    }
                }
                ForEach(plan.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
                }
                if plan.issues.isEmpty {
                    Label("Ready to add.", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            }
            .font(.callout)
        }
    }
}
