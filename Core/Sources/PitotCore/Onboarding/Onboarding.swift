/// What onboarding would change in a settings file, before anything is written.
///
/// `changes` come from the answers and `dependencyAdditions` from the catalog's `requires` rules.
/// Every line carries the edit that makes the file hold its value, so the app can pass the
/// accepted lines straight to `SettingsFile.apply(operations:expectedHash:)`.
public struct Proposal: Sendable, Equatable {
    public struct Change: Sendable, Equatable, Identifiable {
        public enum Source: Sendable, Equatable {
            case answer(questionId: String)
            /// Added because these tweaks in the proposal need it.
            case dependency(requiredBy: [String])
        }

        public let tweakId: String
        /// Nil removes the key.
        public let value: TweakValue?
        public let source: Source
        public let reason: String
        public let operation: JSONEdit.Operation

        public var id: String { tweakId }

        public var questionId: String? {
            if case .answer(let questionId) = source { return questionId }
            return nil
        }
    }

    /// An answer's value that is not part of the proposal.
    public struct Excluded: Sendable, Equatable {
        public let tweakId: String
        public let value: TweakValue?
        public let source: Change.Source
        public let reason: String
    }

    public struct ConfirmationNeeded: Sendable, Equatable {
        public let tweakId: String
        public let message: String
    }

    public struct Dropped: Sendable, Equatable {
        public let tweakId: String
        public let reason: String
    }

    /// The lines the user kept, made consistent.
    public struct Acceptance: Sendable, Equatable {
        public let changes: [Change]
        /// Ticked lines that cannot apply without a line the user unticked.
        public let dropped: [Dropped]
        public let confirmations: [ConfirmationNeeded]

        public var operations: [JSONEdit.Operation] { changes.map(\.operation) }
    }

    /// In question order. Within a question, in the order the option lists them.
    public let changes: [Change]
    public let dependencyAdditions: [Change]
    /// Values the file already holds. Nothing is written for them.
    public let alreadySet: [Excluded]
    /// Tweaks the installed Claude Code is too old for.
    public let skipped: [Excluded]
    /// Values that fail validation or the safety rules, cannot be written to this file,
    /// or need a tweak that cannot be changed.
    public let blocked: [Excluded]
    public let confirmations: [ConfirmationNeeded]
    /// The most frequent profile among the answers. Nil when nothing was answered.
    public let presetLabel: OnboardingFile.Profile?
    public let warnings: [String]
    /// Lines with a minimum version that could not be checked because the installed version is unknown.
    public let unverifiedVersion: [String]
    public let installed: ClaudeVersion?
    let catalog: Catalog
    let document: JSONDocument

    public var all: [Change] { changes + dependencyAdditions }
    public var operations: [JSONEdit.Operation] { all.map(\.operation) }
    public var isEmpty: Bool { all.isEmpty }

    /// Keeps the ticked lines, then drops any line that cannot apply without an unticked one:
    /// a tweak whose requirement is no longer met, or an addition no kept line needs.
    /// The result is always a subset of `ids`; an unticked line is never put back.
    public func accepting(_ ids: Set<String>) -> Acceptance {
        let result = Onboarding.consistent(all.filter { ids.contains($0.tweakId) }, catalog: catalog, document: document)
        let kept = Set(result.kept.map(\.tweakId))
        return Acceptance(
            changes: result.kept,
            dropped: result.dropped.map { Dropped(tweakId: $0.change.tweakId, reason: $0.reason) },
            confirmations: confirmations.filter { kept.contains($0.tweakId) })
    }
}

public enum Onboarding {
    /// Turns answers (question id to option id) into a proposal for `document`.
    ///
    /// Later questions win over earlier ones on the same tweak. Unanswered questions change nothing.
    /// Nothing outside the answered tweaks and their catalog requirements is touched.
    public static func propose(
        _ file: OnboardingFile,
        answers: [String: String],
        catalog: Catalog,
        document: JSONDocument,
        installed: ClaudeVersion?
    ) -> Proposal {
        var builder = Builder(catalog: catalog, document: document, installed: installed)
        let chosen = builder.choose(file, answers: answers)
        builder.collect(chosen)
        builder.resolveDependencies()
        return builder.finish(profiles: chosen.map { $0.option.profile })
    }

