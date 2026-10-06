/// A key whose restrictive value Claude Code honors from a layer that would otherwise lose, even to
/// managed settings.
///
/// The rows are the docs table "Exceptions to managed settings precedence", read 2026-10-06 at
/// `docURL`. They are documented, not tested against Claude Code (rule 27 in `Core/MERGE-RULES.md`).
///
/// How a value is chosen: the layers outside `onlyRestrictiveFrom` give a base value by plain
/// precedence. Each restrictive value from a layer in `honoredFrom` then competes with the base,
/// and the most restrictive value wins. On a tie the higher layer wins. A layer in
/// `onlyRestrictiveFrom` counts only for a restrictive value, and Claude Code ignores any other
/// value it holds. Layers that cannot set the key at all are handled by the scope table, such as
/// a project `useAutoModeDuringPlan`.
///
/// Not modeled: `disableArtifact: true` also turns `enableArtifact` off, but each key is resolved
/// on its own path; the legacy `remoteControlAtStartup` value in `~/.claude.json`.
public struct RestrictiveKey: Sendable, Equatable {
    public static let docURL = "https://code.claude.com/docs/en/settings#exceptions-to-managed-settings-precedence"

    public let path: [String]
    /// Values from least to most restrictive. Every value after the first is restrictive; any value
    /// not listed ranks below all of them.
    public let ladder: [JSONValue]
    public let honoredFrom: Set<LayerID>
    public let onlyRestrictiveFrom: Set<LayerID>
    /// The docs table row, quoted.
    public let quote: String

    public static func rule(for path: [String]) -> RestrictiveKey? {
        all.first { $0.path == path }
    }

    public static let all: [RestrictiveKey] = [
        RestrictiveKey(
            path: ["disableClaudeAiConnectors"], ladder: [false, true], honoredFrom: anyLayer, onlyRestrictiveFrom: [],
            quote: "`true` from any scope. Honored even when a managed source sets `false`"
        ),
        RestrictiveKey(
            path: ["enableArtifact"], ladder: [true, false], honoredFrom: anyLayer, onlyRestrictiveFrom: [],
            quote: "`false` from any scope, and `disableArtifact: true` from any scope. Honored even when a managed source sets `true`; nothing turns the Artifact tool back on"
        ),
        RestrictiveKey(
            path: ["disableArtifact"], ladder: [false, true], honoredFrom: anyLayer, onlyRestrictiveFrom: [],
            quote: "`false` from any scope, and `disableArtifact: true` from any scope. Honored even when a managed source sets `true`; nothing turns the Artifact tool back on"
        ),
        RestrictiveKey(
            path: ["isolatePeerMachines"], ladder: [false, true], honoredFrom: anyLayer, onlyRestrictiveFrom: [],
            quote: "`true` from any scope. Honored even when a managed source sets `false`"
        ),
        RestrictiveKey(
            path: ["remoteControlAtStartup"], ladder: [true, false], honoredFrom: projectOrLocal, onlyRestrictiveFrom: projectOrLocal,
            quote: "`false` from `.claude/settings.json` or `.claude/settings.local.json`. Honored even when a managed source sets `true`; a project or local `true` is ignored"
        ),
        // With no managed or user value, a project or local `accept` is ignored too: it does not
        // tighten the per-message default. Inferred: a repository may only tighten it.
        RestrictiveKey(
            path: ["crossSessionInbound"], ladder: ["accept", "hold", "refuse"], honoredFrom: projectOrLocal, onlyRestrictiveFrom: projectOrLocal,
            quote: "A stricter value from `.claude/settings.json` or `.claude/settings.local.json`, on the `accept` < `hold` < `refuse` ladder. Honored over managed, `--settings`, and user values; a project or local value that isn't stricter is ignored"
        ),
        RestrictiveKey(
            path: ["useAutoModeDuringPlan"], ladder: [true, false], honoredFrom: notProject, onlyRestrictiveFrom: [],
            quote: "`false` from any managed source, `--settings`, `~/.claude/settings.json`, or `.claude/settings.local.json`. Honored even when the winning managed source sets `true`; a `false` in `.claude/settings.json` is ignored"
        ),
        RestrictiveKey(
            path: ["syncClaudeAiSkills"], ladder: [true, false], honoredFrom: notProject, onlyRestrictiveFrom: [],
            quote: "`false` from any managed source, `--settings`, `~/.claude/settings.json`, or `.claude/settings.local.json`. Honored even when the winning managed source sets `true`; a `false` in `.claude/settings.json` is ignored"
        ),
        RestrictiveKey(
            path: ["syncClaudeAiPlugins"], ladder: [true, false], honoredFrom: notProject, onlyRestrictiveFrom: [],
            quote: "`false` from any managed source, `--settings`, `~/.claude/settings.json`, or `.claude/settings.local.json`. Honored even when the winning managed source sets `true`; a `false` in `.claude/settings.json` is ignored"
        ),
        // `max` sets no cap (settings-reference.md, `maxEffortLevel`), so it is the least restrictive.
        RestrictiveKey(
            path: ["maxEffortLevel"], ladder: ["max", "xhigh", "high", "medium", "low"], honoredFrom: anyLayer, onlyRestrictiveFrom: [],
            quote: "A lower cap from any scope, including `--settings`. Honored even when the managed settings Claude Code applies set a higher cap; the lowest cap applies"
        ),
    ]

    private static let anyLayer = Set(LayerID.allCases)
    private static let projectOrLocal: Set<LayerID> = [.project, .local]
    private static let notProject: Set<LayerID> = [.managed, .user, .local]

    func rank(of value: JSONValue) -> Int {
        ladder.firstIndex(of: value) ?? -1
    }

    func isRestrictive(_ value: JSONValue) -> Bool {
        rank(of: value) > 0
    }

    /// Whether a managed `value` stays in effect whatever the other layers hold.
    func locks(managedValue value: JSONValue) -> Bool {
        honoredFrom.subtracting([.managed]).isEmpty || rank(of: value) == ladder.count - 1
    }
}
