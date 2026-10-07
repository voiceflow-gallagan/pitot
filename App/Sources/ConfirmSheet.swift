import PitotCore
import SwiftUI

/// Asks before a risky change goes ahead. Cancel leaves everything as it was.
struct ConfirmSheet: View {
    let request: ConfirmRequest
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Confirm this change", systemImage: "exclamationmark.shield")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            Text(request.headline)
                .font(.headline)
            Text(request.message)
                .fixedSize(horizontal: false, vertical: true)
            Text(request.detail)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Confirm", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Confirm this change")
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
