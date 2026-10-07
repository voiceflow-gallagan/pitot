import PitotCore
import SwiftUI

struct TweakRowView: View {
    let model: SettingsModel
    let tweak: Tweak

    var body: some View {
        let state = model.row(tweak)
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                titleLine(state)
                Text(tweak.keyText)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(tweak.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let layer = state.overriddenBy {
                    OverrideChip(model: model, layer: layer)
                }
                ForEach(state.notes) { note in
                    NoteLine(note: note)
                }
                if state.showsUnrecognized, let text = state.unrecognizedText {
                    UnrecognizedLine(text: text) { model.requestChange(nil, for: tweak) }
                        .disabled(model.isWriting)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TweakControl(model: model, tweak: tweak, state: state)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Reset to Default in \(model.scope.displayName)") { model.requestChange(nil, for: tweak) }
                .disabled(!model.canEditScope || state.isLocked || state.rowRefusal != nil || state.reading == .unset && state.pending == nil)
            if let url = URL(string: tweak.docURL) {
                Link("Open Documentation", destination: url)
            }
        }
    }

    private func titleLine(_ state: RowState) -> some View {
        HStack(spacing: 6) {
            if state.isLocked {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityLabel("Locked")
            }
            Text(tweak.title).font(.headline)
            RiskBadges(risks: tweak.risks)
            if state.isPending {
                Tag(text: "pending", symbol: "pencil", color: .orange).accessibilityLabel("Pending change")
            } else if state.autoSet != nil {
                Tag(text: "auto", symbol: "link", color: .blue).accessibilityLabel("Set automatically by another change")
            }
            if let url = URL(string: tweak.docURL) {
                Link(destination: url) {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open the Claude Code documentation")
                .accessibilityLabel("Documentation for \(tweak.title)")
            }
        }
    }
}

/// "Overridden by Project-local", with a button that selects that layer when Pitot can write it.
private struct OverrideChip: View {
    let model: SettingsModel
    let layer: LayerID

    var body: some View {
        HStack(spacing: 6) {
            Tag(text: "Overridden by \(layer.displayName)", symbol: "arrow.up.square", color: .orange)
                .accessibilityLabel("Overridden by \(layer.displayName) settings")
            if let kind = layer.writableKind, kind != model.scope, model.store(for: kind) != nil {
                Button("Edit in \(layer.displayName)") { model.switchScope(to: layer) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityLabel("Switch the scope to \(layer.displayName) settings")
            }
        }
    }
}

private struct NoteLine: View {
    let note: RowNote

    var body: some View {
        if note.kind == .quiet {
            Text(note.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label {
                Text(note.text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
            .font(.caption)
            .foregroundStyle(note.kind == .info ? .secondary : .primary)
        }
    }

    private var symbol: String {
        switch note.kind {
        case .info, .quiet: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .disabled: "nosign"
        case .locked: "lock.fill"
        }
    }

    private var color: Color {
        switch note.kind {
        case .info: .blue
        case .warning: .orange
        case .disabled, .locked, .quiet: .secondary
        }
    }
}

private struct UnrecognizedLine: View {
    let text: String
    let reset: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text("Unrecognized value: \(text)").textSelection(.enabled)
            } icon: {
                Image(systemName: "questionmark.diamond").foregroundStyle(.orange)
            }
            Button("Reset", action: reset)
                .controlSize(.small)
                .accessibilityLabel("Reset unrecognized value to default")
        }
        .font(.caption)
    }
}
