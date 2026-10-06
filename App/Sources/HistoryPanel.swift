import PitotCore
import SwiftUI

/// Applied groups of every layer, newest first. Undo reverses the newest group of the selected layer.
struct HistoryPanel: View {
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Button("Undo in \(model.undoTargetName)", systemImage: "arrow.uturn.backward") { Task { await model.undoInSection() } }
                    .controlSize(.small)
                    .disabled(!model.canUndoInSection || model.isWritingInSection)
                    .accessibilityLabel("Undo the last applied group in \(model.undoTargetName)")
            }
            if let keys = model.blockedUndoInSection {
                BlockedUndoNotice(model: model, keys: keys)
            }
            if model.history.isEmpty {
                Text("Nothing applied yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.history) { entry in
                HistoryRow(entry: entry, isSelectedLayer: model.section == .keybindings ? entry.kind == nil : entry.kind == model.scope)
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let isSelectedLayer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.date, format: .dateTime.hour().minute().second()).font(.callout.monospacedDigit())
                Tag(text: entry.layer, symbol: "doc.text", color: isSelectedLayer ? .accentColor : .secondary)
                if entry.isNewestInLayer {
                    Tag(text: "latest", color: .accentColor)
                }
            }
            Text(entry.keys.joined(separator: ", "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct BlockedUndoNotice: View {
    let model: SettingsModel
    let keys: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Another program changed these keys since Pitot wrote them, so undo was not applied:")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(keys, id: \.self) { key in
                Text(key.joined(separator: ".")).font(.caption.monospaced())
            }
            HStack {
                Button("Force Undo") { Task { await model.undoInSection(force: true) } }
                    .accessibilityLabel("Force undo and overwrite the other program's change")
                Button("Keep") { model.dismissBlockedUndoInSection() }
                    .accessibilityLabel("Keep the file as it is")
            }
            .controlSize(.small)
            .disabled(model.isWritingInSection)
        }
        .font(.callout)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
