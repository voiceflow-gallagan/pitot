import Foundation

/// Every setting and env var Pitot can edit, as data. The app builds its screens from this.
///
/// JSON shape: every union is an object with a `type` field plus the fields of that case,
/// such as `{"type": "setting", "path": ["sandbox", "enabled"]}`. Unknown keys are rejected
/// so a typo in the hand-written file fails to load instead of being ignored.
public struct Catalog: Sendable, Equatable {
    public var researchDate: String
    /// The Claude Code version the research notes were checked against.
    public var claudeCodeVersionChecked: String
    public var tweaks: [Tweak]

    public init(researchDate: String, claudeCodeVersionChecked: String, tweaks: [Tweak]) {
        self.researchDate = researchDate
        self.claudeCodeVersionChecked = claudeCodeVersionChecked
        self.tweaks = tweaks
    }

    public func tweak(id: String) -> Tweak? {
        tweaks.first { $0.id == id }
    }
}

/// A value Pitot proposes for a tweak. Flags use `bool`: true is on, false is off.
public enum TweakValue: Sendable, Hashable {
    case bool(Bool)
    case integer(Int)
    case string(String)

    /// False for `false` and the empty string, which Claude Code treats as off.
    public var isActive: Bool {
        switch self {
        case .bool(let flag): flag
        case .integer: true
        case .string(let text): !text.isEmpty
        }
    }

    public var displayText: String {
        switch self {
        case .bool(let flag): flag ? "on" : "off"
        case .integer(let number): String(number)
        case .string(let text): text
        }
    }
}

public struct Tweak: Sendable, Equatable, Identifiable {
    public var id: String
    public var location: Location
    public var valueType: ValueType
    /// Common values a string row offers as choices. Any other non-empty text stays valid.
    public var suggestions: [Suggestion]
    /// What Claude Code does when the key is unset, in plain words.
    public var defaultDescription: String
    /// The value Claude Code uses when the key is unset, when the docs state one. Nil counts as off.
    public var defaultValue: TweakValue?
    public var title: String
    public var description: String
    public var category: String
    public var risks: Set<Risk>
    public var status: Status
    public var minVersion: String?
    public var scope: Scope
    /// Enum values Claude Code ignores in project and local settings, so Pitot writes them only to user settings.
    public var userOnlyValues: [String]
    public var requires: [Requirement]
    public var confirm: Confirmation?
    /// Env vars that beat this tweak when the same file sets them.
    public var overriddenBy: [EnvOverride]
    public var docURL: String
    public var notes: String?

    public init(
        id: String,
        location: Location,
        valueType: ValueType,
        suggestions: [Suggestion] = [],
        defaultDescription: String,
        defaultValue: TweakValue? = nil,
        title: String,
        description: String,
        category: String,
        risks: Set<Risk> = [],
        status: Status = .documented,
        minVersion: String? = nil,
        scope: Scope = .any,
        userOnlyValues: [String] = [],
        requires: [Requirement] = [],
        confirm: Confirmation? = nil,
        overriddenBy: [EnvOverride] = [],
        docURL: String,
        notes: String? = nil
    ) {
        self.id = id
        self.location = location
        self.valueType = valueType
        self.suggestions = suggestions
        self.defaultDescription = defaultDescription
        self.defaultValue = defaultValue
        self.title = title
        self.description = description
        self.category = category
        self.risks = risks
        self.status = status
        self.minVersion = minVersion
        self.scope = scope
        self.userOnlyValues = userOnlyValues
        self.requires = requires
        self.confirm = confirm
        self.overriddenBy = overriddenBy
        self.docURL = docURL
        self.notes = notes
    }

    public enum Location: Sendable, Hashable {
        /// A key in `settings.json`. Nested keys are path elements, such as `["sandbox", "enabled"]`.
        case setting(path: [String])
        /// A variable in the `env` object of `settings.json`. Its value is always a JSON string.
        case env(name: String)
    }

    public enum ValueType: Sendable, Hashable {
        case bool
        case enumeration([Option])
        case string
        /// Either bound may be absent, such as `cleanupPeriodDays` with a minimum of 1 and no maximum.
        case integer(min: Int?, max: Int?)
        case path
        /// An env var that is on when it holds any non-empty value, even `"0"`. On writes `"1"`, off removes the key.
        case flag
        /// A toggle for a key with one valid string, such as `"disable"`. On writes the string, off removes the key.
        /// Values use `bool`, like a flag.
        case fixedString(String)
    }

    public struct Option: Sendable, Hashable {
        public var value: String
        public var label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    public struct Suggestion: Sendable, Hashable {
        public var value: String
        public var label: String
        public var note: String?

        public init(value: String, label: String, note: String? = nil) {
            self.value = value
            self.label = label
            self.note = note
        }
    }

    public enum Risk: String, Codable, Sendable, CaseIterable {
        case security, cost, behavior, privacy
    }

    public enum Status: String, Codable, Sendable {
        case documented, hidden, unverified
    }

