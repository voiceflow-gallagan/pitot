import SwiftUI

/// The keys Claude Code reads but the docs do not list. Read only: there are no controls here.
struct UnverifiedView: View {
    let model: SettingsModel

    var body: some View {
        let sections = model.unverifiedSections
        VStack(spacing: 0) {
            // No vertical fixedSize here: outside the Form it would make the window's minimum height
            // follow this text wrapped at a tiny width, which pushed the whole window content off screen.
            Label {
                Text(UnverifiedList.header)
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.top, 12)
            if sections.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
                    .frame(maxHeight: .infinity)
            } else {
                Form {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                UnverifiedRowView(row: row)
                            }
                        }
                    }
                    Section {
                        Text("Checked against the docs on \(model.unverified.researchDate), Claude Code \(model.unverified.claudeCodeVersionChecked).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Unverified")
    }
}

private struct UnverifiedRowView: View {
    let row: UnverifiedRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.name).font(.callout.monospaced().weight(.semibold)).textSelection(.enabled)
                Tag(text: row.statusLabel, color: row.statusLabel == "Not documented" ? .purple : .orange)
            }
            Text(row.description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !row.notes.isEmpty {
                Text(row.notes).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text("Seen in: \(row.seenIn)")
                Text(row.presence).foregroundStyle(row.presence.hasPrefix("Present") ? .primary : .secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
