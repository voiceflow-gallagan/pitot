import PitotCore
import SwiftUI

struct KeybindingsReviewPanel: View {
    let model: KeybindingsModel

    var body: some View {
        let preview = model.preview
        VStack(alignment: .leading, spacing: 10) {
            Text("Review").font(.headline).accessibilityAddTraits(.isHeader)
            if !model.hasPending {
                Text(ReviewText.emptyKeybindings).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.pending) { edit in
                    Label(edit.summary, systemImage: "pencil").font(.callout)
                        .accessibilityLabel(ReviewLineKind.change.spokenText(edit.summary))
                }
                if preview.createsFile {
                    Label("Creates \(model.url.lastPathComponent), with the header the docs describe.", systemImage: "doc.badge.plus")
                        .font(.callout)
                }
                ForEach(Array((preview.notes + preview.warnings).enumerated()), id: \.offset) { _, text in
                    Label(text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .accessibilityLabel(ReviewLineKind.warning.spokenText(text))
                }
                ForEach(Array(preview.problems.enumerated()), id: \.offset) { _, text in
                    Label(text, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red)
                        .accessibilityLabel(ReviewLineKind.problem.spokenText(text))
                }
                DiffView(lines: preview.diff)
                HStack {
                    Button("Discard", role: .destructive) { model.discardPending() }
                        .disabled(model.isWriting)
                        .help(ReviewText.discardHelp)
                        .accessibilityLabel("Discard all pending keybinding changes")
                    Spacer()
                    Button("Apply") { Task { await model.apply() } }
                        .disabled(model.isWriting || !preview.canApply)
                        .help(ReviewText.applyHelp)
                        .accessibilityLabel("Apply all pending keybinding changes in one write")
                }
            }
        }
    }
}
