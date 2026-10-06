public enum ValidationIssue: Sendable, Equatable {
    /// The value's kind does not match the tweak. `expected` is the catalog type name, such as `bool`.
    case wrongType(expected: String)
    case notAnOption(String)
    case belowMinimum(Int)
    case aboveMaximum(Int)
    /// A string or path that holds nothing but whitespace.
    case empty
    /// A path or env value with a NUL character, which no file system or environment accepts.
    case containsNul
    /// A flag or fixed string takes only on or off.
    case notOnOff
    case envValueNotString

    public var message: String {
        switch self {
        case .wrongType(let expected): "Expected a value of type \(expected)."
        case .notAnOption(let value): "\"\(value)\" is not one of the allowed values."
        case .belowMinimum(let minimum): "The value must be at least \(minimum)."
        case .aboveMaximum(let maximum): "The value must be at most \(maximum)."
        case .empty: "The value must not be empty."
        case .containsNul: "The value must not contain a NUL character."
        case .notOnOff: "The value must be on or off."
        case .envValueNotString: "Values in the env block must be strings."
        }
    }
}

/// Checks a proposed value against its tweak before anything is written.
public enum Validator {
    public static func check(_ tweak: Tweak, value: TweakValue) -> [ValidationIssue] {
        let issues = typeIssues(tweak.valueType, value: value)
        guard issues.isEmpty, tweak.location.envName != nil, case .string(let text) = value, text.contains("\0") else { return issues }
        return [.containsNul]
    }

    public static func checkEnvValueIsString(_ value: JSONValue) -> [ValidationIssue] {
        if case .string = value { return [] }
        return [.envValueNotString]
    }

    private static func typeIssues(_ valueType: Tweak.ValueType, value: TweakValue) -> [ValidationIssue] {
        switch (valueType, value) {
        case (.bool, .bool), (.flag, .bool), (.fixedString, .bool):
            return []
        case (.flag, _), (.fixedString, _):
            return [.notOnOff]
        case (.enumeration(let options), .string(let text)):
            return options.contains { $0.value == text } ? [] : [.notAnOption(text)]
        case (.string, .string(let text)):
            return isBlank(text) ? [.empty] : []
        case (.path, .string(let text)):
            return (isBlank(text) ? [.empty] : []) + (text.contains("\0") ? [.containsNul] : [])
        case (.integer(let minimum, let maximum), .integer(let number)):
            if let minimum, number < minimum { return [.belowMinimum(minimum)] }
            if let maximum, number > maximum { return [.aboveMaximum(maximum)] }
            return []
        default:
            return [.wrongType(expected: valueType.name)]
        }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