    public enum Scope: String, Codable, Sendable {
        case any
        /// Claude Code honors the key only in user or managed settings.
        case userOnly
    }

    /// This tweak needs another tweak to hold a value.
    public struct Requirement: Sendable, Hashable {
        public var tweakId: String
        /// The value of this tweak that triggers the requirement. Nil means any active value.
        public var when: TweakValue?
        /// The value the other tweak must hold. Nil means any active value.
        public var equals: TweakValue?
        public var behavior: Behavior
        public var reason: String

        public init(tweakId: String, when: TweakValue? = nil, equals: TweakValue?, behavior: Behavior, reason: String) {
            self.tweakId = tweakId
            self.when = when
            self.equals = equals
            self.behavior = behavior
            self.reason = reason
        }

        public enum Behavior: String, Codable, Sendable {
            /// Setting this tweak also sets the other tweak to `equals`.
            case autoSet
            /// This tweak's control stays disabled until the other tweak holds `equals`.
            case disable
        }
    }

    public struct Confirmation: Sendable, Hashable {
        public var message: String
        public var appliesWhen: AppliesWhen

        public init(message: String, appliesWhen: AppliesWhen) {
            self.message = message
            self.appliesWhen = appliesWhen
        }

        /// Triggers compare effective values: an unset key means the row's `defaultValue`, or off without one.
        public enum AppliesWhen: Sendable, Hashable {
            /// The tweak goes from effectively off to effectively on.
            case onEnable
            /// The tweak goes from effectively on to effectively off, by a false value or by removing the key.
            case onDisable
            case onAnyChange
            case whenValue(TweakValue)
        }
    }

    /// An env var that beats this tweak. With `whenValue`, only that value beats it;
    /// boolean words such as `0` and `false` count as the same value.
    public struct EnvOverride: Sendable, Hashable {
        public var envName: String
        public var whenValue: String?

        public init(envName: String, whenValue: String? = nil) {
            self.envName = envName
            self.whenValue = whenValue
        }
    }
}

extension TweakValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    public init(integerLiteral value: Int) {
        self = .integer(value)
    }

    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

// MARK: Codable

extension TweakValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Int.self) {
            self = .integer(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a bool, an integer or a string")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let flag): try container.encode(flag)
        case .integer(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        }
    }
}

extension Catalog: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case researchDate, claudeCodeVersionChecked, tweaks
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        researchDate = try container.decode(String.self, forKey: .researchDate)
        claudeCodeVersionChecked = try container.decode(String.self, forKey: .claudeCodeVersionChecked)
        tweaks = try container.decode([Tweak].self, forKey: .tweaks)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(researchDate, forKey: .researchDate)
        try container.encode(claudeCodeVersionChecked, forKey: .claudeCodeVersionChecked)
        try container.encode(tweaks, forKey: .tweaks)
    }
}

/// `suggestions`, `defaultValue`, `scope`, `userOnlyValues`, `minVersion`, `requires`, `confirm`, `overriddenBy`
/// and `notes` may be left out.
/// `risks` is required, so every row states its risks, even when the list is empty.
extension Tweak: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, location, valueType, defaultDescription, defaultValue, title, description, category, risks, status
        case minVersion, scope, requires, confirm, overriddenBy, docURL, notes, suggestions, userOnlyValues
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        location = try container.decode(Location.self, forKey: .location)
        valueType = try container.decode(ValueType.self, forKey: .valueType)
        suggestions = try container.decodeIfPresent([Suggestion].self, forKey: .suggestions) ?? []
        defaultDescription = try container.decode(String.self, forKey: .defaultDescription)
        defaultValue = try container.decodeIfPresent(TweakValue.self, forKey: .defaultValue)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        category = try container.decode(String.self, forKey: .category)
        risks = try container.decode(Set<Risk>.self, forKey: .risks)
        status = try container.decode(Status.self, forKey: .status)
        minVersion = try container.decodeIfPresent(String.self, forKey: .minVersion)
        scope = try container.decodeIfPresent(Scope.self, forKey: .scope) ?? .any
        userOnlyValues = try container.decodeIfPresent([String].self, forKey: .userOnlyValues) ?? []
        requires = try container.decodeIfPresent([Requirement].self, forKey: .requires) ?? []
        confirm = try container.decodeIfPresent(Confirmation.self, forKey: .confirm)
        overriddenBy = try container.decodeIfPresent([EnvOverride].self, forKey: .overriddenBy) ?? []
        docURL = try container.decode(String.self, forKey: .docURL)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(location, forKey: .location)
        try container.encode(valueType, forKey: .valueType)
        if !suggestions.isEmpty { try container.encode(suggestions, forKey: .suggestions) }
        try container.encode(defaultDescription, forKey: .defaultDescription)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(category, forKey: .category)
        try container.encode(Risk.allCases.filter(risks.contains), forKey: .risks)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(minVersion, forKey: .minVersion)
        try container.encode(scope, forKey: .scope)
        if !userOnlyValues.isEmpty { try container.encode(userOnlyValues, forKey: .userOnlyValues) }
        if !requires.isEmpty { try container.encode(requires, forKey: .requires) }
        try container.encodeIfPresent(confirm, forKey: .confirm)
        if !overriddenBy.isEmpty { try container.encode(overriddenBy, forKey: .overriddenBy) }
        try container.encode(docURL, forKey: .docURL)
        try container.encodeIfPresent(notes, forKey: .notes)
    }
}

