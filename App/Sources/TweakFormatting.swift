import PitotCore

extension Tweak {
    /// The key as a dotted path; env vars read `env.NAME`.
    var keyText: String {
        location.path.joined(separator: ".")
    }

    func label(for value: TweakValue?) -> String {
        guard let value else { return "not set" }
        switch (valueType, value) {
        case (.enumeration(let options), .string(let text)):
            return options.first { $0.value == text }?.label ?? text
        case (.string, .string(let text)), (.path, .string(let text)):
            return "\"\(text)\""
        default:
            return value.displayText
        }
    }

    func matches(search query: String) -> Bool {
        [title, keyText, description].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
