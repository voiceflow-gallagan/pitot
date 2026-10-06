import Foundation
import Testing

@testable import PitotCore

@Suite("Catalog data")
struct CatalogDataTests {
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Catalog/tweaks.json")

    private static let mustHaveIds = [
        "tui", "viewMode", "showThinkingSummaries", "showClearContextOnPlanAccept", "plansDirectory", "outputStyle", "theme", "editorMode",
        "showTurnDuration", "spinnerTipsEnabled", "prefersReducedMotion", "promptSuggestionEnabled", "preferredNotifChannel",
        "askUserQuestionTimeout", "awaySummaryEnabled", "model", "maxEffortLevel", "alwaysThinkingEnabled", "fastMode", "promptCacheTtl",
        "autoCompactEnabled", "CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE", "disableClaudeAiConnectors", "DISABLE_TELEMETRY",
        "DISABLE_ERROR_REPORTING", "enableArtifact", "CLAUDE_CODE_NEW_INIT", "sandbox.enabled",
        "permissions.blockReadsOutsideWorkingDirectories", "permissions.disableBypassPermissionsMode", "permissions.defaultMode", "ANTHROPIC_BASE_URL",
    ]

    /// Rows that make Claude Code safer when on, so turning them off must ask first.
    private static let protectiveIds = [
        "sandbox.enabled", "permissions.blockReadsOutsideWorkingDirectories", "permissions.disableBypassPermissionsMode",
    ]

    private func load() throws -> Catalog {
        try CatalogLoader.load(data: Data(contentsOf: Self.catalogURL))
    }

    @Test func catalogLintsClean() throws {
        _ = try load()
    }

    @Test func rowCountIsInRange() throws {
        #expect((25...40).contains(try load().tweaks.count))
    }

    @Test func everyMustHaveIdIsPresent() throws {
        let ids = Set(try load().tweaks.map(\.id))

        #expect(Set(Self.mustHaveIds).subtracting(ids) == [])
    }

    @Test func noFlagRowCanWriteZero() throws {
        for tweak in try load().tweaks where tweak.valueType == .flag {
            #expect(Validator.check(tweak, value: .string("0")) != [], "\(tweak.id) accepts \"0\"")
            #expect(tweak.defaultDescription.hasPrefix("0") == false)
        }
    }

    @Test func bypassLockIsAToggleThatWritesDisable() throws {
        let tweak = try #require(try load().tweak(id: "permissions.disableBypassPermissionsMode"))

        #expect(tweak.valueType == .fixedString("disable"))
        #expect(tweak.operation(for: true) == .set(path: ["permissions", "disableBypassPermissionsMode"], value: .json("disable")))
    }

    @Test func subagentModelForceWorksAlone() throws {
        let catalog = try load()
        let force = try #require(catalog.tweak(id: "CLAUDE_CODE_SUBAGENT_MODEL_FORCE"))

        let resolution = Dependencies.resolve(catalog, document: try CatalogSamples.document("{}"), change: ProposedChange(tweakId: force.id, value: true))

        #expect(force.requires.isEmpty)
        #expect(resolution.blocked.isEmpty)
    }

    @Test func envRowsLinkToTheVariablesTable() throws {
        for tweak in try load().tweaks where tweak.location.envName != nil {
            #expect(tweak.docURL == "https://code.claude.com/docs/en/env-vars#variables", "\(tweak.id)")
        }
    }

