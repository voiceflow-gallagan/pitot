import Foundation

/// What a settings file holds for one tweak.
public enum TweakReading: Sendable, Equatable {
    case unset
    case value(TweakValue)
    /// The key holds JSON the tweak's type cannot represent, such as a number for a bool setting.
    case unrecognized(JSONValue)

    public var value: TweakValue? {
        if case .value(let value) = self { return value }
        return nil
    }

    public var isActive: Bool {
        switch self {
        case .unset: false
        case .value(let value): value.isActive
        case .unrecognized: true
        }
    }
}

extension Tweak.Location {
    /// The JSON path in `settings.json`. Env vars live under `["env", name]`.
    public var path: [String] {
        switch self {
        case .setting(let path): path
        case .env(let name): ["env", name]
        }
    }

    public var envName: String? {
        if case .env(let name) = self { return name }
        return nil
    }
}

extension Tweak {
    /// Reads this tweak from a scanned settings file, using the location and value type.
    ///
    /// Env values are strings: a flag is on when non-empty, a bool accepts `1`, `true`, `yes`, `on`
    /// and `0`, `false`, `no`, `off`, an integer must be plain digits. A fixed string is on only for
    /// its exact text; any other value is `unrecognized`, and an absent key is `unset`, which means off.
    public func reading(in document: JSONDocument) -> TweakReading {
        reading(from: document.value(at: location.path))
    }

    /// Reads this tweak from the JSON at its location, nil when the key is absent.
    func reading(from json: JSONValue?) -> TweakReading {
        guard let json else { return .unset }
        switch location {
        case .setting: return Self.settingReading(json, as: valueType)
        case .env: return Self.envReading(json, as: valueType)
        }
    }

    public func value(in document: JSONDocument) -> TweakValue? {
        reading(in: document).value
    }

    /// The JSON to write for `value`, or nil when the key must be removed.
    /// A flag is `"1"` when the value is active and removed otherwise, so `"0"` is never written.
    /// A fixed string works the same way with its own string. Env values are always strings;
    /// an env bool is `"1"` or `"0"`.
    public func editValue(for value: TweakValue) -> JSONEdit.Value? {
        switch valueType {
        case .flag: return value.isActive ? .json(.string("1")) : nil
        case .fixedString(let fixed): return value.isActive ? .json(.string(fixed)) : nil
        case .bool, .enumeration, .string, .integer, .path: break
        }
        switch (location, value) {
        case (.setting, .bool(let flag)): return .json(.bool(flag))
        case (.setting, .integer(let number)): return .json(.number(JSONNumber(number)))
        case (.setting, .string(let text)): return .json(.string(text))
        case (.env, .bool(let flag)): return .json(.string(flag ? "1" : "0"))
        case (.env, .integer(let number)): return .json(.string(String(number)))
        case (.env, .string(let text)): return .json(.string(text))
        }
    }

    /// The edit that makes the file hold `value`. Nil `value` removes the key.
    public func operation(for value: TweakValue?) -> JSONEdit.Operation {
        guard let value, let edit = editValue(for: value) else { return .remove(path: location.path) }
        return .set(path: location.path, value: edit)
    }

    /// Like `operation(for:)`, but nil when the file already means `value`.
    /// A value that reads back the same, such as an env bool written as `"true"`, is left alone.
    public func operation(for value: TweakValue?, in document: JSONDocument) -> JSONEdit.Operation? {
        let operation = operation(for: value)
        switch operation {
        case .remove(let path):
            return document.node(at: path) == nil ? nil : operation
        case .set:
            return value.map { reading(in: document) == .value($0) } == true ? nil : operation
        case .appendElement, .insertElement, .replaceElement, .removeElement, .editElement:
            return operation
        }
    }

    private static func settingReading(_ json: JSONValue, as valueType: ValueType) -> TweakReading {
        switch (valueType, json) {
        case (.bool, .bool(let flag)), (.flag, .bool(let flag)):
            return .value(.bool(flag))
        case (.enumeration, .string(let text)), (.string, .string(let text)), (.path, .string(let text)):
            return .value(.string(text))
        case (.integer, .number(let number)):
            return Int(number.text).map { .value(.integer($0)) } ?? .unrecognized(json)
        case (.fixedString(let fixed), .string(let text)) where text == fixed:
            return .value(.bool(true))
        default:
            return .unrecognized(json)
        }
    }

    private static func envReading(_ json: JSONValue, as valueType: ValueType) -> TweakReading {
        guard case .string(let text) = json else { return .unrecognized(json) }
        switch valueType {
        case .flag:
            return .value(.bool(!text.isEmpty))
        case .bool:
            return EnvBoolean.parse(text).map { .value(.bool($0)) } ?? .unrecognized(json)
        case .integer:
            return Int(text).map { .value(.integer($0)) } ?? .unrecognized(json)
        case .fixedString(let fixed):
            return text == fixed ? .value(.bool(true)) : .unrecognized(json)
        case .enumeration, .string, .path:
            return .value(.string(text))
        }
    }
}

enum EnvBoolean {
    static func parse(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: nil
        }
    }
}
