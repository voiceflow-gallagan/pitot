import PitotCore
import SwiftUI

/// The proposal: one checkbox per change, the lines left out, and the diff of the ticked lines.
struct OnboardingProposalStep: View {
    let onboarding: OnboardingModel

    var body: some View {
        let lines = onboarding.lines
        VStack(alignment: .leading, spacing: 16) {
            if let preset = onboarding.proposal?.presetLabel {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preset: \(preset.title)").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    Text(lines.isEmpty ? "Based on your answers." : "Based on your answers. Untick any line you do not want.")
                        .foregroundStyle(.secondary)
                }
            }
            if lines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing to change").font(.title3.bold())
                    Text("Your settings file already matches these answers.").foregroundStyle(.secondary)
                }
            } else {
                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            if index > 0 { Divider() }
                            ProposalLineRow(onboarding: onboarding, line: line)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
            ExcludedSection(title: "Skipped: needs a newer Claude Code", lines: onboarding.skippedLines)
            ExcludedSection(title: "Not changed", lines: onboarding.blockedLines)
            ForEach(Array((onboarding.proposal?.warnings ?? []).enumerated()), id: \.offset) { _, warning in
                Label {
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .font(.callout)
            }
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Changes to settings.json").font(.headline).accessibilityAddTraits(.isHeader)
                    if let error = onboarding.previewError {
                        Text(error).foregroundStyle(.red)
                    } else if onboarding.diff.isEmpty {
                        Text("No line is ticked.").foregroundStyle(.secondary)
                    } else {
                        DiffView(lines: onboarding.diff)
                    }
                }
            }
        }
    }
}

private struct ProposalLineRow: View {
    let onboarding: OnboardingModel
    let line: ProposalLine

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(line.title, isOn: Binding(get: { line.isTicked }, set: { onboarding.setTicked($0, tweakId: line.id) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(onboarding.isApplying || line.removedBecause != nil)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(line.title).font(.headline)
                    RiskBadges(risks: line.risks)
                    if line.needsConfirm {
                        Tag(text: "will ask to confirm", symbol: "exclamationmark.shield", color: .orange)
                            .accessibilityLabel("Will ask you to confirm before writing")
                    }
                }
                Text(line.key).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text(line.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                if !line.isDependency {
                    Text(line.reason).font(.caption).foregroundStyle(.secondary)
                }
                if let removed = line.removedBecause {
                    Label("Also removed because \(removed.lowercasedFirst)", systemImage: "minus.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(line.isTicked ? 1 : 0.5)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

private struct ExcludedSection: View {
    let title: String
    let lines: [ExcludedLine]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.secondary)
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.text).font(.callout)
                        Text(line.reason).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
