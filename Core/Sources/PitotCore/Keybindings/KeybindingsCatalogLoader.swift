import Foundation

public enum KeybindingsCatalogError: Error, Equatable, Sendable {
    /// The data is not a valid keybindings catalog. `path` names the failing field, such as `actions[3].contexts`.
    case malformed(path: String, reason: String)
    case lintFailed([KeybindingsLintIssue])
}

public struct KeybindingsLintIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Rule: String, Sendable {
        case missingDocURL
        case duplicateContext
        case duplicateActionId
        case unknownContext
        case namespaceMismatch
        case emptyDescription
        case invalidKey
        case duplicateReservedKey
        case invalidLegacy
        case unknownContextDefault
    }

    public let rule: Rule
    public let detail: String

    public init(rule: Rule, detail: String) {
        self.rule = rule
        self.detail = detail
    }

    public var description: String { detail }
}

public enum KeybindingsCatalogLoader {
    public static let docURLPrefix = "https://code.claude.com/docs/"

    /// Decodes and lints. A catalog with any lint issue is rejected.
    public static func load(data: Data) throws(KeybindingsCatalogError) -> KeybindingsCatalog {
        let catalog = try decode(data: data)
        let issues = lint(catalog)
        guard issues.isEmpty else { throw .lintFailed(issues) }
        return catalog
    }

    public static func decode(data: Data) throws(KeybindingsCatalogError) -> KeybindingsCatalog {
        do {
            return try JSONDecoder().decode(KeybindingsCatalog.self, from: data)
        } catch let error as DecodingError {
            throw KeybindingsCatalogError(error)
        } catch {
            throw .malformed(path: "", reason: String(describing: error))
        }
    }

    public static func lint(_ catalog: KeybindingsCatalog) -> [KeybindingsLintIssue] {
        var issues: [KeybindingsLintIssue] = []
        func add(_ rule: KeybindingsLintIssue.Rule, _ detail: String) {
            issues.append(KeybindingsLintIssue(rule: rule, detail: detail))
        }

        if !catalog.docURL.hasPrefix(docURLPrefix) {
            add(.missingDocURL, "docURL must start with \(docURLPrefix)")
        }

        var contextNames: Set<String> = []
        for context in catalog.contexts {
            if !contextNames.insert(context.name).inserted {
                add(.duplicateContext, "Context \"\(context.name)\" is listed twice")
            }
            if context.description.isEmpty {
                add(.emptyDescription, "Context \"\(context.name)\" has no description")
            }
        }

        var actionIds: Set<String> = []
        for action in catalog.actions {
            if !actionIds.insert(action.id).inserted {
                add(.duplicateActionId, "Action \"\(action.id)\" is listed twice")
            }
            if !action.id.hasPrefix("\(action.namespace):") {
                add(.namespaceMismatch, "Action \"\(action.id)\" does not start with its namespace \"\(action.namespace)\"")
            }
            if action.description.isEmpty {
                add(.emptyDescription, "Action \"\(action.id)\" has no description")
            }
            for name in action.contexts where !contextNames.contains(name) {
                add(.unknownContext, "Action \"\(action.id)\" names unknown context \"\(name)\"")
            }
            for name in (action.contextDefaults ?? [:]).keys.sorted() where !action.contexts.contains(name) {
                add(.unknownContextDefault, "Action \"\(action.id)\" has a default for \"\(name)\", which is not one of its contexts")
            }
            if action.legacy != (action.replacedBy != nil) {
                add(.invalidLegacy, "Action \"\(action.id)\" must set legacy and replacedBy together")
            } else if let target = action.replacedBy, catalog.action(id: target).map(\.legacy) != false {
                add(.invalidLegacy, "Action \"\(action.id)\" is replaced by \"\(target)\", which is not a current action")
            }
        }

        var reserved: Set<String> = []
        for entry in catalog.reservedKeys where entry.writable {
            guard let key = KeyString(entry.key, syntax: catalog.keySyntax) else {
                add(.invalidKey, "Reserved key \"\(entry.key)\" is not valid key syntax")
                continue
            }
            if !reserved.insert(key.normalized).inserted {
                add(.duplicateReservedKey, "Reserved key \"\(entry.key)\" is listed twice")
            }
        }
        return issues
    }
}

extension KeybindingsCatalogError {
    init(_ error: DecodingError) {
        switch error {
        case .typeMismatch(let type, let context):
            self = .malformed(path: Self.render(context.codingPath), reason: "Expected \(type). \(context.debugDescription)")
        case .valueNotFound(let type, let context):
            self = .malformed(path: Self.render(context.codingPath), reason: "Expected \(type), found null. \(context.debugDescription)")
        case .keyNotFound(let key, let context):
            self = .malformed(path: Self.render(context.codingPath + [key]), reason: "Missing key \"\(key.stringValue)\"")
        case .dataCorrupted(let context):
            self = .malformed(path: Self.render(context.codingPath), reason: context.debugDescription)
        @unknown default:
            self = .malformed(path: "", reason: String(describing: error))
        }
    }

    private static func render(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce(into: "") { text, key in
            if let index = key.intValue {
                text += "[\(index)]"
            } else {
                text += text.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
    }
}
