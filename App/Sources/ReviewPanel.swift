import PitotCore
import SwiftUI

struct ReviewPanel: View {
    let model: SettingsModel

    var body: some View {
        let review = model.review
        VStack(alignment: .leading, spacing: 10) {
            Text("Review").font(.headline).accessibilityAddTraits(.isHeader)
            if review.isEmpty {
                Text(ReviewText.empty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(review.changes) { line in
                    ReviewLine(kind: .change, text: line.text)
                }
                ForEach(review.autoSets) { line in
                    ReviewLine(kind: .autoSet, text: line.text)
                }
                ForEach(Array(review.warnings.enumerated()), id: \.offset) { _, warning in
                    ReviewLine(kind: .warning, text: warning)
                }
                ForEach(review.suggestions, id: \.tweakId) { suggestion in
                    SuggestionLine(model: model, suggestion: suggestion)
                }
                ForEach(Array(review.problems.enumerated()), id: \.offset) { _, problem in
                    ReviewLine(kind: .problem, text: problem)
                }
                if let error = review.previewError {
                    ReviewLine(kind: .problem, text: error)
                } else {
                    DiffView(lines: review.diff)
                }
                HStack {
                    Button("Discard", role: .destructive) { model.discardPending() }
                        .disabled(model.isWriting)
                        .help(ReviewText.discardHelp)
                        .accessibilityLabel("Discard all pending changes")
                    Spacer()
                    Button("Apply") { Task { await model.applyPending() } }
                        .disabled(model.isWriting || !review.canApply)
                        .help(ReviewText.applyHelp)
                        .accessibilityLabel("Apply all pending changes in one write")
                }
            }
        }
    }
}

/// The review panels' fixed text.
enum ReviewText {
    static let empty = "No changes waiting. When you change a setting, it waits here until you press Apply."
    static let emptyKeybindings = "No keybinding changes waiting. Each change waits here until you press Apply."
    static let applyHelp = "Write all pending changes to the file (Command-Return)"
    static let discardHelp = "Forget all pending changes (Command-Delete)"
}

/// What a line of the review panel is. VoiceOver says the kind first, since the icon only shows it.
enum ReviewLineKind {
    case change, autoSet, warning, problem

    var symbol: String {
        switch self {
        case .change: "pencil"
        case .autoSet: "link"
        case .warning: "exclamationmark.triangle"
        case .problem: "xmark.octagon"
        }
    }

    var color: Color {
        switch self {
        case .change, .warning: .orange
        case .autoSet: .blue
        case .problem: .red
        }
    }

    /// Automatic lines already start with "Also turning on", so they need no word in front.
    func spokenText(_ text: String) -> String {
        switch self {
        case .change: "Change: \(text)"
        case .autoSet: text
        case .warning: "Warning: \(text)"
        case .problem: "Problem: \(text)"
        }
    }
}

private struct ReviewLine: View {
    let kind: ReviewLineKind
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: kind.symbol).foregroundStyle(kind.color)
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.spokenText(text))
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
