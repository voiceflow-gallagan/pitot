public enum WriteDecision: Sendable, Equatable {
    case allowed
    case refused(String)
}

extension Tweak {
    /// Whether Pitot may write `value` for this row in `layer`. A nil value removes the key.
    ///
    /// Claude Code ignores a `userOnly` row in project and local files, so the row is refused there
    /// for any value. A value in `userOnlyValues` is refused there too; other values and removal are allowed.
    public func canWrite(in layer: SettingsLayerKind, value: TweakValue?) -> WriteDecision {
        guard layer != .user else { return .allowed }
        if scope == .userOnly {
            return .refused("Claude Code reads \(title) only from user settings, so it cannot be set in \(layer.rawValue) settings.")
        }
        if case .string(let text)? = value, userOnlyValues.contains(text) {
            return .refused("Claude Code ignores \(text) for \(title) in project and local settings. Set it in user settings.")
        }
        return .allowed
    }
}