    static func consistent(
        _ changes: [Proposal.Change],
        catalog: Catalog,
        document: JSONDocument
    ) -> (kept: [Proposal.Change], dropped: [(change: Proposal.Change, reason: String)]) {
        var kept = changes
        var dropped: [(change: Proposal.Change, reason: String)] = []
        while true {
            let byId = Dictionary(kept.map { ($0.tweakId, $0) }, uniquingKeysWith: { first, _ in first })
            let reading = { (id: String) -> TweakReading in
                if let change = byId[id] { return change.value.map(TweakReading.value) ?? .unset }
                return catalog.tweak(id: id)?.reading(in: document) ?? .unset
            }
            let removals = kept.compactMap { change -> (change: Proposal.Change, reason: String)? in
                if case .dependency(let owners) = change.source, !owners.contains(where: { byId[$0] != nil }) {
                    let titles = owners.map { catalog.tweak(id: $0)?.title ?? $0 }.joined(separator: ", ")
                    return (change, "Only needed for \(titles), which is not part of the change.")
                }
                guard let tweak = catalog.tweak(id: change.tweakId) else { return nil }
                let own = reading(change.tweakId)
                let unmet = tweak.requires.first { requirement in
                    let applies = requirement.behavior == .disable ? own.isActive : requirement.applies(toOwner: own)
                    return applies && !requirement.isSatisfied(by: reading(requirement.tweakId))
                }
                return unmet.map { (change, $0.reason) }
            }
            guard !removals.isEmpty else { return (kept, dropped) }
            let removed = Set(removals.map(\.change.tweakId))
            kept.removeAll { removed.contains($0.tweakId) }
            dropped += removals
        }
    }
}

private struct Builder {
    let catalog: Catalog
    let document: JSONDocument
    let installed: ClaudeVersion?
    var candidates: [Proposal.Change] = []
    var additions: [Proposal.Change] = []
    var alreadySet: [Proposal.Excluded] = []
    var skipped: [Proposal.Excluded] = []
    var blocked: [Proposal.Excluded] = []
    var warnings: [String] = []

    init(catalog: Catalog, document: JSONDocument, installed: ClaudeVersion?) {
        self.catalog = catalog
        self.document = document
        self.installed = installed
    }

    /// The answered options in question order. Unknown questions and options are ignored with a warning.
    mutating func choose(_ file: OnboardingFile, answers: [String: String]) -> [(question: OnboardingFile.Question, option: OnboardingFile.Option)] {
        for questionId in answers.keys.sorted() where file.question(id: questionId) == nil {
            warnings.append("Onboarding has no question \"\(questionId)\". That answer was ignored.")
        }
        return file.questions.compactMap { question in
            guard let optionId = answers[question.id] else { return nil }
            guard let option = question.option(id: optionId) else {
                warnings.append("\"\(optionId)\" is not an answer to \"\(question.title)\". That answer was ignored.")
                return nil
            }
            return (question, option)
        }
    }

    /// The last answer for each tweak, checked against the file, the rules and the installed version.
    mutating func collect(_ chosen: [(question: OnboardingFile.Question, option: OnboardingFile.Option)]) {
        var wanted: [(tweak: Tweak, value: TweakValue?, questionId: String, reason: String)] = []
        for (question, option) in chosen {
            for assignment in option.sets {
                guard let tweak = catalog.tweak(id: assignment.tweakId) else {
                    warnings.append("\"\(assignment.tweakId)\" is not in the catalog. Pitot skipped it.")
                    continue
                }
                wanted.removeAll { $0.tweak.id == tweak.id }
                wanted.append((tweak, assignment.value, question.id, "Your answer: \(option.label)"))
            }
        }
        for item in wanted {
            if let change = admit(item.tweak, value: item.value, source: .answer(questionId: item.questionId), reason: item.reason, reportAlreadySet: true) {
                candidates.append(change)
            }
        }
    }

    /// Blocks changes the dependency rules disable, then adds what the rest require.
    mutating func resolveDependencies() {
        var resolution = resolve(candidates)
        while true {
            let stopped = candidates.compactMap { change in resolution.blocked[change.tweakId].map { (change, $0) } }
            guard !stopped.isEmpty else { break }
            for (change, reason) in stopped {
                blocked.append(Proposal.Excluded(tweakId: change.tweakId, value: change.value, source: change.source, reason: reason))
            }
            candidates.removeAll { resolution.blocked[$0.tweakId] != nil }
            resolution = resolve(candidates)
        }
        for autoSet in resolution.autoSet {
            guard let tweak = catalog.tweak(id: autoSet.tweakId) else { continue }
            let owners = (candidates + additions).filter { needs($0, autoSet) }.map(\.tweakId)
            if let change = admit(tweak, value: autoSet.value, source: .dependency(requiredBy: owners), reason: autoSet.reason, reportAlreadySet: false) {
                additions.append(change)
            }
        }
    }

