import PitotCore
import Foundation
import Observation

/// One line of the proposal as the review step shows it.
struct ProposalLine: Identifiable, Equatable {
    let id: String
    let title: String
    let key: String
    /// "old → new", or the "Also turning on X because Y" text for a dependency addition.
    let summary: String
    let reason: String
    let risks: Set<Tweak.Risk>
    let isDependency: Bool
    /// What the checkbox shows: false when the user unticked the line or it was removed with another line.
    let isTicked: Bool
    /// Set when the user kept the line but it cannot apply without a line the user unticked.
    /// It comes back by itself when that line is ticked again.
    let removedBecause: String?
    let needsConfirm: Bool
}

/// An answer's value that is not part of the proposal, with the reason.
struct ExcludedLine: Identifiable, Equatable {
    let id: String
    let text: String
    let reason: String
}

/// The setup questions: one answer per question, then a proposal the user trims before one write.
@MainActor
@Observable
final class OnboardingModel: Identifiable {
    let file: OnboardingFile
    private let settings: SettingsModel

    private(set) var step = 0
    /// Question id to option id.
    private(set) var answers: [String: String] = [:]
    private(set) var skipped: Set<String> = []
    private(set) var proposal: Proposal?
    /// The file the proposal was made from. Apply passes its hash, so a newer file is rebased.
    private(set) var basis: SettingsSnapshot?
    private(set) var unticked: Set<String> = []
    private(set) var acceptance: Proposal.Acceptance?
    private(set) var diff: [DiffLine] = []
    private(set) var previewError: String?
    private(set) var isApplying = false
    var confirmRequest: ConfirmRequest?
    private var confirmQueue: [ConfirmRequest] = []

    init(file: OnboardingFile, settings: SettingsModel) {
        self.file = file
        self.settings = settings
    }

    var isReviewing: Bool { step >= file.questions.count }
    var question: OnboardingFile.Question? { isReviewing ? nil : file.questions[step] }
    var canGoBack: Bool { step > 0 && !isApplying }

    var canGoNext: Bool {
        guard let question else { return false }
        return answers[question.id] != nil || skipped.contains(question.id)
    }

    var canApply: Bool {
        guard let acceptance, !acceptance.changes.isEmpty else { return false }
        return previewError == nil && !isApplying && !settings.isWriting
    }

    // MARK: Questions

    func choose(_ option: OnboardingFile.Option) {
        guard let question else { return }
        answers[question.id] = option.id
        skipped.remove(question.id)
    }

    /// Keeps the current settings for this question and moves on.
    func skip() {
        guard let question else { return }
        answers[question.id] = nil
        skipped.insert(question.id)
        next()
    }

    func next() {
        guard canGoNext else { return }
        step += 1
        if isReviewing { refreshProposal() }
    }

    func back() {
        guard canGoBack else { return }
        step -= 1
    }

    // MARK: Proposal

    /// Rebuilds the proposal from the file as it is now. Unticked lines stay unticked.
    func refreshProposal() {
        guard let snapshot = settings.user.snapshot else { return }
        basis = snapshot
        proposal = Onboarding.propose(file, answers: answers, catalog: settings.catalog, document: snapshot.document, installed: settings.claude.version)
        updateAcceptance()
    }

    func isTicked(_ tweakId: String) -> Bool {
        !unticked.contains(tweakId)
    }

    func setTicked(_ ticked: Bool, tweakId: String) {
        if ticked {
            unticked.remove(tweakId)
        } else {
            unticked.insert(tweakId)
        }
        updateAcceptance()
    }

    var lines: [ProposalLine] {
        guard let proposal, let document = basis?.document else { return [] }
        let removed = Dictionary((acceptance?.dropped ?? []).map { ($0.tweakId, $0.reason) }, uniquingKeysWith: { first, _ in first })
        let confirmIds = Set(proposal.confirmations.map(\.tweakId))
        return proposal.all.compactMap { change in
            guard let tweak = settings.catalog.tweak(id: change.tweakId) else { return nil }
            let isDependency = change.questionId == nil
            let summary =
                isDependency
                ? ReviewPlan.autoSetText(tweak, value: change.value, reason: change.reason)
                : ReviewPlan.changeText(tweak, from: tweak.reading(in: document), to: change.value, in: document)
            let removedBecause = isTicked(tweak.id) ? removed[tweak.id] : nil
            return ProposalLine(
                id: tweak.id, title: tweak.title, key: tweak.keyText, summary: summary, reason: change.reason, risks: tweak.risks,
                isDependency: isDependency, isTicked: isTicked(tweak.id) && removedBecause == nil, removedBecause: removedBecause,
                needsConfirm: confirmIds.contains(tweak.id))
        }
    }

    var skippedLines: [ExcludedLine] { excluded(proposal?.skipped ?? []) }
    var blockedLines: [ExcludedLine] { excluded(proposal?.blocked ?? []) }

    private func excluded(_ items: [Proposal.Excluded]) -> [ExcludedLine] {
        items.map { item in
            let tweak = settings.catalog.tweak(id: item.tweakId)
            let text = tweak.map { "\($0.title): \($0.label(for: item.value))" } ?? item.tweakId
            return ExcludedLine(id: item.tweakId, text: text, reason: item.reason)
        }
    }

    private func updateAcceptance() {
        guard let proposal, let basis else { return }
        let accepted = proposal.accepting(Set(proposal.all.map(\.tweakId)).subtracting(unticked))
        acceptance = accepted
        (diff, previewError) = ReviewPlan.preview(accepted.operations, over: basis.bytes)
    }

    // MARK: Apply

    /// Asks each confirmation the kept lines need, in order, then writes them as one group.
    func apply() async {
        guard canApply, let acceptance else { return }
        confirmQueue = acceptance.confirmations.compactMap { needed in
            guard let tweak = settings.catalog.tweak(id: needed.tweakId) else { return nil }
            let value = acceptance.changes.first { $0.tweakId == needed.tweakId }?.value
            return ConfirmRequest.change(tweak, value: value, message: needed.message)
        }
        await continueApplying()
    }

    func confirm() async {
        confirmRequest = nil
        await continueApplying()
    }

    /// Stops the apply. Nothing is written and the lines stay as they are.
    func cancelConfirmation() {
        confirmQueue = []
        confirmRequest = nil
    }

    private func continueApplying() async {
        if !confirmQueue.isEmpty {
            confirmRequest = confirmQueue.removeFirst()
            return
        }
        guard let acceptance, let basis else { return }
        isApplying = true
        defer { isApplying = false }
        if await settings.write(acceptance.operations, to: settings.user, expectedHash: basis.hash) {
            settings.finishOnboarding()
        }
    }
}
