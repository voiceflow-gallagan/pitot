/// Writes onboarding must never make, whatever the answers. Presets never reduce safety:
/// they cannot skip permission prompts, turn the sandbox off, lift a protective block,
/// or send prompts and keys somewhere else. The app offers those only as explicit,
/// confirmed edits.
///
/// Rules match the file path and the JSON written, not the tweak id, so a renamed
/// catalog row is still covered.
public enum OnboardingSafety {
    public struct Rule: Sendable, Equatable {
        public enum Limit: Sendable, Equatable {
            /// Onboarding never sets or removes the key.
            case neverTouch
            /// Onboarding may set only these values and never removes the key.
            case onlyValues([JSONValue])
            /// Onboarding never sets these values. Removing the key is allowed.
            case neverValues([JSONValue])
        }

        public let path: [String]
        public let limit: Limit
        public let reason: String
    }

    public static let rules: [Rule] = [
        Rule(
            path: ["permissions", "defaultMode"], limit: .neverValues(["bypassPermissions", "auto"]),
            reason: "Onboarding never starts sessions in a mode that skips permission prompts."),
        Rule(path: ["sandbox", "enabled"], limit: .onlyValues([true]), reason: "Onboarding never turns the sandbox off."),
        Rule(
            path: ["permissions", "blockReadsOutsideWorkingDirectories"], limit: .onlyValues([true]),
            reason: "Onboarding never lifts the block on reads outside the project."),
        Rule(
            path: ["permissions", "disableBypassPermissionsMode"], limit: .onlyValues(["disable"]),
            reason: "Onboarding never allows bypass mode again."),
        Rule(path: ["skipDangerousModePermissionPrompt"], limit: .neverTouch, reason: "Onboarding never skips the bypass mode warning."),
        Rule(path: ["env", "ANTHROPIC_BASE_URL"], limit: .neverTouch, reason: "Onboarding never changes where your prompts are sent."),
        Rule(path: ["env", "ANTHROPIC_API_KEY"], limit: .neverTouch, reason: "Onboarding never writes keys."),
        Rule(path: ["env", "ANTHROPIC_AUTH_TOKEN"], limit: .neverTouch, reason: "Onboarding never writes keys."),
        Rule(path: ["apiKeyHelper"], limit: .neverTouch, reason: "Onboarding never writes keys."),
    ]

    /// Why onboarding must not give `tweak` this value, or nil when it may. Nil `value` removes the key.
    public static func violation(_ tweak: Tweak, value: TweakValue?) -> String? {
        let written: JSONValue? =
            switch value.flatMap(tweak.editValue) {
            case .json(let json)?: json
            case .raw?, nil: nil
            }
        if tweak.valueType == .flag, let written, written == .string("0") || written == .string("") {
            return "Onboarding never writes an off value to a flag. It removes the key instead."
        }
        guard let rule = rules.first(where: { $0.path == tweak.location.path }) else { return nil }
        switch rule.limit {
        case .neverTouch:
            return rule.reason
        case .onlyValues(let allowed):
            return written.map(allowed.contains) == true ? nil : rule.reason
        case .neverValues(let forbidden):
            return written.map(forbidden.contains) == true ? rule.reason : nil
        }
    }
}