    func finish(profiles: [OnboardingFile.Profile]) -> Proposal {
        let result = Onboarding.consistent(candidates + additions, catalog: catalog, document: document)
        let dropped = result.dropped.map { Proposal.Excluded(tweakId: $0.change.tweakId, value: $0.change.value, source: $0.change.source, reason: $0.reason) }
        let kept = Set(result.kept.map(\.tweakId))

        var notes = warnings + resolve(result.kept).warnings
        let unverified = result.kept.compactMap { change -> Tweak? in
            guard let tweak = catalog.tweak(id: change.tweakId), VersionGate.status(tweak, installed: installed) == .unknown else { return nil }
            return tweak
        }
        if !unverified.isEmpty {
            let list = unverified.map { "\($0.title) (\($0.minVersion ?? "unknown"))" }.joined(separator: ", ")
            notes.append("Pitot could not read your Claude Code version. Check that it is recent enough for: \(list).")
        }

        return Proposal(
            changes: candidates.filter { kept.contains($0.tweakId) },
            dependencyAdditions: additions.filter { kept.contains($0.tweakId) },
            alreadySet: alreadySet,
            skipped: skipped,
            blocked: blocked + dropped,
            confirmations: result.kept.compactMap(confirmation),
            presetLabel: Self.preset(profiles),
            warnings: notes,
            unverifiedVersion: unverified.map(\.id),
            installed: installed,
            catalog: catalog,
            document: document)
    }

    /// The change for `value`, or nil after recording why it is left out.
    private mutating func admit(
        _ tweak: Tweak,
        value: TweakValue?,
        source: Proposal.Change.Source,
        reason: String,
        reportAlreadySet: Bool
    ) -> Proposal.Change? {
        let excluded = { (why: String) in Proposal.Excluded(tweakId: tweak.id, value: value, source: source, reason: why) }
        if let value, let issue = Validator.check(tweak, value: value).first {
            blocked.append(excluded(issue.message))
            return nil
        }
        if let violation = OnboardingSafety.violation(tweak, value: value) {
            blocked.append(excluded(violation))
            return nil
        }
        guard let operation = tweak.operation(for: value, in: document) else {
            if reportAlreadySet { alreadySet.append(excluded("Your settings file already has this value.")) }
            return nil
        }
        if case .needs(let version) = VersionGate.status(tweak, installed: installed) {
            let current = installed.map { " You have \($0)." } ?? ""
            skipped.append(excluded("Needs Claude Code \(version) or later.\(current)"))
            return nil
        }
        do throws(JSONEditError) {
            _ = try JSONEdit.apply(operation, to: document)
        } catch {
            blocked.append(excluded(Self.describe(error)))
            return nil
        }
        return Proposal.Change(tweakId: tweak.id, value: value, source: source, reason: reason, operation: operation)
    }

    private func resolve(_ changes: [Proposal.Change]) -> Resolution {
        Dependencies.resolve(catalog, document: document, changes: changes.map { ProposedChange(tweakId: $0.tweakId, value: $0.value) })
    }

    /// Whether `change` has an autoSet requirement that `autoSet` fulfils.
    private func needs(_ change: Proposal.Change, _ autoSet: Resolution.AutoSet) -> Bool {
        guard let tweak = catalog.tweak(id: change.tweakId) else { return false }
        let reading = change.value.map(TweakReading.value) ?? .unset
        return tweak.requires.contains {
            $0.behavior == .autoSet && $0.tweakId == autoSet.tweakId && $0.equals == autoSet.value && $0.applies(toOwner: reading)
        }
    }

    private func confirmation(_ change: Proposal.Change) -> Proposal.ConfirmationNeeded? {
        guard let tweak = catalog.tweak(id: change.tweakId), let confirm = tweak.confirm,
            Tweak.Confirmation.isRequired(for: tweak, old: tweak.reading(in: document), new: change.value)
        else { return nil }
        return Proposal.ConfirmationNeeded(tweakId: tweak.id, message: confirm.message)
    }

    /// The most frequent profile. A tie goes to the more careful one: cautious, then balanced, then power.
    private static func preset(_ profiles: [OnboardingFile.Profile]) -> OnboardingFile.Profile? {
        var best: (profile: OnboardingFile.Profile, count: Int)?
        for profile in OnboardingFile.Profile.allCases {
            let count = profiles.filter { $0 == profile }.count
            if count > (best?.count ?? 0) { best = (profile, count) }
        }
        return best?.profile
    }

    private static func describe(_ error: JSONEditError) -> String {
        switch error {
        case .notAnObject(let path):
            let place = path.isEmpty ? "The top of your settings file" : path.joined(separator: ".")
            return "\(place) is not an object in your settings file, so Pitot cannot add a key inside it."
        case .keyNotFound(let path):
            return "\(path.joined(separator: ".")) is not in your settings file."
        case .invalidJSON, .invalidRawValue, .emptyPath, .producedInvalidJSON, .notAnArray, .indexOutOfRange, .elementNotAnObject,
            .staleElementIndex:
            return "Pitot cannot edit this key in your settings file: \(error)"
        }
    }
}
