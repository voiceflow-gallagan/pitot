import Foundation
import Testing

@testable import PitotCore

@Suite("Onboarding proposal")
struct OnboardingTests {
    private typealias Samples = OnboardingSamples

    private static let focusNeedsFull = Tweak.Requirement(
        tweakId: "screen", when: "focus", equals: "full", behavior: .autoSet, reason: "Focus view needs the full screen.")
    private static let strictNeedsHelper = Tweak.Requirement(tweakId: "helper", equals: nil, behavior: .disable, reason: "Strict mode needs a helper.")

    private static func catalog(screenMinVersion: String? = nil) -> Catalog {
        Samples.catalog([
            Samples.tweak("a"),
            Samples.tweak("b"),
            Samples.tweak(
                "view", valueType: .enumeration([.init(value: "default", label: "Default"), .init(value: "focus", label: "Focus")]),
                requires: [focusNeedsFull]),
            Samples.tweak(
                "screen", valueType: .enumeration([.init(value: "classic", label: "Classic"), .init(value: "full", label: "Full")]),
                minVersion: screenMinVersion),
            Samples.tweak("helper", location: .env(name: "HELPER_MODEL"), valueType: .string),
            Samples.tweak("strict", location: .env(name: "HELPER_STRICT"), valueType: .flag, requires: [strictNeedsHelper]),
            Samples.tweak("newer", minVersion: "2.2.0"),
            Samples.tweak(
                "telemetryOff", location: .env(name: "NO_TELEMETRY"), valueType: .flag,
                confirm: Tweak.Confirmation(message: "Some features stop.", appliesWhen: .onEnable)),
        ])
    }

    private let catalog = Self.catalog()

    private func file(_ questions: OnboardingFile.Question...) -> OnboardingFile {
        OnboardingFile(questions: questions)
    }

    /// One question whose option `x` sets `sets`, and a second option that sets nothing.
    private func single(_ sets: [(String, TweakValue?)], profile: OnboardingFile.Profile = .balanced) -> OnboardingFile {
        file(Samples.question("q", Samples.option("x", profile, sets), Samples.option("keep")))
    }

    private func propose(
        _ file: OnboardingFile,
        _ answers: [String: String],
        document text: String = "{}",
        catalog: Catalog? = nil,
        installed: String? = "2.2.0"
    ) throws -> Proposal {
        Onboarding.propose(
            file, answers: answers, catalog: catalog ?? self.catalog, document: try Samples.document(text),
            installed: try installed.map(Samples.version))
    }

    // MARK: Answers to changes

