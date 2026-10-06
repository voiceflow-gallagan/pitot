/// A read model of `~/.claude/keybindings.json`: binding blocks in file order.
///
/// Fields this model does not know are kept in `extras`, at the top level and in each block,
/// so an editor can write them back unchanged.
public struct KeybindingsFile: Sendable, Equatable {
    public struct Binding: Sendable, Equatable {
        public let key: String
        /// Nil when the file sets the action to `null`, which unbinds the key.
        public let action: String?
    }

    public struct Block: Sendable, Equatable {
        public let context: String
        /// File order. An empty list is a valid block.
        public let bindings: [Binding]
        public let extras: [JSONValue.Member]
    }

    public let schema: String?
    public let docs: String?
    public let blocks: [Block]
    public let extras: [JSONValue.Member]

    public init(document: JSONDocument) throws(KeybindingsFileError) {
        guard case .object(let members) = document.root.kind else { throw .rootNotObject }
        var schema: String?
        var docs: String?
        var blocks: [Block] = []
        var extras: [JSONValue.Member] = []
        for member in members {
            switch member.key {
            case "$schema":
                schema = Self.string(member.value, in: document)
                if schema == nil { extras.append(.init(key: member.key, value: document.decode(member.value))) }
            case "$docs":
                docs = Self.string(member.value, in: document)
                if docs == nil { extras.append(.init(key: member.key, value: document.decode(member.value))) }
            case "bindings":
                blocks = try Self.readBlocks(member.value, in: document)
            default:
                extras.append(.init(key: member.key, value: document.decode(member.value)))
            }
        }
        self.schema = schema
        self.docs = docs
        self.blocks = blocks
        self.extras = extras
    }

    private static func string(_ node: JSONNode, in document: JSONDocument) -> String? {
        if case .string(let value) = document.decode(node) { return value }
        return nil
    }

    private static func readBlocks(_ node: JSONNode, in document: JSONDocument) throws(KeybindingsFileError) -> [Block] {
        guard case .array(let elements) = node.kind else { throw .bindingsNotArray }
        var blocks: [Block] = []
        for (index, element) in elements.enumerated() {
            guard case .object(let members) = element.kind else { throw .blockNotObject(index: index) }
            var context: String?
            var bindings: [Binding] = []
            var extras: [JSONValue.Member] = []
            for member in members {
                switch member.key {
                case "context":
                    guard let value = string(member.value, in: document) else { throw .contextNotString(block: index) }
                    context = value
                case "bindings":
                    bindings = try readBindings(member.value, block: index, in: document)
                default:
                    extras.append(.init(key: member.key, value: document.decode(member.value)))
                }
            }
            guard let context else { throw .contextMissing(block: index) }
            blocks.append(Block(context: context, bindings: bindings, extras: extras))
        }
        return blocks
    }

    private static func readBindings(_ node: JSONNode, block: Int, in document: JSONDocument) throws(KeybindingsFileError) -> [Binding] {
        guard case .object(let members) = node.kind else { throw .blockBindingsNotObject(block: block) }
        var bindings: [Binding] = []
        for member in members {
            switch document.decode(member.value) {
            case .string(let action):
                bindings.append(Binding(key: member.key, action: action))
            case .null:
                bindings.append(Binding(key: member.key, action: nil))
            default:
                throw .actionNotStringOrNull(block: block, key: member.key)
            }
        }
        return bindings
    }
}

public enum KeybindingsFileError: Error, Equatable, Sendable {
    case rootNotObject
    case bindingsNotArray
    case blockNotObject(index: Int)
    case contextMissing(block: Int)
    case contextNotString(block: Int)
    case blockBindingsNotObject(block: Int)
    case actionNotStringOrNull(block: Int, key: String)
    /// The content for a new file does not scan, so the catalog header cannot be written as JSON.
    case initialContentInvalid(JSONScanError)
}
