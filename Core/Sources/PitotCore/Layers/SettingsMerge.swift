/// Claude Code's merge of one settings value over a lower one.
///
/// Rule numbers refer to `Core/MERGE-RULES.md`.
/// - Objects merge key by key at every depth, and a higher object never removes a lower key.
///   Tested for `env`, `permissions` and `hooks` (rules 3, 5, 11, 13); inferred for other objects.
/// - Two arrays join, lower first, and repeated strings, numbers and Booleans are removed. Objects in an array never equal each other, so a hook entry from two
///   files stays twice. Joining is tested (rules 12, 14); removing repeats is inferred (rule 18).
///   An array that only one file sets is copied as it is.
/// - Any other pair: the higher value replaces the lower one, including a change of type.
/// - Key-name exceptions, at any depth, because only the key name decides them (rules 19 and 20): `fallbackModel` takes the higher array whole, `modelPicker` takes
///   the higher value whole, and each entry of `extraKnownMarketplaces` or `managedMcpServers`
///   replaces the lower entry with the same name whole.
enum SettingsMerge {
    static let entryWholeKeys: Set<String> = ["extraKnownMarketplaces", "managedMcpServers"]

    /// Keys a managed list sets alone: "when the managed settings Claude Code applies define it,
    /// Claude Code applies that list as-is and ignores entries you add in user, project, or local
    /// settings" (settings.md, `availableModels`). Inferred, rule 21.
    static let managedWholeKeys = ["availableModels"]

    static func fold(_ roots: [JSONValue]) -> JSONValue {
        roots.reduce(JSONValue.object([])) { merge($0, $1, key: nil) }
    }

    static func merge(_ lower: JSONValue?, _ upper: JSONValue, key: String?) -> JSONValue {
        guard let lower, combines(lower, upper, key: key) else { return upper }
        switch (lower, upper) {
        case (.array(let lowerElements), .array(let upperElements)):
            return .array(joined(lowerElements, upperElements))
        case (.object(let lowerMembers), .object(let upperMembers)):
            let entriesWhole = key.map(entryWholeKeys.contains) ?? false
            return .object(merged(lowerMembers, upperMembers, entriesWhole: entriesWhole))
        default:
            return upper
        }
    }

    /// Whether `upper` merges into `lower` instead of replacing it.
    static func combines(_ lower: JSONValue, _ upper: JSONValue, key: String?) -> Bool {
        if key == "modelPicker" { return false }
        switch (lower, upper) {
        case (.array, .array): return key != "fallbackModel"
        case (.object, .object): return true
        default: return false
        }
    }

    /// Whether the value under `key` replaces the lower value whole, whatever both values are.
    static func replacesWhole(key: String, parentKey: String?) -> Bool {
        key == "modelPicker" || parentKey.map(entryWholeKeys.contains) == true
    }

    static func joined(_ lower: [JSONValue], _ upper: [JSONValue]) -> [JSONValue] {
        var seen = Set<PrimitiveKey>()
        return (lower + upper).filter { element in
            guard let key = PrimitiveKey(element) else { return true }
            return seen.insert(key).inserted
        }
    }

    private static func merged(_ lower: [JSONValue.Member], _ upper: [JSONValue.Member], entriesWhole: Bool) -> [JSONValue.Member] {
        var members = lower
        for member in upper {
            guard let index = members.firstIndex(where: { SettingsTree.sameKey($0.key, member.key) }) else {
                members.append(member)
                continue
            }
            let value = entriesWhole ? member.value : merge(members[index].value, member.value, key: member.key)
            members[index] = JSONValue.Member(key: members[index].key, value: value)
        }
        return members
    }

    /// JavaScript `Set` equality for JSON primitives: strings by UTF-16 code units, numbers by value.
    private enum PrimitiveKey: Hashable {
        case null
        case bool(Bool)
        case number(Double)
        case string([UInt16])

        init?(_ value: JSONValue) {
            switch value {
            case .null: self = .null
            case .bool(let flag): self = .bool(flag)
            case .number(let number):
                guard let double = Double(number.text) else { return nil }
                self = .number(double)
            case .string(let text): self = .string(Array(text.utf16))
            case .array, .object: return nil
            }
        }
    }
}

/// A top-level key Claude Code reads only from some layers. Elsewhere it is ignored.
struct ScopedKey: Sendable {
    let key: String
    let readFrom: Set<LayerID>
    let quote: String

    /// From https://code.claude.com/docs/en/settings-reference.md, read 2026-10-06.
    static let all: [ScopedKey] = [
        ScopedKey(
            key: "modelPicker",
            readFrom: [.managed, .user],
            quote: "Claude Code reads the key from managed settings, `--settings`, and user settings, and ignores it in project and local settings"
        ),
        ScopedKey(
            key: "deniedModels",
            readFrom: [.managed],
            quote: "Claude Code ignores the key in user, project, and local settings and in `--settings`, with a warning"
        ),
        ScopedKey(key: "useAutoModeDuringPlan", readFrom: [.managed, .user, .local], quote: "User, local, or managed. A repository can't turn it off for you."),
        ScopedKey(key: "syncClaudeAiSkills", readFrom: [.managed, .user, .local], quote: "User, local, or managed, and files passed with `--settings`. A repository can't turn it off for you."),
        ScopedKey(key: "syncClaudeAiPlugins", readFrom: [.managed, .user, .local], quote: "User, local, or managed, and files passed with `--settings`. A repository can't turn it off for you."),
    ]

    static func rule(for key: String) -> ScopedKey? {
        all.first { $0.key == key }
    }

    /// `root` without the keys Claude Code ignores in `layer`.
    static func readable(_ root: JSONValue, in layer: LayerID) -> JSONValue {
        all.filter { !$0.readFrom.contains(layer) }.reduce(root) { SettingsTree.removing([$1.key], from: $0) }
    }
}