    @Test func answersBecomeOrderedChangesWithTheirOperations() throws {
        let proposal = try propose(single([("b", true), ("helper", "haiku"), ("strict", true), ("a", false)]), ["q": "x"])

        #expect(Samples.lines(proposal.changes) == ["b=true", "helper=haiku", "strict=true", "a=false"])
        #expect(proposal.changes.allSatisfy { $0.source == .answer(questionId: "q") && $0.questionId == "q" })
        #expect(proposal.changes.allSatisfy { $0.reason == "Your answer: Label of x." })
        #expect(
            proposal.operations == [
                .set(path: ["b"], value: .json(true)),
                .set(path: ["env", "HELPER_MODEL"], value: .json("haiku")),
                .set(path: ["env", "HELPER_STRICT"], value: .json("1")),
                .set(path: ["a"], value: .json(false)),
            ])
    }

    @Test func laterAnswersWinOnTheSameTweak() throws {
        let file = file(
            Samples.question("first", Samples.option("x", .cautious, [("a", true), ("b", true)]), Samples.option("keep")),
            Samples.question("second", Samples.option("y", .power, [("a", false)]), Samples.option("keep")))

        let proposal = try propose(file, ["first": "x", "second": "y"])

        #expect(Samples.lines(proposal.changes) == ["b=true", "a=false"])
        #expect(proposal.changes.map(\.questionId) == ["first", "second"])
    }

    @Test func questionOrderComesFromTheFileNotTheAnswers() throws {
        let file = file(
            Samples.question("first", Samples.option("x", .cautious, [("a", true)]), Samples.option("keep")),
            Samples.question("second", Samples.option("y", .power, [("b", true)]), Samples.option("keep")))

        let proposal = try propose(file, ["second": "y", "first": "x"])

        #expect(Samples.lines(proposal.changes) == ["a=true", "b=true"])
    }

    @Test func noAnswersProposeNothing() throws {
        let proposal = try propose(single([("a", true)]), [:])

        #expect(proposal.isEmpty)
        #expect(proposal.presetLabel == nil)
        #expect(proposal.warnings.isEmpty)
    }

    @Test func anOptionThatSetsNothingKeepsTheFile() throws {
        let proposal = try propose(single([("a", true)]), ["q": "keep"], document: #"{"a": false}"#)

        #expect(proposal.isEmpty)
        #expect(proposal.presetLabel == .balanced)
    }

    @Test func valuesTheFileAlreadyHoldsAreListedApart() throws {
        let proposal = try propose(single([("a", true), ("b", true), ("helper", nil), ("strict", false)]), ["q": "x"], document: #"{"a": true}"#)

        #expect(Samples.lines(proposal.changes) == ["b=true"])
        #expect(Samples.lines(proposal.alreadySet) == ["a=true", "helper=unset", "strict=false"])
    }

    @Test func removingAKeyTheFileHoldsIsAChange() throws {
        let document = #"{"env": {"HELPER_MODEL": "opus", "HELPER_STRICT": "0"}}"#

        let proposal = try propose(single([("helper", nil), ("strict", false)]), ["q": "x"], document: document)

        #expect(Samples.lines(proposal.changes) == ["helper=unset", "strict=false"])
        #expect(proposal.operations == [.remove(path: ["env", "HELPER_MODEL"]), .remove(path: ["env", "HELPER_STRICT"])])
    }

    @Test func unknownAnswersAndTweaksAreIgnoredWithAWarning() throws {
        let proposal = try propose(single([("a", true), ("missing", true)]), ["q": "x", "nope": "x", "other": "y"])

        #expect(Samples.lines(proposal.changes) == ["a=true"])
        #expect(proposal.warnings.count == 3)
        #expect(try propose(single([("a", true)]), ["q": "zzz"]).warnings.count == 1)
    }

    @Test func invalidValuesAreBlocked() throws {
        let proposal = try propose(single([("a", "yes"), ("helper", " ")]), ["q": "x"])

        #expect(proposal.all.isEmpty)
        #expect(proposal.blocked.map(\.tweakId) == ["a", "helper"])
    }

    @Test func editsThatCannotApplyToTheFileAreBlocked() throws {
        let proposal = try propose(single([("helper", "haiku"), ("a", true)]), ["q": "x"], document: #"{"env": "text"}"#)

        #expect(Samples.lines(proposal.changes) == ["a=true"])
        #expect(proposal.blocked.map(\.tweakId) == ["helper"])
        #expect(proposal.blocked.first?.reason.contains("env") == true)
    }

    // MARK: Dependencies

    @Test func focusAddsItsRequirementWithTheReason() throws {
        let proposal = try propose(single([("view", "focus")]), ["q": "x"])

        #expect(Samples.lines(proposal.changes) == ["view=focus"])
        #expect(Samples.lines(proposal.dependencyAdditions) == ["screen=full"])
        let addition = try #require(proposal.dependencyAdditions.first)
        #expect(addition.source == .dependency(requiredBy: ["view"]))
        #expect(addition.questionId == nil)
        #expect(addition.reason == "Focus view needs the full screen.")
        #expect(addition.operation == .set(path: ["screen"], value: .json("full")))
    }

    @Test func noAdditionWhenTheFileAlreadyMeetsTheRequirement() throws {
        #expect(try propose(single([("view", "focus")]), ["q": "x"], document: #"{"screen": "full"}"#).dependencyAdditions.isEmpty)
    }

    @Test func aConflictingAnswerDropsTheDependent() throws {
        let proposal = try propose(single([("view", "focus"), ("screen", "classic")]), ["q": "x"])

        #expect(Samples.lines(proposal.changes) == ["screen=classic"])
        #expect(proposal.dependencyAdditions.isEmpty)
        #expect(proposal.blocked.map(\.tweakId) == ["view"])
        #expect(proposal.blocked.first?.reason == "Focus view needs the full screen.")
    }

    @Test func aDisabledTweakIsBlockedUntilItsRequirementIsMet() throws {
        let alone = try propose(single([("strict", true)]), ["q": "x"])
        let together = try propose(single([("helper", "haiku"), ("strict", true)]), ["q": "x"])
        let inFile = try propose(single([("strict", true)]), ["q": "x"], document: #"{"env": {"HELPER_MODEL": "opus"}}"#)

        #expect(alone.all.isEmpty)
        #expect(alone.blocked.map(\.tweakId) == ["strict"])
        #expect(alone.blocked.first?.reason == "Strict mode needs a helper.")
        #expect(Samples.lines(together.changes) == ["helper=haiku", "strict=true"])
        #expect(Samples.lines(inFile.changes) == ["strict=true"])
    }

    // MARK: Versions

    @Test func tweaksAboveTheInstalledVersionAreSkipped() throws {
        let proposal = try propose(single([("newer", true), ("a", true)]), ["q": "x"], installed: "2.1.300")

        #expect(Samples.lines(proposal.changes) == ["a=true"])
        #expect(Samples.lines(proposal.skipped) == ["newer=true"])
        #expect(proposal.skipped.first?.reason == "Needs Claude Code 2.2.0 or later. You have 2.1.300.")
        #expect(proposal.unverifiedVersion.isEmpty)
        #expect(proposal.warnings.isEmpty)
    }

    @Test func anUnknownVersionSkipsNothingButWarns() throws {
        let proposal = try propose(single([("newer", true), ("a", true)]), ["q": "x"], installed: nil)

        #expect(Samples.lines(proposal.changes) == ["newer=true", "a=true"])
        #expect(proposal.skipped.isEmpty)
        #expect(proposal.unverifiedVersion == ["newer"])
        #expect(proposal.warnings == ["Pitot could not read your Claude Code version. Check that it is recent enough for: Title of newer (2.2.0)."])
    }

    @Test func anUnknownVersionIsQuietWhenNoChangeNeedsAVersion() throws {
        let proposal = try propose(single([("a", true)]), ["q": "x"], installed: nil)

        #expect(proposal.unverifiedVersion.isEmpty)
        #expect(proposal.warnings.isEmpty)
    }

    @Test func aSkippedRequirementDropsItsDependent() throws {
        let proposal = try propose(single([("view", "focus"), ("a", true)]), ["q": "x"], catalog: Self.catalog(screenMinVersion: "2.3.0"))

        #expect(Samples.lines(proposal.changes) == ["a=true"])
        #expect(proposal.dependencyAdditions.isEmpty)
        #expect(Samples.lines(proposal.skipped) == ["screen=full"])
        #expect(Samples.lines(proposal.blocked) == ["view=focus"])
    }

    // MARK: Confirmations and preset label

    @Test func confirmationsListOnlyChangesThatTriggerThem() throws {
        let fresh = try propose(single([("telemetryOff", true), ("a", true)]), ["q": "x"])
        let alreadyOff = try propose(single([("telemetryOff", true)]), ["q": "x"], document: #"{"env": {"NO_TELEMETRY": "1"}}"#)

        #expect(fresh.confirmations == [Proposal.ConfirmationNeeded(tweakId: "telemetryOff", message: "Some features stop.")])
        #expect(alreadyOff.confirmations.isEmpty)
    }

    /// Shaped like `sandbox.enabled`: off by default, with a confirm when it turns off. The real row
    /// cannot be used here because the safety rules block onboarding from removing it.
    @Test func removingAKeyThatFallsBackToOffNeedsTheConfirmation() throws {
        let guardRow = Samples.tweak(
            "guard", defaultValue: false, confirm: Tweak.Confirmation(message: "Commands run unguarded.", appliesWhen: .onDisable))
        let catalog = Samples.catalog([guardRow])

        let removed = try propose(single([("guard", nil)]), ["q": "x"], document: #"{"guard": true}"#, catalog: catalog)
        let turnedOn = try propose(single([("guard", true)]), ["q": "x"], document: #"{"guard": false}"#, catalog: catalog)

        #expect(Samples.lines(removed.changes) == ["guard=unset"])
        #expect(removed.confirmations == [Proposal.ConfirmationNeeded(tweakId: "guard", message: "Commands run unguarded.")])
        #expect(turnedOn.confirmations.isEmpty)
    }

    @Test func theRealSandboxIsNeverRemovedSoItsConfirmationNeverShows() throws {
        let catalog = try Samples.realCatalog()
        let sandbox = try #require(catalog.tweak(id: "sandbox.enabled"))
        let document = try Samples.document(#"{"sandbox": {"enabled": true}}"#)

        let proposal = Onboarding.propose(
            single([("sandbox.enabled", nil)]), answers: ["q": "x"], catalog: catalog, document: document, installed: nil)

        #expect(Tweak.Confirmation.isRequired(for: sandbox, old: sandbox.reading(in: document), new: nil))
        #expect(proposal.all.isEmpty)
        #expect(proposal.blocked.map(\.tweakId) == ["sandbox.enabled"])
    }

    @Test(
        "the preset label is the most frequent profile, ties go to the more careful one",
        arguments: [
            ([OnboardingFile.Profile.power, .power, .cautious], OnboardingFile.Profile?.some(.power)),
            ([.power, .cautious], .cautious),
            ([.power, .balanced], .balanced),
            ([.balanced, .cautious, .power], .cautious),
            ([.balanced, .balanced, .power, .power, .cautious], .balanced),
            ([], nil),
        ])
    func presetLabel(profiles: [OnboardingFile.Profile], expected: OnboardingFile.Profile?) throws {
        let questions = profiles.indices.map { index in
            Samples.question("q\(index)", Samples.option("x", profiles[index]), Samples.option("y", profiles[index]))
        }
        let answers = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, "x") })

        #expect(try propose(OnboardingFile(questions: questions), answers).presetLabel == expected)
    }

    // MARK: Accepting a subset

    @Test func acceptingEverythingKeepsEverything() throws {
        let proposal = try propose(single([("view", "focus"), ("telemetryOff", true)]), ["q": "x"])

        let acceptance = proposal.accepting(Set(proposal.all.map(\.tweakId)))

        #expect(acceptance.changes == proposal.all)
        #expect(acceptance.dropped.isEmpty)
        #expect(acceptance.operations == proposal.operations)
        #expect(acceptance.confirmations == proposal.confirmations)
    }

    @Test func untickingARequirementDropsItsDependent() throws {
        let proposal = try propose(single([("view", "focus"), ("a", true)]), ["q": "x"])

        let acceptance = proposal.accepting(["view", "a"])

        #expect(Samples.lines(acceptance.changes) == ["a=true"])
        #expect(acceptance.dropped == [Proposal.Dropped(tweakId: "view", reason: "Focus view needs the full screen.")])
    }

    @Test func untickingTheDependentDropsItsAddition() throws {
        let proposal = try propose(single([("view", "focus"), ("a", true)]), ["q": "x"])

        let acceptance = proposal.accepting(["screen", "a"])

        #expect(Samples.lines(acceptance.changes) == ["a=true"])
        #expect(acceptance.dropped == [Proposal.Dropped(tweakId: "screen", reason: "Only needed for Title of view, which is not part of the change.")])
    }

    @Test func untickingAHelperDropsTheTweakThatNeedsIt() throws {
        let proposal = try propose(single([("helper", "haiku"), ("strict", true)]), ["q": "x"])
        let withHelperInFile = try propose(single([("helper", "haiku"), ("strict", true)]), ["q": "x"], document: #"{"env": {"HELPER_MODEL": "opus"}}"#)

        #expect(proposal.accepting(["strict"]).changes.isEmpty)
        #expect(proposal.accepting(["strict"]).dropped == [Proposal.Dropped(tweakId: "strict", reason: "Strict mode needs a helper.")])
        #expect(Samples.lines(withHelperInFile.accepting(["strict"]).changes) == ["strict=true"])
    }

    @Test func acceptingIsASubsetThatNeedsNoFurtherDrops() throws {
        let proposal = try propose(single([("view", "focus"), ("helper", "haiku"), ("strict", true), ("a", true), ("telemetryOff", true)]), ["q": "x"])
        let ids = proposal.all.map(\.tweakId)
        var generator = SplitMix64(seed: 7)
        for _ in 0..<200 {
            let ticked = Set(ids.filter { _ in Bool.random(using: &generator) })

            let acceptance = proposal.accepting(ticked)

            let kept = acceptance.changes.map(\.tweakId)
            #expect(Set(kept).isSubset(of: ticked))
            #expect(kept == ids.filter(Set(kept).contains))
            #expect(Set(kept).union(acceptance.dropped.map(\.tweakId)) == ticked)
            #expect(proposal.accepting(Set(kept)).changes == acceptance.changes)
            #expect(acceptance.confirmations.allSatisfy { kept.contains($0.tweakId) })
        }
        #expect(proposal.accepting([]).changes.isEmpty)
    }

    @Test func acceptedOperationsApplyAsOneWrite() throws {
        let directory = try TemporaryDirectory()
        let url = try directory.write("settings.json", "{\n  \"keep\": {\"me\": [1, 2e3]},\n  \"a\": false\n}\n")
        let settings = SettingsFile(url: url, backupRoot: directory.file("Backups"))
        let snapshot = try settings.load()
        let proposal = Onboarding.propose(
            single([("a", true), ("view", "focus"), ("helper", "haiku"), ("strict", true)]), answers: ["q": "x"], catalog: catalog,
            document: snapshot.document, installed: try Samples.version("2.2.0"))

        let acceptance = proposal.accepting(["a", "view", "screen", "strict"])
        let result = try settings.apply(operations: acceptance.operations, expectedHash: snapshot.hash)

        #expect(acceptance.dropped.map(\.tweakId) == ["strict"])
        let number = try #require(JSONNumber(text: "2e3"))
        #expect(result.snapshot.document.value(at: ["keep"]) == .object([JSONValue.Member(key: "me", value: [1, .number(number)])]))
        #expect(result.snapshot.document.value(at: ["a"]) == true)
        #expect(result.snapshot.document.value(at: ["view"]) == "focus")
        #expect(result.snapshot.document.value(at: ["screen"]) == "full")
        #expect(result.snapshot.document.value(at: ["env"]) == nil)
    }
}