extension Tweak.Location: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type, path, name
    }

    private enum Kind: String, Codable {
        case setting, env
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .setting: self = .setting(path: try container.decode([String].self, forKey: .path))
        case .env: self = .env(name: try container.decode(String.self, forKey: .name))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setting(let path):
            try container.encode(Kind.setting, forKey: .type)
            try container.encode(path, forKey: .path)
        case .env(let name):
            try container.encode(Kind.env, forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}

extension Tweak.ValueType: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type, options, min, max, value
    }

    private enum Kind: String {
        case bool, enumeration = "enum", string, integer, path, flag, fixedString

        var keys: Set<CodingKeys> {
            switch self {
            case .enumeration: [.type, .options]
            case .integer: [.type, .min, .max]
            case .fixedString: [.type, .value]
            case .bool, .string, .path, .flag: [.type]
            }
        }
    }

    private var kind: Kind {
        switch self {
        case .bool: .bool
        case .enumeration: .enumeration
        case .string: .string
        case .integer: .integer
        case .path: .path
        case .flag: .flag
        case .fixedString: .fixedString
        }
    }

    /// The `type` text in the catalog file.
    public var name: String {
        kind.rawValue
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: name) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown value type \"\(name)\"")
        }
        if let foreign = container.allKeys.filter({ !kind.keys.contains($0) }).min(by: { $0.stringValue < $1.stringValue }) {
            throw DecodingError.dataCorruptedError(
                forKey: foreign, in: container, debugDescription: "Key \"\(foreign.stringValue)\" does not apply to type \"\(name)\"")
        }
        switch kind {
        case .bool: self = .bool
        case .enumeration: self = .enumeration(try container.decode([Tweak.Option].self, forKey: .options))
        case .string: self = .string
        case .integer:
            self = .integer(min: try container.decodeIfPresent(Int.self, forKey: .min), max: try container.decodeIfPresent(Int.self, forKey: .max))
        case .path: self = .path
        case .flag: self = .flag
        case .fixedString: self = .fixedString(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .type)
        switch self {
        case .enumeration(let options):
            try container.encode(options, forKey: .options)
        case .integer(let min, let max):
            try container.encodeIfPresent(min, forKey: .min)
            try container.encodeIfPresent(max, forKey: .max)
        case .fixedString(let value):
            try container.encode(value, forKey: .value)
        case .bool, .string, .path, .flag:
            break
        }
    }
}

extension Tweak.Suggestion: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value, label, note
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(String.self, forKey: .value)
        label = try container.decode(String.self, forKey: .label)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

extension Tweak.Option: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value, label
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(String.self, forKey: .value)
        label = try container.decode(String.self, forKey: .label)
    }
}

extension Tweak.Requirement: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tweakId, when, equals, behavior, reason
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tweakId = try container.decode(String.self, forKey: .tweakId)
        when = try container.decodeIfPresent(TweakValue.self, forKey: .when)
        equals = try container.decodeIfPresent(TweakValue.self, forKey: .equals)
        behavior = try container.decode(Behavior.self, forKey: .behavior)
        reason = try container.decode(String.self, forKey: .reason)
    }
}

extension Tweak.Confirmation: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case message, appliesWhen
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        appliesWhen = try container.decode(AppliesWhen.self, forKey: .appliesWhen)
    }
}

extension Tweak.Confirmation.AppliesWhen: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type, value
    }

    private enum Kind: String, Codable {
        case onEnable, onDisable, onAnyChange, whenValue
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .onEnable: self = .onEnable
        case .onDisable: self = .onDisable
        case .onAnyChange: self = .onAnyChange
        case .whenValue: self = .whenValue(try container.decode(TweakValue.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .onEnable: try container.encode(Kind.onEnable, forKey: .type)
        case .onDisable: try container.encode(Kind.onDisable, forKey: .type)
        case .onAnyChange: try container.encode(Kind.onAnyChange, forKey: .type)
        case .whenValue(let value):
            try container.encode(Kind.whenValue, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

extension Tweak.EnvOverride: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case envName, whenValue
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        envName = try container.decode(String.self, forKey: .envName)
        whenValue = try container.decodeIfPresent(String.self, forKey: .whenValue)
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String

    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

extension Decoder {
    fileprivate func rejectUnknownKeys<Key: CodingKey & CaseIterable>(besides keys: Key.Type) throws {
        let known = Set(keys.allCases.map(\.stringValue))
        let container = try container(keyedBy: AnyCodingKey.self)
        let unknown = container.allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
        guard let first = unknown.first else { return }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: codingPath + [AnyCodingKey(stringValue: first)], debugDescription: "Unknown key \"\(first)\""))
    }
}
