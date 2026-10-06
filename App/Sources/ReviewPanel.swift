import PitotCore
import SwiftUI

struct ReviewPanel: View {
    let model: SettingsModel

    var body: some View {
        let review = model.review
        VStack(alignment: .leading, spacing: 10) {
            Text("Review").font(.headline)
            if review.isEmpty {
                Text("No pending changes. Changes you make stay here until you apply them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(review.changes) { line in
                    ReviewLine(text: line.text, symbol: "pencil", color: .orange)
                }
                ForEach(review.autoSets) { line in
                    ReviewLine(text: line.text, symbol: "link", color: .blue)
                }
                ForEach(Array(review.warnings.enumerated()), id: \.offset) { _, warning in
                    ReviewLine(text: warning, symbol: "exclamationmark.triangle", color: .orange)
                }
                ForEach(review.suggestions, id: \.tweakId) { suggestion in
                    SuggestionLine(model: model, suggestion: suggestion)
                }
                ForEach(Array(review.problems.enumerated()), id: \.offset) { _, problem in
                    ReviewLine(text: problem, symbol: "xmark.octagon", color: .red)
                }
                if let error = review.previewError {
                    ReviewLine(text: error, symbol: "xmark.octagon", color: .red)
                } else {
                    DiffView(lines: review.diff)
                }
                HStack {
                    Button("Discard", role: .destructive) { model.discardPending() }
                        .disabled(model.isWriting)
                        .accessibilityLabel("Discard all pending changes")
                    Spacer()
                    Button("Apply") { Task { await model.applyPending() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isWriting || !review.canApply)
                        .accessibilityLabel("Apply all pending changes in one write")
                }
            }
        }
    }
}

private struct ReviewLine: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.callout)
    }
}

private struct SuggestionLine: View {
    let model: SettingsModel
    let suggestion: Resolution.UnsetSuggestion

    var body: some View {
        if let tweak = model.catalog.tweak(id: suggestion.tweakId) {
            HStack {
                Text("\(tweak.title) may stop working.").font(.callout)
                Spacer()
                Button("Clear \(tweak.title)") { model.requestChange(nil, for: tweak) }
                    .controlSize(.small)
                    .disabled(model.isWriting)
            }
        }
    }
}

struct DiffView: View {
    let lines: [DiffLine]
    /// The visible width, so line colors reach the right edge when every line is short.
    @State private var visibleWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text("\(prefix(line.kind)) \(line.text)")
                        .font(.caption.monospaced())
                        .foregroundStyle(line.kind == .gap ? .secondary : .primary)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line.kind))
                        .accessibilityLabel("\(label(line.kind)) \(line.text)")
                }
            }
            .padding(6)
            .frame(minWidth: visibleWidth, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { visibleWidth = $0 }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "-"
        case .context, .gap: " "
        }
    }

    private func label(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "Added"
        case .removed: "Removed"
        case .context: "Unchanged"
        case .gap: "Skipped lines"
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.22)
        case .removed: .red.opacity(0.22)
        case .context, .gap: .clear
        }
    }
}
