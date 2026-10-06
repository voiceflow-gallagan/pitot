/// Turns keybinding edits into `JSONEdit` operations. It does no I/O.
///
/// Operations apply to `document`, or to `initialContent` when the file does not exist yet.
/// Only the targeted binding or block changes. Other blocks and unknown fields keep their bytes.
public struct KeybindingsEditor: Sendable {
    public struct Plan: Sendable, Equatable {
        public let operations: [JSONEdit.Operation]
        public let issues: [KeybindingsValidator.Issue]
        public let notes: [String]
        /// True when the file is missing and the operations apply to `initialContent`.
        public let createsFile: Bool

        /// A keybindings file may hold `null` (it unbinds a key), and undoing a change restores one.
        /// The app must let writes of this plan through any guard that refuses `null` in settings files.
        public var allowsNullValues: Bool { true }

        /// An error issue means nothing may be applied.
        public var isBlocked: Bool {
            issues.contains { $0.severity == .error }
        }
    }

    public struct BlockSummary: Sendable, Equatable {
        public let context: String
        public let rows: [Row]
    }

    public struct Row: Sendable, Equatable {
        public let key: String
        /// Nil when the key is unbound.
        public let action: String?
        public let issues: [KeybindingsValidator.Issue]
        public let isLegacyAction: Bool
        public let description: String?
        public let defaultKey: String?
    }

    public let catalog: KeybindingsCatalog
    public let file: KeybindingsFile
    public let createsFile: Bool

    private let validator: KeybindingsValidator
    private let bindingsFieldPresence: [Bool]
    private let hasBindingsArray: Bool

    /// `document` is nil when the file does not exist.
    public init(catalog: KeybindingsCatalog, document: JSONDocument?) throws(KeybindingsFileError) {
        self.catalog = catalog
        validator = KeybindingsValidator(catalog: catalog)
        createsFile = document == nil
        let source: JSONDocument
        if let document {
            source = document
        } else {
            source = try Self.scanInitialContent(Self.makeInitialContent(catalog: catalog))
        }
        file = try KeybindingsFile(document: source)
        (hasBindingsArray, bindingsFieldPresence) = Self.shape(of: source)
    }

    /// The docs header and an empty `bindings` array, for creating the file.
    public static func initialContent(catalog: KeybindingsCatalog) throws(KeybindingsFileError) -> [UInt8] {
        let bytes = makeInitialContent(catalog: catalog)
        _ = try scanInitialContent(bytes)
        return bytes
    }

    static func scanInitialContent(_ bytes: [UInt8]) throws(KeybindingsFileError) -> JSONDocument {
        do {
            return try JSONScanner.scan(bytes)
        } catch {
            throw .initialContentInvalid(error)
        }
    }

    private static func makeInitialContent(catalog: KeybindingsCatalog) -> [UInt8] {
        let text = """
            {
              "$schema": \(Self.quoted(catalog.header.schema)),
              "$docs": \(Self.quoted(catalog.header.docs)),
              "bindings": []
            }

            """
        return Array(text.utf8)
    }

    private static func quoted(_ text: String) -> String {
        String(decoding: JSONGrammar.quoted(text), as: UTF8.self)
    }

    public func addBinding(context: String, key: String, action: String) -> Plan {
        let issues = validator.check(context: context, key: key, action: .string(action))
        let notes = legacyNotes(for: action)
        guard !issues.contains(where: { $0.severity == .error }) else { return plan([], issues, notes) }
        if existing(context: context, key: key) != nil {
            return plan([], issues + [duplicate(key, context)], notes)
        }
        return plan(setOperations(context: context, key: key, value: .string(action)), issues, notes)
    }

    public func changeAction(context: String, key: String, newAction: String) -> Plan {
        let notes = legacyNotes(for: newAction)
        guard let found = existing(context: context, key: key) else { return plan([], [missing(key, context)], notes) }
        let issues = validator.check(context: context, key: found.key, action: .string(newAction))
        guard !issues.contains(where: { $0.severity == .error }) else { return plan([], issues, notes) }
        return plan([edit(block: found.block, .set(path: ["bindings", found.key], value: .json(.string(newAction))))], issues, notes)
    }

    /// Sets the key to `null`, which unbinds a default shortcut.
    public func unbind(context: String, key: String) -> Plan {
        guard let found = existing(context: context, key: key) else { return plan([], [missing(key, context)], []) }
        return plan([edit(block: found.block, .set(path: ["bindings", found.key], value: .json(.null)))], [], [])
    }

