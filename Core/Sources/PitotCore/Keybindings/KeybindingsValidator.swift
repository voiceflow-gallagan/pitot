/// Checks one binding against the catalog. Claude Code only logs these problems, so the
/// validator marks as `error` what Claude Code cannot apply as written and everything else as `warning`.
/// A warning never blocks an edit, because newer Claude Code versions add actions and contexts.
public struct KeybindingsValidator: Sendable {
    public struct Issue: Sendable, Equatable {
        public enum Severity: String, Sendable {
            case error
            case warning
        }

        public enum Kind: String, Sendable {
            case malformedKey
            case invalidActionValue
            case unknownContext
            case unknownAction
            case duplicateKey
            case reservedKey
            case bindingNotFound
        }

        public let severity: Severity
        public let kind: Kind
        public let message: String
    }

    public struct LocatedIssue: Sendable, Equatable {
        public let block: Int
        public let key: String
        public let issue: Issue
    }

    public let catalog: KeybindingsCatalog

    private let reserved: Set<String>

    public init(catalog: KeybindingsCatalog) {
        self.catalog = catalog
        reserved = Set(catalog.reservedKeys.filter(\.writable).compactMap { KeyString($0.key, syntax: catalog.keySyntax)?.normalized })
    }

    /// `action` is `.null` for an unbound key. `existingKeys` are the other keys already in the same context.
    public func check(context: String, key: String, action: JSONValue, existingKeys: [String] = []) -> [Issue] {
        var issues: [Issue] = []

        if catalog.context(named: context) == nil {
            issues.append(Issue(severity: .warning, kind: .unknownContext, message: "Unknown context \"\(context)\". Claude Code ignores this block."))
        }

        switch action {
        case .null:
            break
        case .string(let id):
            if catalog.action(id: id) == nil {
                issues.append(Issue(severity: .warning, kind: .unknownAction, message: "Unknown action \"\(id)\". Claude Code skips this binding. A newer version may know it."))
            }
        default:
            issues.append(Issue(severity: .error, kind: .invalidActionValue, message: "The action must be a string or null."))
        }

        guard let parsed = KeyString(key, syntax: catalog.keySyntax) else {
            issues.append(Issue(severity: .error, kind: .malformedKey, message: "\"\(key)\" is not a valid key. Check the modifiers and the key name."))
            return issues
        }
        if reserved.contains(parsed.normalized) {
            issues.append(Issue(severity: .warning, kind: .reservedKey, message: "\(key) is reserved and cannot be rebound."))
        }
        if existingKeys.contains(where: { KeyString($0, syntax: catalog.keySyntax)?.normalized == parsed.normalized }) {
            issues.append(Issue(severity: .warning, kind: .duplicateKey, message: "\(key) is bound twice in the \(context) context."))
        }
        return issues
    }

    /// Checks every binding in the file. A key counts as a duplicate when an earlier binding in a block
    /// with the same context has the same normalized key.
    public func check(file: KeybindingsFile) -> [LocatedIssue] {
        var seen: [String: [String]] = [:]
        var located: [LocatedIssue] = []
        for (blockIndex, block) in file.blocks.enumerated() {
            for binding in block.bindings {
                let action: JSONValue = binding.action.map { .string($0) } ?? .null
                let issues = check(context: block.context, key: binding.key, action: action, existingKeys: seen[block.context, default: []])
                located.append(contentsOf: issues.map { LocatedIssue(block: blockIndex, key: binding.key, issue: $0) })
                seen[block.context, default: []].append(binding.key)
            }
        }
        return located
    }
}
