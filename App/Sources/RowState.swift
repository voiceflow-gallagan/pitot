import PitotCore
import Foundation

struct RowNote: Identifiable, Equatable {
    enum Kind: Equatable {
        case info
        case warning
        case disabled
        /// Set by the managed settings, so no layer Pitot writes can change it.
        case locked
        /// Background facts, such as where an env var is written.
        case quiet
    }

    let kind: Kind
    let text: String

    var id: String { text }
}

/// What a row needs to know about the selected layer and the merged settings.
struct RowContext {
    let scope: SettingsLayerKind
    /// The selected layer's file, `{}` when Pitot would create it, nil when Claude Code skips it.
    let document: JSONDocument?
    let bytes: [UInt8]
    let problem: String?
    /// The file a write would create, when the selected layer has no file yet.
    let createsFile: URL?
    let effective: EffectiveSettings
    let claude: ClaudeStatus

    @MainActor
    init(scope: SettingsLayerKind, layer: LayerStore, effective: EffectiveSettings, claude: ClaudeStatus) {
        self.scope = scope
        document = layer.editDocument
        bytes = layer.editBytes
        problem = layer.problem
        createsFile = layer.isMissing && layer.isEditable ? layer.url : nil
        self.effective = effective
        self.claude = claude
    }
}

/// Everything one row shows: the selected layer's value, the value in effect across all layers,
/// the pending change, and why the row may not be edited.
struct RowState: Equatable {
    static let envNote = "Saved in the env block of the file. When Claude Desktop starts Claude Code, it can override this value."
    static let lockedText = "Set by your organization"
    static let opusplanNote = "Opus plan (opusplan) is not in the /model picker of Claude Code. Type /model opusplan there, or choose it here."

    /// The selected layer's value.
    var reading: TweakReading = .unset
    /// The value in effect across all layers, and the layer it comes from.
    var effective = LayeredReading(reading: .unset, winner: nil, overridden: [])
    var pending: ProposedChange?
    /// Set when a pending change elsewhere sets this tweak through a dependency.
    var autoSet: Resolution.AutoSet?
    /// The file's text for a value this row cannot show, such as `42` for an enum.
    var unrecognizedText: String?
    var versionStatus: VersionStatus = .available
    var isLocked = false
    /// Why the selected layer cannot hold this row at all, such as a user-only key in a project file.
    var rowRefusal: String?
    /// Every reason the control is disabled, the first one found.
    var disabledReason: String?
    /// The layer that keeps what you set here out of effect. The row offers to switch to it.
    var overriddenBy: LayerID?
    var notes: [RowNote] = []

    var isPending: Bool { pending != nil }

    /// What the control shows: the pending value, then an automatic one, then the selected layer's.
    var displayed: TweakValue? {
        if let pending { return pending.value }
        if let autoSet { return autoSet.value }
        return reading.value
    }

    /// True while the file's unrecognized value is still what the row would write.
    var showsUnrecognized: Bool {
        unrecognizedText != nil && pending == nil && autoSet == nil
    }

    static func make(_ tweak: Tweak, context: RowContext, pending: ProposedChange?, resolution: Resolution?, refusal: String?) -> RowState {
        var state = RowState()
        let selected = LayerID(context.scope)
        state.reading = context.document.map(tweak.reading(in:)) ?? .unset
        state.effective = tweak.reading(in: context.effective)
        state.pending = pending
        state.autoSet = resolution?.autoSet.first { $0.tweakId == tweak.id }
        state.unrecognizedText = context.document.flatMap { unrecognizedText(tweak, reading: state.reading, document: $0) }
        state.versionStatus = VersionGate.status(tweak, installed: context.claude.version)
        state.isLocked = context.effective.lockedByManaged(tweak)
        if case .refused(let reason) = tweak.canWrite(in: context.scope, value: nil) { state.rowRefusal = reason }

        if let problem = context.problem {
            state.disabledReason = problem
        } else if state.isLocked {
            state.disabledReason = lockedText
        } else if let reason = state.rowRefusal {
            state.disabledReason = reason
        } else if case .needs(let minimum) = state.versionStatus {
            let installed = context.claude.version.map { " This Mac has \($0)." } ?? ""
            state.disabledReason = "Needs Claude Code \(minimum) or later.\(installed)"
        } else {
            state.disabledReason = resolution?.disabled[tweak.id]
        }

        if !state.isLocked {
            let shadowing = state.reading == .unset ? [] : context.effective.shadowing(of: selected, at: tweak.location.path)
            let higherWinner = state.effective.winner.flatMap { $0 > selected ? $0 : nil }
            state.overriddenBy = shadowing.first ?? higherWinner
        }

        if let reason = state.disabledReason, context.problem == nil {
            state.notes.append(RowNote(kind: state.isLocked ? .locked : .disabled, text: reason))
        }
        if let refusal {
            state.notes.append(RowNote(kind: .disabled, text: refusal))
        }
        if state.versionStatus == .unknown, context.claude == .notFound, let minimum = tweak.minVersion {
            state.notes.append(RowNote(kind: .warning, text: "Needs Claude Code \(minimum) or later. Pitot could not check the installed version."))
        }
        if let winner = state.effective.winner, winner != selected {
            state.notes.append(RowNote(kind: .info, text: "In effect: \(effectiveText(tweak, state.effective.reading)), set in \(winner.displayName)"))
        }
        if let autoSet = state.autoSet {
            state.notes.append(RowNote(kind: .info, text: "Will be set to \(tweak.label(for: autoSet.value)): \(autoSet.reason)"))
        }
        for text in activeOverrides(tweak, in: context.effective) {
            state.notes.append(RowNote(kind: .warning, text: text))
        }
        if tweak.location.envName != nil {
            state.notes.append(RowNote(kind: .quiet, text: envNote))
        }
        if tweak.suggestions.contains(where: { $0.value == "opusplan" }) {
            state.notes.append(RowNote(kind: .quiet, text: opusplanNote))
        }
        return state
    }

    static func effectiveText(_ tweak: Tweak, _ reading: TweakReading) -> String {
        switch (reading, tweak.valueType) {
        case (.unset, _): "not set"
        case (.value(let value), .enumeration): tweak.label(for: value)
        case (.value(let value), _): value.displayText
        case (.unrecognized, _): "a value Pitot cannot read"
        }
    }

    static func unrecognizedText(_ tweak: Tweak, reading: TweakReading, document: JSONDocument) -> String? {
        switch reading {
        case .unset:
            return nil
        case .value(let value) where Validator.check(tweak, value: value).isEmpty:
            return nil
        case .value, .unrecognized:
            guard let node = document.node(at: tweak.location.path) else { return nil }
            let text = String(decoding: document.rawBytes(of: node), as: UTF8.self)
            return text.count > 60 ? String(text.prefix(60)) + "…" : text
        }
    }

    /// Env vars in effect that beat the tweak. Boolean words count as equal, as Core reads them,
    /// so `NO_FLICKER=false` matches an override listed for `0`.
    static func activeOverrides(_ tweak: Tweak, in effective: EffectiveSettings) -> [String] {
        tweak.overriddenBy.compactMap { envOverride in
            guard let found = effective.value(at: ["env", envOverride.envName]), case .string(let value) = found.value, !value.isEmpty
            else { return nil }
            if let expected = envOverride.whenValue, booleanWord(value) != booleanWord(expected) { return nil }
            return "Overridden: \(envOverride.envName)=\(value) in the \(found.winner.displayName) env block wins over this setting."
        }
    }

    private static func booleanWord(_ text: String) -> String {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": "true"
        case "0", "false", "no", "off": "false"
        default: text
        }
    }
}