    /// Removes the key. A block left without bindings and without other fields is removed too.
    public func removeBinding(context: String, key: String) -> Plan {
        guard let found = existing(context: context, key: key) else { return plan([], [missing(key, context)], []) }
        let block = file.blocks[found.block]
        if block.bindings.count == 1, block.extras.isEmpty {
            return plan([.removeElement(path: ["bindings"], index: found.block)], [], [])
        }
        return plan([edit(block: found.block, .remove(path: ["bindings", found.key]))], [], [])
    }

    public func summary(of file: KeybindingsFile) -> [BlockSummary] {
        let located = validator.check(file: file)
        return file.blocks.enumerated().map { index, block in
            let rows = block.bindings.map { binding -> Row in
                let issues = located.filter { $0.block == index && $0.key == binding.key }.map(\.issue)
                let entry = binding.action.flatMap { catalog.action(id: $0) }
                return Row(
                    key: binding.key,
                    action: binding.action,
                    issues: issues,
                    isLegacyAction: entry?.legacy ?? false,
                    description: entry?.description,
                    defaultKey: entry.flatMap { $0.contextDefaults?[block.context] ?? $0.defaultKey })
            }
            return BlockSummary(context: block.context, rows: rows)
        }
    }

    public func summary() -> [BlockSummary] {
        summary(of: file)
    }

    private func plan(_ operations: [JSONEdit.Operation], _ issues: [KeybindingsValidator.Issue], _ notes: [String]) -> Plan {
        Plan(operations: operations, issues: issues, notes: notes, createsFile: createsFile)
    }

    private func edit(block: Int, _ inner: JSONEdit.Operation) -> JSONEdit.Operation {
        .editElement(path: ["bindings"], index: block, inner: inner)
    }

    private func setOperations(context: String, key: String, value: JSONValue) -> [JSONEdit.Operation] {
        if let block = file.blocks.firstIndex(where: { $0.context == context }) {
            if bindingsFieldPresence.indices.contains(block), bindingsFieldPresence[block] {
                return [edit(block: block, .set(path: ["bindings", key], value: .json(value)))]
            }
            return [edit(block: block, .set(path: ["bindings"], value: .json(.object([.init(key: key, value: value)]))))]
        }
        let newBlock = JSONValue.object([
            .init(key: "context", value: .string(context)),
            .init(key: "bindings", value: .object([.init(key: key, value: value)])),
        ])
        if hasBindingsArray {
            return [.appendElement(path: ["bindings"], value: .json(newBlock))]
        }
        return [.set(path: ["bindings"], value: .json(.array([newBlock])))]
    }

    private func existing(context: String, key: String) -> (block: Int, key: String)? {
        guard let wanted = KeyString(key, syntax: catalog.keySyntax)?.normalized else { return nil }
        for (index, block) in file.blocks.enumerated() where block.context == context {
            if let binding = block.bindings.first(where: { KeyString($0.key, syntax: catalog.keySyntax)?.normalized == wanted }) {
                return (index, binding.key)
            }
        }
        return nil
    }

    private func legacyNotes(for action: String) -> [String] {
        guard let entry = catalog.action(id: action), entry.legacy else { return [] }
        let replacement = entry.replacedBy.map { " Use \($0) instead." } ?? ""
        return ["\(action) is a legacy action name that Claude Code still reads.\(replacement)"]
    }

    private func duplicate(_ key: String, _ context: String) -> KeybindingsValidator.Issue {
        .init(severity: .error, kind: .duplicateKey, message: "\(key) is already bound in the \(context) context.")
    }

    private func missing(_ key: String, _ context: String) -> KeybindingsValidator.Issue {
        .init(severity: .error, kind: .bindingNotFound, message: "\(key) is not bound in the \(context) context.")
    }

    /// Whether the root has a `bindings` array, and for each block whether it has a `bindings` field.
    private static func shape(of document: JSONDocument) -> (Bool, [Bool]) {
        guard case .array(let elements)? = document.node(at: ["bindings"])?.kind else { return (false, []) }
        let presence = elements.map { element -> Bool in
            guard case .object(let members) = element.kind else { return false }
            return members.contains { $0.key == "bindings" }
        }
        return (true, presence)
    }
}
