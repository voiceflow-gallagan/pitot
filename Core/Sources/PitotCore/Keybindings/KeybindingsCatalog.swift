import Foundation

/// The keybindings reference as data: contexts, actions and key syntax from the Claude Code docs.
///
/// JSON shape: see `Catalog/keybindings.json`. Unknown keys are rejected, like the settings catalog.
/// `defaultKey` is display text from the docs (for example `Ctrl+X Ctrl+K`), not a parsable key string.
public struct KeybindingsCatalog: Sendable, Equatable, Codable {
    public var researchDate: String
    public var claudeCodeVersionChecked: String
    public var docURL: String
    public var header: Header
    public var contexts: [Context]
    public var actions: [Action]
    public var keySyntax: KeySyntax
    public var reservedKeys: [ReservedKey]

    public func context(named name: String) -> Context? {
        contexts.first { $0.name == name }
    }

    public func action(id: String) -> Action? {
        actions.first { $0.id == id }
    }

    public struct Header: Sendable, Equatable, Codable {
        public var schema: String
        public var docs: String

        enum CodingKeys: String, CodingKey, CaseIterable { case schema, docs }

        public init(schema: String, docs: String) {
            self.schema = schema
            self.docs = docs
        }

        public init(from decoder: any Decoder) throws {
            try decoder.rejectUnknownKeybindingKeys(besides: CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schema = try container.decode(String.self, forKey: .schema)
            docs = try container.decode(String.self, forKey: .docs)
        }
    }

    public struct Context: Sendable, Equatable, Codable {
        public var name: String
        public var description: String

        enum CodingKeys: String, CodingKey, CaseIterable { case name, description }

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }

        public init(from decoder: any Decoder) throws {
            try decoder.rejectUnknownKeybindingKeys(besides: CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            description = try container.decode(String.self, forKey: .description)
        }
    }

    public struct Action: Sendable, Equatable, Codable {
        public var id: String
        public var namespace: String
        /// Empty when the docs do not name a context for the action.
        public var contexts: [String]
        public var description: String
        public var defaultKey: String?
        /// Display text per context, when the default differs between contexts. Keys are context names.
        public var contextDefaults: [String: String]?
        /// A legacy name that Claude Code still reads. Pickers hide it, files that use it stay valid.
        public var legacy: Bool
        /// The action that replaces a legacy one.
        public var replacedBy: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case id, namespace, contexts, description, defaultKey, contextDefaults, legacy, replacedBy
        }

        public init(
            id: String,
            namespace: String,
            contexts: [String],
            description: String,
            defaultKey: String? = nil,
            contextDefaults: [String: String]? = nil,
            legacy: Bool = false,
            replacedBy: String? = nil
        ) {
            self.id = id
            self.namespace = namespace
            self.contexts = contexts
            self.description = description
            self.defaultKey = defaultKey
            self.contextDefaults = contextDefaults
            self.legacy = legacy
            self.replacedBy = replacedBy
        }

        public init(from decoder: any Decoder) throws {
            try decoder.rejectUnknownKeybindingKeys(besides: CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            namespace = try container.decode(String.self, forKey: .namespace)
            contexts = try container.decode([String].self, forKey: .contexts)
            description = try container.decode(String.self, forKey: .description)
            defaultKey = try container.decodeIfPresent(String.self, forKey: .defaultKey)
            contextDefaults = try container.decodeIfPresent([String: String].self, forKey: .contextDefaults)
            legacy = try container.decodeIfPresent(Bool.self, forKey: .legacy) ?? false
            replacedBy = try container.decodeIfPresent(String.self, forKey: .replacedBy)
        }
    }

    public struct ReservedKey: Sendable, Equatable, Codable {
        public var key: String
        public var reason: String
        /// False for a key that cannot be written as a key string, such as Caps Lock. `key` is then a display name.
        public var writable: Bool

        enum CodingKeys: String, CodingKey, CaseIterable { case key, reason, writable }

        public init(key: String, reason: String, writable: Bool = true) {
            self.key = key
            self.reason = reason
            self.writable = writable
        }

        public init(from decoder: any Decoder) throws {
            try decoder.rejectUnknownKeybindingKeys(besides: CodingKeys.self)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            reason = try container.decode(String.self, forKey: .reason)
            writable = try container.decodeIfPresent(Bool.self, forKey: .writable) ?? true
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case researchDate, claudeCodeVersionChecked, docURL, header, contexts, actions, keySyntax, reservedKeys
    }

    public init(
        researchDate: String,
        claudeCodeVersionChecked: String,
        docURL: String,
        header: Header,
        contexts: [Context],
        actions: [Action],
        keySyntax: KeySyntax,
        reservedKeys: [ReservedKey]
    ) {
        self.researchDate = researchDate
        self.claudeCodeVersionChecked = claudeCodeVersionChecked
        self.docURL = docURL
        self.header = header
        self.contexts = contexts
        self.actions = actions
        self.keySyntax = keySyntax
        self.reservedKeys = reservedKeys
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeybindingKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        researchDate = try container.decode(String.self, forKey: .researchDate)
        claudeCodeVersionChecked = try container.decode(String.self, forKey: .claudeCodeVersionChecked)
        docURL = try container.decode(String.self, forKey: .docURL)
        header = try container.decode(Header.self, forKey: .header)
        contexts = try container.decode([Context].self, forKey: .contexts)
        actions = try container.decode([Action].self, forKey: .actions)
        keySyntax = try container.decode(KeySyntax.self, forKey: .keySyntax)
        reservedKeys = try container.decode([ReservedKey].self, forKey: .reservedKeys)
    }
}

/// How a key string is written. Names are lowercase. Matching is case-insensitive.
public struct KeySyntax: Sendable, Equatable, Codable {
    /// Canonical modifier names. The order is the order used by `KeyString.normalized`.
    public var modifiers: [String]
    /// Alternative spelling to canonical name, for modifiers and special keys.
    public var aliases: [String: String]
    public var specialKeys: [String]
    public var chordSeparator: String
    public var notes: [String]

    enum CodingKeys: String, CodingKey, CaseIterable { case modifiers, aliases, specialKeys, chordSeparator, notes }

    public init(modifiers: [String], aliases: [String: String], specialKeys: [String], chordSeparator: String, notes: [String]) {
        self.modifiers = modifiers
        self.aliases = aliases
        self.specialKeys = specialKeys
        self.chordSeparator = chordSeparator
        self.notes = notes
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeybindingKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modifiers = try container.decode([String].self, forKey: .modifiers)
        aliases = try container.decode([String: String].self, forKey: .aliases)
        specialKeys = try container.decode([String].self, forKey: .specialKeys)
        chordSeparator = try container.decode(String.self, forKey: .chordSeparator)
        notes = try container.decode([String].self, forKey: .notes)
    }
}

struct KeybindingsAnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

extension Decoder {
    func rejectUnknownKeybindingKeys<Key: CodingKey & CaseIterable>(besides keys: Key.Type) throws {
        let container = try container(keyedBy: KeybindingsAnyKey.self)
        let known = Set(keys.allCases.map(\.stringValue))
        guard let first = container.allKeys.map(\.stringValue).filter({ !known.contains($0) }).min() else { return }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: codingPath + [KeybindingsAnyKey(stringValue: first)], debugDescription: "Unknown key \"\(first)\""))
    }
}
