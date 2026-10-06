import Foundation
import Testing

@testable import PitotCore

@Suite("Catalog loader")
struct CatalogLoaderTests {
    private func rules(_ tweaks: [Tweak]) -> [LintIssue.Rule] {
        CatalogLinter.lint(CatalogSamples.catalog(tweaks)).map(\.rule)
    }

    private func tweak(
        _ id: String,
        location: Tweak.Location? = nil,
        valueType: Tweak.ValueType = .bool,
        defaultDescription: String = "Unset",
        requires: [Tweak.Requirement] = []
    ) -> Tweak {
        CatalogSamples.tweak(id, location: location, valueType: valueType, defaultDescription: defaultDescription, requires: requires)
    }

    @Test func sampleCatalogLintsClean() throws {
        let catalog = try CatalogLoader.decode(data: Data(CatalogSamples.json.utf8))

        #expect(CatalogLinter.lint(catalog) == [])
    }

    @Test func loadRejectsACatalogWithLintIssues() throws {
        let catalog = CatalogSamples.catalog([tweak("a"), tweak("a")])
        let data = try JSONEncoder().encode(catalog)

        #expect(throws: CatalogError.lintFailed(CatalogLinter.lint(catalog))) {
            try CatalogLoader.load(data: data)
        }
    }

    @Test func idsAreUnique() {
        #expect(rules([tweak("a"), tweak("b", location: .setting(path: ["other"])), tweak("a", location: .setting(path: ["third"]))]) == [.duplicateId])
    }

    @Test func twoRowsCannotWriteTheSameKey() {
        #expect(rules([tweak("a", location: .setting(path: ["tui"])), tweak("b", location: .setting(path: ["tui"]))]) == [.duplicateLocation])
    }

    @Test func locationKeysAreNotEmpty() {
        #expect(rules([tweak("a", location: .setting(path: []))]) == [.emptyLocation])
        #expect(rules([tweak("b", location: .setting(path: ["sandbox", ""]))]) == [.emptyLocation])
        #expect(rules([tweak("c", location: .env(name: ""))]) == [.emptyLocation])
    }

    @Test func everyRowHasADocURL() {
        #expect(rules([CatalogSamples.tweak("a", docURL: "")]) == [.invalidDocURL])
    }

    @Test(
        "doc links point at the Claude Code docs",
        arguments: [
            "http://code.claude.com/docs/en/settings", "https://docs.anthropic.com/en/settings", "https://code.claude.com/doc", "code.claude.com/docs/en",
        ])
    func docURLPointsAtClaudeCodeDocs(url: String) {
        #expect(rules([CatalogSamples.tweak("a", docURL: url)]) == [.invalidDocURL])
    }

    @Test("only documented rows ship", arguments: [Tweak.Status.hidden, .unverified])
    func onlyDocumentedRows(status: Tweak.Status) {
        #expect(rules([CatalogSamples.tweak("a", status: status)]) == [.notDocumented])
    }

    @Test func enumNeedsTwoOptions() {
        #expect(rules([tweak("a", valueType: .enumeration([Tweak.Option(value: "x", label: "X")]))]) == [.enumTooFewOptions])
    }

    @Test func enumValuesAreUnique() {
        let options = [Tweak.Option(value: "x", label: "X"), Tweak.Option(value: "x", label: "Also X")]
        #expect(rules([tweak("a", valueType: .enumeration(options))]) == [.enumDuplicateValue])
    }

    @Test func integerMinimumIsNotAboveMaximum() {
        #expect(rules([tweak("a", valueType: .integer(min: 10, max: 1))]) == [.integerRangeInverted])
        #expect(rules([tweak("b", valueType: .integer(min: 5, max: 5))]) == [])
        #expect(rules([tweak("c", valueType: .integer(min: nil, max: 5))]) == [])
    }

    @Test(
        "user-only keys are marked userOnly",
        arguments: [
            Tweak.Location.setting(path: ["askUserQuestionTimeout"]), .setting(path: ["sandbox", "filesystem", "disabled"]),
            .setting(path: ["spellcheck", "enabled"]), .env(name: "CLAUDE_CODE_ENABLE_TELEMETRY"), .env(name: "OTEL_EXPORTER_OTLP_ENDPOINT"),
            .env(name: "OTEL_METRICS_EXPORTER"),
        ])
    func userOnlyKeysAreMarked(location: Tweak.Location) {
        #expect(rules([tweak("a", location: location)]) == [.userOnlyNotMarked])
        #expect(rules([CatalogSamples.tweak("a", location: location, scope: .userOnly)]) == [])
    }

    @Test func anyScopeKeyNeedsNoMark() {
        #expect(!CatalogLinter.isUserOnly(.setting(path: ["sandbox", "enabled"])))
        #expect(!CatalogLinter.isUserOnly(.env(name: "DISABLE_TELEMETRY")))
    }

    @Test func flagsAreEnvVarsOnly() {
        #expect(rules([tweak("a", location: .setting(path: ["a"]), valueType: .flag)]) == [.flagNotEnv])
        #expect(rules([tweak("b", location: .env(name: "B"), valueType: .flag)]) == [])
    }

    @Test("a fixed string has a value", arguments: ["", " "])
    func fixedStringHasAValue(value: String) {
        #expect(rules([tweak("a", valueType: .fixedString(value))]) == [.emptyFixedString])
    }

    @Test func fixedStringFitsAnyLocation() {
        #expect(rules([tweak("a", valueType: .fixedString("disable")), tweak("b", location: .env(name: "B"), valueType: .fixedString("on"))]) == [])
    }

    @Test func requirementOnAFixedStringUsesOnOff() {
        let fixed = tweak("fixed", valueType: .fixedString("disable"))
        let byText = tweak("a", requires: [Tweak.Requirement(tweakId: "fixed", equals: "disable", behavior: .disable, reason: "r")])
        let byOn = tweak("b", requires: [Tweak.Requirement(tweakId: "fixed", equals: true, behavior: .disable, reason: "r")])

        #expect(rules([fixed, byText]) == [.invalidRequirementValue])
        #expect(rules([fixed, byOn]) == [])
    }

    @Test("a flag never defaults to 0", arguments: ["0", "\"0\"", "0 (off)"])
    func flagNeverDefaultsToZero(text: String) {
        #expect(rules([tweak("a", location: .env(name: "A"), valueType: .flag, defaultDescription: text)]) == [.flagDefaultsToZero])
    }

    @Test func requirementsPointAtRealRows() {
        let requirement = Tweak.Requirement(tweakId: "missing", equals: true, behavior: .disable, reason: "r")

        #expect(rules([tweak("a", requires: [requirement])]) == [.unknownRequirement])
    }

    @Test func requirementsDoNotLoop() {
        let a = tweak("a", requires: [Tweak.Requirement(tweakId: "b", equals: true, behavior: .autoSet, reason: "r")])
        let b = tweak("b", requires: [Tweak.Requirement(tweakId: "c", equals: true, behavior: .autoSet, reason: "r")])
        let c = tweak("c", requires: [Tweak.Requirement(tweakId: "a", equals: true, behavior: .disable, reason: "r")])

        let issues = CatalogLinter.lint(CatalogSamples.catalog([c, b, a]))

        #expect(issues == [LintIssue(rule: .requirementCycle, tweakId: "a", detail: "requirements form a loop: a -> b -> c -> a")])
    }

    @Test func aRowCannotRequireItself() {
        let a = tweak("a", requires: [Tweak.Requirement(tweakId: "a", equals: true, behavior: .disable, reason: "r")])

        #expect(rules([a]) == [.requirementCycle])
    }

    @Test func chainsWithoutLoopsAreFine() {
        let a = tweak("a", requires: [Tweak.Requirement(tweakId: "b", equals: true, behavior: .autoSet, reason: "r")])
        let b = tweak("b", requires: [Tweak.Requirement(tweakId: "c", equals: true, behavior: .autoSet, reason: "r")])
        let d = tweak("d", requires: [Tweak.Requirement(tweakId: "c", equals: true, behavior: .disable, reason: "r")])

        #expect(rules([a, b, tweak("c"), d]) == [])
    }

    @Test func autoSetNeedsAValue() {
        let a = tweak("a", requires: [Tweak.Requirement(tweakId: "b", equals: nil, behavior: .autoSet, reason: "r")])

        #expect(rules([a, tweak("b")]) == [.autoSetWithoutValue])
    }

    @Test func disableAppliesToTheWholeRow() {
        let a = tweak("a", requires: [Tweak.Requirement(tweakId: "b", when: true, equals: true, behavior: .disable, reason: "r")])

        #expect(rules([a, tweak("b")]) == [.disableWithCondition])
    }

    @Test func requirementValuesFitTheirRows() {
        let flag = tweak("flag", location: .env(name: "FLAG"), valueType: .flag)
        let setsZero = tweak("a", requires: [Tweak.Requirement(tweakId: "flag", equals: "0", behavior: .autoSet, reason: "r")])
        let badWhen = tweak("b", requires: [Tweak.Requirement(tweakId: "flag", when: "yes", equals: true, behavior: .autoSet, reason: "r")])

        #expect(rules([flag, setsZero]) == [.invalidRequirementValue])
        #expect(rules([flag, badWhen]) == [.invalidRequirementValue])
    }

    @Test("minVersion is a plain version", arguments: ["v2.1.257", "2.1", "2.1.257 (Claude Code)", "2.1.257+build", "latest"])
    func minVersionParses(text: String) {
        #expect(rules([CatalogSamples.tweak("a", minVersion: text)]) == [.invalidVersion])
    }

    @Test func checkedVersionParses() {
        var catalog = CatalogSamples.catalog([tweak("a")])
        catalog.claudeCodeVersionChecked = "2.1"

        #expect(CatalogLinter.lint(catalog).map(\.rule) == [.invalidVersion])
    }

    @Test func confirmNeedsAMessage() {
        let confirm = Tweak.Confirmation(message: "  ", appliesWhen: .onEnable)

        #expect(rules([CatalogSamples.tweak("a", confirm: confirm)]) == [.emptyConfirmMessage])
    }

    @Test func confirmValueFitsTheRow() {
        let confirm = Tweak.Confirmation(message: "Sure?", appliesWhen: .whenValue("split"))
        let options = [Tweak.Option(value: "default", label: "Classic"), Tweak.Option(value: "fullscreen", label: "Fullscreen")]

        #expect(rules([CatalogSamples.tweak("a", valueType: .enumeration(options), confirm: confirm)]) == [.invalidConfirmValue])
    }

    @Test func defaultValueFitsTheRow() {
        var tweak = CatalogSamples.tweak("a")
        tweak.defaultValue = "yes"

        #expect(rules([tweak]) == [.invalidDefaultValue])
        tweak.defaultValue = false
        #expect(rules([tweak]) == [])
    }

    @Test func userOnlyValuesNeedAnEnumRow() {
        var tweak = CatalogSamples.tweak("a", valueType: .string)
        tweak.userOnlyValues = ["x"]

        #expect(rules([tweak]) == [.userOnlyValuesNotEnum])
    }

    @Test func userOnlyValuesAreOptions() {
        let options = [Tweak.Option(value: "default", label: "Default"), Tweak.Option(value: "bypassPermissions", label: "Bypass")]
        var tweak = CatalogSamples.tweak("a", valueType: .enumeration(options))
        tweak.userOnlyValues = ["bypassPermissions", "auto"]

        #expect(rules([tweak]) == [.unknownUserOnlyValue])
        tweak.userOnlyValues = ["bypassPermissions"]
        #expect(rules([tweak]) == [])
    }

    @Test func suggestionsNeedAStringRow() {
        var tweak = CatalogSamples.tweak("a", valueType: .path)
        tweak.suggestions = [Tweak.Suggestion(value: "docs", label: "Docs")]

        #expect(rules([tweak]) == [.suggestionsNotString])
    }

    @Test("a suggestion has a value and a label", arguments: [("", "Empty"), (" ", "Blank"), ("opus", ""), ("opus", " ")])
    func suggestionsAreNotEmpty(value: String, label: String) {
        var tweak = CatalogSamples.tweak("a", valueType: .string)
        tweak.suggestions = [Tweak.Suggestion(value: value, label: label)]

        #expect(rules([tweak]) == [.emptySuggestion])
    }

    @Test func suggestionValuesAreUnique() {
        var tweak = CatalogSamples.tweak("a", valueType: .string)
        tweak.suggestions = [Tweak.Suggestion(value: "opus", label: "Opus"), Tweak.Suggestion(value: "opus", label: "Opus again")]

        #expect(rules([tweak]) == [.duplicateSuggestion])
    }

    @Test func issuesNameTheirRow() {
        let issue = CatalogLinter.lint(CatalogSamples.catalog([CatalogSamples.tweak("a", status: .hidden)]))

        #expect(issue.map(\.description) == ["a: status is hidden; only documented rows belong in tweaks.json"])
    }
}
