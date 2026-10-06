import Foundation

/// The onboarding questions, as data. Each answer option lists the tweak values it sets.
///
/// JSON shape: `{"questions": [{"id", "title", "hint"?, "options": [{"id", "label", "hint"?, "profile", "sets": [...]}]}]}`.
/// `sets` is a list of `{"tweakId": ..., "value": ...}` so the file order is the order the user sees.
/// A `null` value removes the key. Unknown keys are rejected, like the catalog.
public struct OnboardingFile: Sendable, Equatable {
    public var questions: [Question]

    public init(questions: [Question]) {
        self.questions = questions
    }

    public func question(id: String) -> Question? {
        questions.first { $0.id == id }
    }

    public struct Question: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var hint: String?
        public var options: [Option]

        public init(id: String, title: String, hint: String? = nil, options: [Option]) {
            self.id = id
            self.title = title
            self.hint = hint
            self.options = options
        }

        public func option(id: String) -> Option? {
            options.first { $0.id == id }
        }
    }

    public struct Option: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var hint: String?
        public var profile: Profile
        /// An empty list keeps the current settings.
        public var sets: [Assignment]

        public init(id: String, label: String, hint: String? = nil, profile: Profile, sets: [Assignment]) {
            self.id = id
            self.label = label
            self.hint = hint
            self.profile = profile
            self.sets = sets
        }
    }

    public struct Assignment: Sendable, Equatable {
        public var tweakId: String
        /// Nil removes the key.
        public var value: TweakValue?

        public init(tweakId: String, value: TweakValue?) {
            self.tweakId = tweakId
            self.value = value
        }
    }

    /// The preset an answer leans to. The label shown at the end is the most frequent one.
    public enum Profile: String, Codable, Sendable, CaseIterable {
        case cautious, balanced, power

        public var title: String {
            switch self {
            case .cautious: "Cautious"
            case .balanced: "Balanced"
            case .power: "Power user"
            }
        }
    }
}

// MARK: Codable

extension OnboardingFile: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case questions
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownOnboardingKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        questions = try container.decode([Question].self, forKey: .questions)
    }
}

extension OnboardingFile.Question: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, title, hint, options
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownOnboardingKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        hint = try container.decodeIfPresent(String.self, forKey: .hint)
        options = try container.decode([OnboardingFile.Option].self, forKey: .options)
    }
}

extension OnboardingFile.Option: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, hint, profile, sets
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownOnboardingKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        hint = try container.decodeIfPresent(String.self, forKey: .hint)
        profile = try container.decode(OnboardingFile.Profile.self, forKey: .profile)
        sets = try container.decode([OnboardingFile.Assignment].self, forKey: .sets)
    }
}

/// `value` is required so a forgotten value fails to load instead of removing the key.
extension OnboardingFile.Assignment: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tweakId, value
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownOnboardingKeys(besides: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tweakId = try container.decode(String.self, forKey: .tweakId)
        guard container.contains(.value) else {
            throw DecodingError.keyNotFound(
                CodingKeys.value, DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing key \"value\""))
        }
        value = try container.decodeNil(forKey: .value) ? nil : container.decode(TweakValue.self, forKey: .value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tweakId, forKey: .tweakId)
        if let value {
            try container.encode(value, forKey: .value)
        } else {
            try container.encodeNil(forKey: .value)
        }
    }
}

struct OnboardingCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension Decoder {
    fileprivate func rejectUnknownOnboardingKeys<Key: CodingKey & CaseIterable>(besides keys: Key.Type) throws {
        let known = Set(keys.allCases.map(\.stringValue))
        let container = try container(keyedBy: OnboardingCodingKey.self)
        let unknown = container.allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
        guard let first = unknown.first else { return }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: codingPath + [OnboardingCodingKey(stringValue: first)], debugDescription: "Unknown key \"\(first)\""))
    }
}
