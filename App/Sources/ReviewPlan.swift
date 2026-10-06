import PitotCore
import Foundation

/// What Apply would write to the selected layer: the pending changes, the dependency auto-sets,
/// the problems that block Apply, the changes another layer keeps out of effect, and a diff computed
/// by running every operation over the layer's bytes.
struct ReviewPlan: Equatable {
    struct Line: Identifiable, Equatable {
        let id: String
        let text: String
    }

    /// Nil only for the empty plan made before the file is loaded.
    var resolution: Resolution?
    var changes: [Line] = []
    /// One "Also turning on X because Y" line per dependency auto-set.
    var autoSets: [Line] = []
    /// Changes that will be written but not take effect, because another layer wins.
    var shadowed: [Line] = []
    var warnings: [String] = []
    /// Validation, version, lock, layer and dependency failures. Any problem disables Apply.
    var problems: [String] = []
    var suggestions: [Resolution.UnsetSuggestion] = []
    /// The pending changes in catalog order, then the auto-sets, without no-ops.
    var operations: [JSONEdit.Operation] = []
    var diff: [DiffLine] = []
    var previewError: String?
    /// The file Apply would create, when the layer has none yet.
    var createsFile: URL?

    var isEmpty: Bool { changes.isEmpty }
    var canApply: Bool { !operations.isEmpty && problems.isEmpty && previewError == nil }

    static func make(catalog: Catalog, context: RowContext, pending: [String: ProposedChange]) -> ReviewPlan {
        let explicit = catalog.tweaks.compactMap { pending[$0.id] }
        var plan = ReviewPlan()
        let resolution = Dependencies.resolve(catalog, effective: context.effective, changes: explicit, target: LayerID(context.scope))
        plan.resolution = resolution
        guard !explicit.isEmpty, let document = context.document else { return plan }
        plan.createsFile = context.createsFile

        var targets: [(tweak: Tweak, value: TweakValue?)] = []
        for change in explicit {
            guard let tweak = catalog.tweak(id: change.tweakId) else { continue }
            let reading = tweak.reading(in: document)
            plan.changes.append(Line(id: tweak.id, text: "\(tweak.title): \(changeText(tweak, from: reading, to: change.value, in: document))"))
            targets.append((tweak, change.value))
        }
        for autoSet in resolution.autoSet {
            guard let tweak = catalog.tweak(id: autoSet.tweakId) else { continue }
            plan.autoSets.append(Line(id: tweak.id, text: autoSetText(tweak, value: autoSet.value, reason: autoSet.reason)))
            targets.append((tweak, autoSet.value))
        }
        for shadowed in resolution.shadowed {
            guard let tweak = catalog.tweak(id: shadowed.tweakId) else { continue }
            plan.shadowed.append(Line(id: tweak.id, text: shadowText(tweak, shadowed, target: context.scope)))
        }

        for (tweak, value) in targets {
            guard let value else { continue }
            plan.problems += Validator.check(tweak, value: value).map { "\(tweak.title): \($0.message)" }
            if case .needs(let minimum) = VersionGate.status(tweak, installed: context.claude.version) {
                plan.problems.append("\(tweak.title) needs Claude Code \(minimum) or later.")
            }
        }
        for (id, reason) in resolution.blocked.sorted(by: { $0.key < $1.key }) {
            plan.problems.append("\(catalog.tweak(id: id)?.title ?? id): \(reason)")
        }
        plan.warnings = resolution.warnings
        plan.suggestions = resolution.unsetSuggestions
        plan.operations = targets.compactMap { $0.tweak.operation(for: $0.value, in: document) }
        // A file Pitot creates is shown as all new lines, not as a change from `{}`.
        (plan.diff, plan.previewError) = preview(plan.operations, over: context.bytes, comparedTo: context.createsFile == nil ? nil : [])
        return plan
    }

    static func shadowText(_ tweak: Tweak, _ shadowed: Resolution.Shadowed, target: SettingsLayerKind) -> String {
        guard let layer = shadowed.by else {
            return "\(tweak.title): this change will not take effect. Claude Code ignores this value in \(target.displayName) settings."
        }
        return "\(tweak.title): this change will not take effect. \(layer.displayName) sets it to "
            + "\(RowState.effectiveText(tweak, shadowed.effective))."
    }

    /// "old → new" for one tweak, showing the file's raw text when the row cannot read it.
    static func changeText(_ tweak: Tweak, from reading: TweakReading, to value: TweakValue?, in document: JSONDocument) -> String {
        let from = RowState.unrecognizedText(tweak, reading: reading, document: document) ?? tweak.label(for: reading.value)
        return "\(from) → \(tweak.label(for: value))"
    }

    static func autoSetText(_ tweak: Tweak, value: TweakValue?, reason: String) -> String {
        "Also turning on \(tweak.title) (\(tweak.label(for: value))) because \(reason.lowercasedFirst)"
    }

    /// The unified diff of running `operations` in order over `original`, or the first edit that fails.
    /// The diff compares with `base` when given, else with `original`.
    static func preview(
        _ operations: [JSONEdit.Operation], over original: [UInt8], comparedTo base: [UInt8]? = nil
    ) -> (diff: [DiffLine], error: String?) {
        var bytes = original
        for operation in operations {
            do throws(JSONEditError) {
                bytes = try JSONEdit.apply(operation, to: bytes).bytes
            } catch {
                return ([], "Cannot preview the change to \(operation.path.joined(separator: ".")): \(ErrorText.describe(error)).")
            }
        }
        return (LineDiff.unified(old: base ?? original, new: bytes), nil)
    }
}