    @Test(
        "documented env overrides are modelled",
        arguments: [
            ("askUserQuestionTimeout", ["CLAUDE_AFK_TIMEOUT_MS"]), ("awaySummaryEnabled", ["CLAUDE_CODE_ENABLE_AWAY_SUMMARY"]),
            ("model", ["ANTHROPIC_MODEL"]), ("promptSuggestionEnabled", ["CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION", "DISABLE_TELEMETRY"]),
            ("alwaysThinkingEnabled", ["MAX_THINKING_TOKENS"]), ("promptCacheTtl", ["CLAUDE_CODE_PROMPT_CACHE_TTL", "FORCE_PROMPT_CACHING_5M"]),
            ("autoCompactEnabled", ["DISABLE_AUTO_COMPACT"]), ("fastMode", ["CLAUDE_CODE_DISABLE_FAST_MODE"]),
        ])
    func envOverridesAreModelled(id: String, envNames: [String]) throws {
        let tweak = try #require(try load().tweak(id: id))

        #expect(tweak.overriddenBy.map(\.envName) == envNames)
    }

    @Test func autoAndBypassAreUserLevelOnly() throws {
        let mode = try #require(try load().tweak(id: "permissions.defaultMode"))

        for value: TweakValue in ["auto", "bypassPermissions"] {
            #expect(mode.canWrite(in: .user, value: value) == .allowed)
            for layer: SettingsLayerKind in [.project, .local] {
                #expect(mode.canWrite(in: layer, value: value) != .allowed, "\(value) allowed in \(layer)")
            }
        }
        #expect(mode.canWrite(in: .project, value: "plan") == .allowed)
    }

    @Test func userOnlyRowsAreRefusedOutsideUserSettings() throws {
        for tweak in try load().tweaks where tweak.scope == .userOnly {
            #expect(tweak.canWrite(in: .local, value: nil) != .allowed, "\(tweak.id)")
        }
    }

    @Test func modelSuggestionsComeFromTheAliasTable() throws {
        let values = try #require(try load().tweak(id: "model")).suggestions.map(\.value)

        #expect(values.contains("opusplan"))
        #expect(Set(["best", "fable", "sonnet", "opus", "haiku", "sonnet[1m]", "opus[1m]"]).isSubset(of: values))
        #expect(!values.contains("default"))
    }

    @Test func outputStyleSuggestionsAreTheBuiltInStyles() throws {
        let values = try #require(try load().tweak(id: "outputStyle")).suggestions.map(\.value)

        #expect(values == ["Proactive", "Concise", "Explanatory", "Learning"])
    }

    @Test func subagentModelSuggestionsAreTheFamilyAliases() throws {
        let values = try #require(try load().tweak(id: "CLAUDE_CODE_SUBAGENT_MODEL")).suggestions.map(\.value)

        #expect(values == ["sonnet", "opus", "haiku", "fable"])
    }

    @Test func securityRowsHaveAConfirm() throws {
        for tweak in try load().tweaks where tweak.risks.contains(.security) {
            #expect(tweak.confirm != nil, "\(tweak.id) has no confirm")
        }
    }

    @Test(arguments: protectiveIds)
    func turningAProtectiveRowOffAsksFirst(id: String) throws {
        let tweak = try #require(try load().tweak(id: id))

        #expect(Tweak.Confirmation.isRequired(for: tweak, old: .value(true), new: false))
        #expect(Tweak.Confirmation.isRequired(for: tweak, old: .value(true), new: nil))
        #expect(!Tweak.Confirmation.isRequired(for: tweak, old: .unset, new: false))
        #expect(!Tweak.Confirmation.isRequired(for: tweak, old: .unset, new: true))
    }

    @Test func forbiddenValuesAreNeverADefault() throws {
        let catalog = try load()
        let bypass = try #require(catalog.tweak(id: "permissions.defaultMode"))
        let sandbox = try #require(catalog.tweak(id: "sandbox.enabled"))
        let baseURL = try #require(catalog.tweak(id: "ANTHROPIC_BASE_URL"))

        #expect(!bypass.defaultDescription.contains("bypassPermissions"))
        #expect(!sandbox.defaultDescription.hasPrefix("true"))
        #expect(Tweak.Confirmation.isRequired(for: sandbox, old: .value(true), new: nil))
        #expect(baseURL.defaultDescription.hasPrefix("Unset"))
    }
}
