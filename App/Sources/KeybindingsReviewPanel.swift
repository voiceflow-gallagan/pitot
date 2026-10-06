import PitotCore
import SwiftUI

struct KeybindingsReviewPanel: View {
    let model: KeybindingsModel

    var body: some View {
        let preview = model.preview
        VStack(alignment: .leading, spacing: 10) {
            Text("Review").font(.headline)
            if !model.hasPending {
                Text("No pending keybinding changes.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.pending) { edit in
                    Label(edit.summary, systemImage: "pencil").font(.callout)
                }
                if preview.createsFile {
                    Label("Creates \(model.url.lastPathComponent) with the documented header.", systemImage: "doc.badge.plus").font(.callout)
                }
                ForEach(Array((preview.notes + preview.warnings).enumerated()), id: \.offset) { _, text in
                    Label(text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                ForEach(Array(preview.problems.enumerated()), id: \.offset) { _, text in
                    Label(text, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red)
                }
                DiffView(lines: preview.diff)
                HStack {
                    Button("Discard", role: .destructive) { model.discardPending() }
                        .disabled(model.isWriting)
                        .accessibilityLabel("Discard all pending keybinding changes")
                    Spacer()
                    Button("Apply") { Task { await model.apply() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isWriting || !preview.canApply)
                        .accessibilityLabel("Apply all pending keybinding changes in one write")
                }
            }
        }
    }
}
