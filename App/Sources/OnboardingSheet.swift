import PitotCore
import SwiftUI

/// The setup questions: seven steps, then the proposal. Nothing is written before Apply.
struct OnboardingSheet: View {
    @Bindable var onboarding: OnboardingModel
    let settings: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    if let question = onboarding.question {
                        OnboardingQuestionStep(onboarding: onboarding, question: question)
                    } else {
                        OnboardingProposalStep(onboarding: onboarding)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if onboarding.isReviewing, let message = settings.errorMessage {
                Banner(symbol: "xmark.octagon.fill", color: .red, text: message) { settings.errorMessage = nil }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 620)
        .sheet(item: $onboarding.confirmRequest) { request in
            ConfirmSheet(request: request, onConfirm: { Task { await onboarding.confirm() } }, onCancel: { onboarding.cancelConfirmation() })
        }
        .onChange(of: settings.user.snapshot?.hash) {
            if onboarding.isReviewing, !onboarding.isApplying { onboarding.refreshProposal() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Setup questions", systemImage: "wand.and.stars").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(stepText).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(onboarding.step), total: Double(onboarding.file.questions.count))
                .accessibilityLabel("Progress")
                .accessibilityValue(stepText)
        }
        .padding(20)
    }

    private var stepText: String {
        onboarding.isReviewing ? "Review" : "Question \(onboarding.step + 1) of \(onboarding.file.questions.count)"
    }

    private var footer: some View {
        HStack {
            Button(onboarding.isReviewing && onboarding.proposal?.isEmpty == true ? "Close" : "Cancel", role: .cancel) {
                settings.finishOnboarding()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(onboarding.isApplying)
            Spacer()
            Button("Back") { onboarding.back() }
                .disabled(!onboarding.canGoBack)
            if onboarding.isReviewing {
                Button("Apply") { Task { await onboarding.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!onboarding.canApply)
                    .accessibilityLabel("Apply the ticked changes in one write")
            } else {
                Button(onboarding.step + 1 == onboarding.file.questions.count ? "Review" : "Next") { onboarding.next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!onboarding.canGoNext)
            }
        }
        .padding(16)
    }
}

private struct OnboardingQuestionStep: View {
    let onboarding: OnboardingModel
    let question: OnboardingFile.Question

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            if let hint = question.hint {
                Text(hint).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(question.options) { option in
                OptionCard(option: option, isSelected: onboarding.answers[question.id] == option.id) { onboarding.choose(option) }
            }
            HStack(spacing: 8) {
                Button("Skip this question") { onboarding.skip() }
                    .buttonStyle(.link)
                    .accessibilityHint("Keeps your current settings for this question")
                Text(onboarding.skipped.contains(question.id) ? "Skipped. Your current settings stay." : "Keeps your current settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }
}

private struct OptionCard: View {
    let option: OnboardingFile.Option
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label).font(.headline)
                    if let hint = option.hint {
                        Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityHint(option.hint ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
