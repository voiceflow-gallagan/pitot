public enum JSONEditError: Error, Equatable, Sendable {
    case invalidJSON(JSONScanError)
    case invalidRawValue(JSONScanError)
    case emptyPath
    /// The value at `path` is not an object, so it cannot hold the next key. `[]` is the root.
    case notAnObject(path: [String])
    case keyNotFound(path: [String])
    /// The value at `path` is not an array, so it has no elements.
    case notAnArray(path: [String])
    /// The array at `path` has `count` elements and no position `index`. Insert also accepts `index == count`.
    case indexOutOfRange(path: [String], index: Int, count: Int)
    /// The element at `index` of the array at `path` is not an object, so no key inside it can be edited.
    case elementNotAnObject(path: [String], index: Int)
    /// The file changed after the caller read it, so `index` may name another element of the array at
    /// `path` now. `SettingsFile` reports this instead of applying the operation to the new content.
    case staleElementIndex(path: [String], index: Int)
    /// The edit produced bytes that do not scan. This is a bug in `JSONEdit`.
    case producedInvalidJSON(JSONScanError)
}

/// Key-level and element-level edits that rewrite only the bytes of the targeted member or element.
///
/// Layout rules:
/// - Replacing a value rewrites only that value's byte range.
/// - A new key goes after the last sibling and copies that sibling's indent,
///   key/colon spacing and line ending. In a single-line object it is inserted
///   inline (`,"key":value`) and the object is not reformatted.
/// - An empty object takes the layout of the file: multi-line when the root
///   spans several lines or the file has no members at all, inline otherwise.
/// - Removing a key removes its comma, and its whole line in a multi-line object.
///   Removing the only key yields `{}`.
/// - Array elements follow the same rules, with `[]` for an empty array.
/// - A new key or element copies the separator of its neighbor. When that neighbor is the
///   first item of a single-line object or array, the separator comes from the second item,
///   else the padding inside the brackets, else `, ` when the nearest colon is followed by a
///   space and `,` when it is not.
/// - Number text, key order and every other byte are left alone.
public enum JSONEdit {
    public enum Value: Sendable, Equatable {
        case json(JSONValue)
        /// A complete JSON value, inserted verbatim after surrounding whitespace is trimmed.
        case raw([UInt8])
    }

    public enum Placement: Sendable, Equatable {
        case end
        case start
        /// Directly after the named sibling, or at the end when that sibling is gone.
        case after(String)
    }

    /// Paths are object keys. An element operation names the array by its key path and the element by its index.
    public enum Operation: Sendable, Equatable {
        case set(path: [String], value: Value, placement: Placement = .end)
        case remove(path: [String])
        case appendElement(path: [String], value: Value)
        /// `index` may equal the element count, which appends.
        case insertElement(path: [String], index: Int, value: Value)
        case replaceElement(path: [String], index: Int, value: Value)
        case removeElement(path: [String], index: Int)
        /// Applies `inner` to the object at `index`. The paths of `inner`, and of the errors it throws, start at that object.
        indirect case editElement(path: [String], index: Int, inner: Operation)

        /// The key this operation edits, or the array whose element it edits.
        public var path: [String] {
            switch self {
            case .set(let path, _, _), .remove(let path), .appendElement(let path, _), .insertElement(let path, _, _),
                .replaceElement(let path, _, _), .removeElement(let path, _), .editElement(let path, _, _):
                path
            }
        }

        /// The element this operation finds by its index. An index read from an older copy
        /// of the file can name another element in the current one.
        var elementPosition: (path: [String], index: Int)? {
            switch self {
            case .set, .remove, .appendElement:
                nil
            case .insertElement(let path, let index, _), .replaceElement(let path, let index, _), .removeElement(let path, let index),
                .editElement(let path, let index, _):
                (path, index)
            }
        }
    }

    /// What an edit did, at the outermost key whose value appeared, changed or disappeared.
    public struct Change: Sendable, Equatable {
        public let path: [String]
        /// Raw value bytes before the edit, or nil when the key was absent.
        public let before: [UInt8]?
        /// Raw value bytes after the edit, or nil when the key was removed.
        public let after: [UInt8]?
        /// Where the key sat among its siblings before the edit.
        public let restorePlacement: Placement
        /// Nil for a key edit. For an element edit, `path` is the array and `before` and `after` hold all of it.
        public let element: ElementChange?

        init(path: [String], before: [UInt8]?, after: [UInt8]?, restorePlacement: Placement, element: ElementChange? = nil) {
            self.path = path
            self.before = before
            self.after = after
            self.restorePlacement = restorePlacement
            self.element = element
        }

        public var inverse: Operation {
            if let element { return element.inverse(at: path) }
            guard let before else { return .remove(path: path) }
            return .set(path: path, value: .raw(before), placement: restorePlacement)
        }
    }

    /// What an element edit did to its array. Bytes are the element's raw bytes.
    public enum ElementChange: Sendable, Equatable {
        case added(index: Int, raw: [UInt8])
        case replaced(index: Int, before: [UInt8], after: [UInt8])
        case removed(index: Int, raw: [UInt8])
        /// `change` was made inside the object at `index`. Its paths start at that object.
        indirect case inside(index: Int, change: Change)

        func inverse(at path: [String]) -> Operation {
            switch self {
            case .added(let index, _): .removeElement(path: path, index: index)
            case .replaced(let index, let before, _): .replaceElement(path: path, index: index, value: .raw(before))
            case .removed(let index, let raw): .insertElement(path: path, index: index, value: .raw(raw))
            case .inside(let index, let change): .editElement(path: path, index: index, inner: change.inverse)
            }
        }
    }

    public struct Result: Sendable, Equatable {
        public let bytes: [UInt8]
        public let change: Change

        public var inverse: Operation { change.inverse }
    }

    public static func apply(_ operation: Operation, to bytes: [UInt8]) throws(JSONEditError) -> Result {
        let document: JSONDocument
        do throws(JSONScanError) {
            document = try JSONScanner.scan(bytes)
        } catch {
            throw .invalidJSON(error)
        }
        return try apply(operation, to: document)
    }

    public static func apply(_ operation: Operation, to document: JSONDocument) throws(JSONEditError) -> Result {
        let result = try Editor(document: document, base: document.root).apply(operation)
        do throws(JSONScanError) {
            _ = try JSONScanner.scan(result.bytes)
        } catch {
            throw .producedInvalidJSON(error)
        }
        return result
    }

    public static func set(
        _ path: [String],
        to value: Value,
        placement: Placement = .end,
        in bytes: [UInt8]
    ) throws(JSONEditError) -> Result {
        try apply(.set(path: path, value: value, placement: placement), to: bytes)
    }

    public static func remove(_ path: [String], in bytes: [UInt8]) throws(JSONEditError) -> Result {
        try apply(.remove(path: path), to: bytes)
    }
}

private let lineFeed: [UInt8] = [JSONGrammar.lineFeed]
private let crlf: [UInt8] = [JSONGrammar.carriageReturn, JSONGrammar.lineFeed]

private struct Layout {
    var multiLine: Bool
    var lineEnding: [UInt8]
    var indentUnit: [UInt8]
    var colon: [UInt8]
    /// Whitespace after each comma in an inline container.
    var inlineSpacing: [UInt8]
}

/// Placement of a new member or element next to an existing sibling, copied from that sibling.
private struct SiblingFormat {
    var layout: Layout
    /// Whitespace that precedes the sibling, normalized to one line ending plus indent.
    var leadingGap: [UInt8]
    /// Indent of the line that holds the sibling.
    var memberIndent: [UInt8]
}

private struct ArrayTarget {
    let node: JSONNode
    let elements: [JSONNode]
    /// Where the array's key sits among its siblings.
    let placement: JSONEdit.Placement
}

private struct Editor {
    let document: JSONDocument
    /// The object that paths start at: the root, or the element that `editElement` edits.
    let base: JSONNode

    var bytes: [UInt8] { document.bytes }

    func apply(_ operation: JSONEdit.Operation) throws(JSONEditError) -> JSONEdit.Result {
        guard !operation.path.isEmpty else { throw .emptyPath }
        switch operation {
        case .set(let path, let value, let placement):
            return try set(path, to: value, placement: placement)
        case .remove(let path):
            return try remove(path)
        case .appendElement(let path, let value):
            let target = try array(at: path)
            return try insert(value, at: target.elements.count, into: target, path: path)
        case .insertElement(let path, let index, let value):
            let target = try array(at: path)
            guard (0...target.elements.count).contains(index) else {
                throw .indexOutOfRange(path: path, index: index, count: target.elements.count)
            }
            return try insert(value, at: index, into: target, path: path)
        case .replaceElement(let path, let index, let value):
            return try replace(elementAt: index, of: try array(at: path, element: index), with: value, path: path)
        case .removeElement(let path, let index):
            return removeElement(at: index, of: try array(at: path, element: index), path: path)
        case .editElement(let path, let index, let inner):
            let target = try array(at: path, element: index)
            let element = target.elements[index]
            guard element.members != nil else { throw .elementNotAnObject(path: path, index: index) }
            let result = try Editor(document: document, base: element).apply(inner)
            return elementResult(result.bytes, in: target, path: path, element: .inside(index: index, change: result.change))
        }
    }

    func set(_ path: [String], to value: JSONEdit.Value, placement: JSONEdit.Placement) throws(JSONEditError) -> JSONEdit.Result {
        var object = base
        for depth in path.indices {
            guard let members = object.members else { throw .notAnObject(path: Array(path[..<depth])) }
            let key = path[depth]
            let isLeaf = depth == path.count - 1
            guard let index = members.firstIndex(where: { $0.hasKey(key) }) else {
                return try insert(
                    key: key,
                    into: object,
                    nestedKeys: path[(depth + 1)...],
                    leaf: value,
                    placement: isLeaf ? placement : .end,
                    changePath: Array(path[...depth])
                )
            }
            if isLeaf {
                return try replace(memberAt: index, of: object, with: value, path: path)
            }
            object = members[index].value
        }
        throw .emptyPath
    }

    func remove(_ path: [String]) throws(JSONEditError) -> JSONEdit.Result {
        let parentPath = Array(path.dropLast())
        let parent: JSONNode
        switch base.lookup(parentPath) {
        case .found(let node): parent = node
        case .absent: throw .keyNotFound(path: path)
        case .blocked(let blockedPath): throw .notAnObject(path: blockedPath)
        }
        guard let members = parent.members else { throw .notAnObject(path: parentPath) }
        guard let key = path.last, let index = members.firstIndex(where: { $0.hasKey(key) }) else {
            throw .keyNotFound(path: path)
        }
        let member = members[index]
        let deletion: Range<Int>
        if members.count == 1 {
            deletion = (parent.range.lowerBound + 1)..<(parent.range.upperBound - 1)
        } else if index < members.count - 1 {
            deletion = member.keyRange.lowerBound..<members[index + 1].keyRange.lowerBound
        } else {
            deletion = members[index - 1].value.range.upperBound..<member.value.range.upperBound
        }
        var output = bytes
        output.removeSubrange(deletion)
        let change = JSONEdit.Change(
            path: path,
            before: document.rawBytes(of: member.value),
            after: nil,
            restorePlacement: restorePlacement(ofMemberAt: index, in: members)
        )
        return JSONEdit.Result(bytes: output, change: change)
    }

    // MARK: Set helpers

    private func replace(memberAt index: Int, of object: JSONNode, with value: JSONEdit.Value, path: [String]) throws(JSONEditError) -> JSONEdit.Result {
        guard let members = object.members else { throw .notAnObject(path: Array(path.dropLast())) }
        let member = members[index]
        let format = siblingFormat(of: index, in: object, members: members)
        let text = try render(value, nestedIn: [], indent: format.memberIndent, layout: format.layout)
        var output = bytes
        output.replaceSubrange(member.value.range, with: text)
        let change = JSONEdit.Change(
            path: path,
            before: document.rawBytes(of: member.value),
            after: text,
            restorePlacement: restorePlacement(ofMemberAt: index, in: members)
        )
        return JSONEdit.Result(bytes: output, change: change)
    }

    private func insert(
        key: String,
        into object: JSONNode,
        nestedKeys: ArraySlice<String>,
        leaf: JSONEdit.Value,
        placement: JSONEdit.Placement,
        changePath: [String]
    ) throws(JSONEditError) -> JSONEdit.Result {
        let keyText = JSONGrammar.quoted(key)
        var output = bytes
        let valueText: [UInt8]
        let members = object.members ?? []
        if members.isEmpty {
            let filled = try fill(object, key: keyText, with: leaf, nestedIn: nestedKeys)
            valueText = filled.valueText
            output.replaceSubrange(object.range, with: filled.replacement)
        } else {
            let anchorIndex: Int? =
                switch placement {
                case .end: nil
                case .start: 0
                case .after(let sibling): members.firstIndex(where: { $0.hasKey(sibling) }).flatMap { $0 + 1 < members.count ? $0 + 1 : nil }
                }
            if let anchorIndex {
                let anchor = members[anchorIndex]
                let format = siblingFormat(of: anchorIndex, in: object, members: members)
                valueText = try render(leaf, nestedIn: nestedKeys, indent: format.memberIndent, layout: format.layout)
                let text = keyText + format.layout.colon + valueText + [JSONGrammar.comma] + format.leadingGap
                output.insert(contentsOf: text, at: anchor.keyRange.lowerBound)
            } else {
                let lastIndex = members.count - 1
                let format = siblingFormat(of: lastIndex, in: object, members: members)
                valueText = try render(leaf, nestedIn: nestedKeys, indent: format.memberIndent, layout: format.layout)
                let text = [JSONGrammar.comma] + format.leadingGap + keyText + format.layout.colon + valueText
                output.insert(contentsOf: text, at: members[lastIndex].value.range.upperBound)
            }
        }
        let change = JSONEdit.Change(path: changePath, before: nil, after: valueText, restorePlacement: .end)
        return JSONEdit.Result(bytes: output, change: change)
    }

    private func restorePlacement(ofMemberAt index: Int, in members: [JSONNode.Member]) -> JSONEdit.Placement {
        index == 0 ? .start : .after(members[index - 1].key)
    }

    /// The only item for an empty container, laid out like the file: `key` and the value
    /// for an object, the value alone for an array.
    private func fill(
        _ container: JSONNode,
        key: [UInt8]?,
        with value: JSONEdit.Value,
        nestedIn keys: ArraySlice<String>
    ) throws(JSONEditError) -> (replacement: [UInt8], valueText: [UInt8]) {
        let layout = documentLayout()
        let (open, close) = key == nil ? (JSONGrammar.openBracket, JSONGrammar.closeBracket) : (JSONGrammar.openBrace, JSONGrammar.closeBrace)
        let prefix = key.map { $0 + layout.colon } ?? []
        guard layout.multiLine else {
            let valueText = try render(value, nestedIn: keys, indent: [], layout: layout)
            return ([open] + prefix + valueText + [close], valueText)
        }
        let outerIndent = lineIndent(at: container.range.lowerBound)
        let innerIndent = outerIndent + layout.indentUnit
        let valueText = try render(value, nestedIn: keys, indent: innerIndent, layout: layout)
        let replacement = [open] + layout.lineEnding + innerIndent + prefix + valueText + layout.lineEnding + outerIndent + [close]
        return (replacement, valueText)
    }

    // MARK: Element helpers

    private func array(at path: [String]) throws(JSONEditError) -> ArrayTarget {
        var node = base
        var placement = JSONEdit.Placement.end
        for (depth, key) in path.enumerated() {
            guard let members = node.members else { throw .notAnObject(path: Array(path[..<depth])) }
            guard let index = members.firstIndex(where: { $0.hasKey(key) }) else { throw .keyNotFound(path: path) }
            placement = restorePlacement(ofMemberAt: index, in: members)
            node = members[index].value
        }
        guard case .array(let elements) = node.kind else { throw .notAnArray(path: path) }
        return ArrayTarget(node: node, elements: elements, placement: placement)
    }

    private func array(at path: [String], element index: Int) throws(JSONEditError) -> ArrayTarget {
        let target = try array(at: path)
        guard target.elements.indices.contains(index) else {
            throw .indexOutOfRange(path: path, index: index, count: target.elements.count)
        }
        return target
    }

    private func insert(_ value: JSONEdit.Value, at index: Int, into target: ArrayTarget, path: [String]) throws(JSONEditError) -> JSONEdit.Result {
        let elements = target.elements
        var output = bytes
        let valueText: [UInt8]
        if elements.isEmpty {
            let filled = try fill(target.node, key: nil, with: value, nestedIn: [])
            valueText = filled.valueText
            output.replaceSubrange(target.node.range, with: filled.replacement)
        } else if index == elements.count {
            let format = elementFormat(of: index - 1, in: target)
            valueText = try render(value, nestedIn: [], indent: format.memberIndent, layout: format.layout)
            output.insert(contentsOf: [JSONGrammar.comma] + format.leadingGap + valueText, at: elements[index - 1].range.upperBound)
        } else {
            let format = elementFormat(of: index, in: target)
            valueText = try render(value, nestedIn: [], indent: format.memberIndent, layout: format.layout)
            output.insert(contentsOf: valueText + [JSONGrammar.comma] + format.leadingGap, at: elements[index].range.lowerBound)
        }
        return elementResult(output, in: target, path: path, element: .added(index: index, raw: valueText))
    }

    private func replace(elementAt index: Int, of target: ArrayTarget, with value: JSONEdit.Value, path: [String]) throws(JSONEditError) -> JSONEdit.Result {
        let element = target.elements[index]
        let format = elementFormat(of: index, in: target)
        let text = try render(value, nestedIn: [], indent: format.memberIndent, layout: format.layout)
        var output = bytes
        output.replaceSubrange(element.range, with: text)
        let change = JSONEdit.ElementChange.replaced(index: index, before: document.rawBytes(of: element), after: text)
        return elementResult(output, in: target, path: path, element: change)
    }

    private func removeElement(at index: Int, of target: ArrayTarget, path: [String]) -> JSONEdit.Result {
        let elements = target.elements
        let element = elements[index]
        let deletion: Range<Int>
        if elements.count == 1 {
            deletion = (target.node.range.lowerBound + 1)..<(target.node.range.upperBound - 1)
        } else if index < elements.count - 1 {
            deletion = element.range.lowerBound..<elements[index + 1].range.lowerBound
        } else {
            deletion = elements[index - 1].range.upperBound..<element.range.upperBound
        }
        var output = bytes
        output.removeSubrange(deletion)
        return elementResult(output, in: target, path: path, element: .removed(index: index, raw: document.rawBytes(of: element)))
    }

    /// Every element edit changes bytes inside the array only, so the array keeps its
    /// start and its end moves by the change in length.
    private func elementResult(_ output: [UInt8], in target: ArrayTarget, path: [String], element: JSONEdit.ElementChange) -> JSONEdit.Result {
        let range = target.node.range
        let change = JSONEdit.Change(
            path: path,
            before: document.rawBytes(of: target.node),
            after: Array(output[range.lowerBound..<(range.upperBound + output.count - bytes.count)]),
            restorePlacement: target.placement,
            element: element
        )
        return JSONEdit.Result(bytes: output, change: change)
    }

    // MARK: Layout detection

    private func siblingFormat(of index: Int, in object: JSONNode, members: [JSONNode.Member]) -> SiblingFormat {
        let member = members[index]
        let colon = Array(bytes[member.keyRange.upperBound..<member.value.range.lowerBound])
        let gap = memberGap(of: index, in: object, members: members)
        let next = members.count > 1 ? memberGap(of: 1, in: object, members: members) : nil
        let separator = index == 0 ? firstSeparator(padding: gap, next: next, colon: colon) : nil
        return format(gap: gap, in: object, colon: colon, inlineSeparator: separator)
    }

    private func memberGap(of index: Int, in object: JSONNode, members: [JSONNode.Member]) -> Range<Int> {
        let start =
            index == 0
            ? object.range.lowerBound + 1
            : (members[index - 1].commaOffset ?? members[index - 1].value.range.upperBound) + 1
        return start..<members[index].keyRange.lowerBound
    }

    private func elementFormat(of index: Int, in target: ArrayTarget) -> SiblingFormat {
        let colon = firstMember(in: target.node).map { Array(bytes[$0.keyRange.upperBound..<$0.value.range.lowerBound]) } ?? documentLayout().colon
        let gap = elementGap(of: index, in: target)
        let next = target.elements.count > 1 ? elementGap(of: 1, in: target) : nil
        let separator = index == 0 ? firstSeparator(padding: gap, next: next, colon: colon) : nil
        return format(gap: gap, in: target.node, colon: colon, inlineSeparator: separator)
    }

    /// In a single-line container the gap after the opening bracket is padding, not a separator, so the
    /// first item takes its separator from the second item, else the padding, else the spacing of `colon`.
    private func firstSeparator(padding: Range<Int>, next: Range<Int>?, colon: [UInt8]) -> [UInt8] {
        if let next, !bytes[next].contains(JSONGrammar.lineFeed) { return Array(bytes[next]) }
        if !padding.isEmpty { return Array(bytes[padding]) }
        return colon.last == JSONGrammar.space ? [JSONGrammar.space] : []
    }

    private func elementGap(of index: Int, in target: ArrayTarget) -> Range<Int> {
        let elements = target.elements
        guard index > 0 else { return (target.node.range.lowerBound + 1)..<elements[0].range.lowerBound }
        let previousEnd = elements[index - 1].range.upperBound
        let comma = bytes[previousEnd..<elements[index].range.lowerBound].firstIndex(of: JSONGrammar.comma) ?? previousEnd
        return (comma + 1)..<elements[index].range.lowerBound
    }

    /// The format of the sibling that `gap` precedes. `inlineSeparator` replaces the gap when the sibling is on the same line.
    private func format(gap range: Range<Int>, in container: JSONNode, colon: [UInt8], inlineSeparator: [UInt8]?) -> SiblingFormat {
        let gap = bytes[range]
        guard let lastLineFeed = gap.lastIndex(of: JSONGrammar.lineFeed) else {
            let spacing = inlineSeparator ?? Array(gap)
            let layout = Layout(
                multiLine: false,
                lineEnding: documentLineEnding(),
                indentUnit: fileIndentUnit(),
                colon: colon,
                inlineSpacing: spacing
            )
            return SiblingFormat(layout: layout, leadingGap: spacing, memberIndent: lineIndent(at: range.upperBound))
        }
        let lineEnding = lastLineFeed > gap.startIndex && bytes[lastLineFeed - 1] == JSONGrammar.carriageReturn ? crlf : lineFeed
        let memberIndent = Array(bytes[(lastLineFeed + 1)..<range.upperBound])
        let containerIndent = lineIndent(at: container.range.lowerBound)
        let indentUnit =
            memberIndent.count > containerIndent.count && memberIndent.starts(with: containerIndent)
            ? Array(memberIndent.dropFirst(containerIndent.count))
            : fileIndentUnit()
        let layout = Layout(multiLine: true, lineEnding: lineEnding, indentUnit: indentUnit, colon: colon, inlineSpacing: [])
        return SiblingFormat(layout: layout, leadingGap: lineEnding + memberIndent, memberIndent: memberIndent)
    }

    private func documentLayout() -> Layout {
        let firstMember = firstMember(in: document.root)
        let multiLine = firstMember == nil || bytes[document.root.range].contains(JSONGrammar.lineFeed)
        let colon =
            firstMember.map { Array(bytes[$0.keyRange.upperBound..<$0.value.range.lowerBound]) }
            ?? (multiLine ? [JSONGrammar.colon, JSONGrammar.space] : [JSONGrammar.colon])
        return Layout(
            multiLine: multiLine,
            lineEnding: documentLineEnding(),
            indentUnit: fileIndentUnit(),
            colon: colon,
            inlineSpacing: []
        )
    }

    private func firstMember(in node: JSONNode) -> JSONNode.Member? {
        switch node.kind {
        case .object(let members):
            return members.first
        case .array(let elements):
            for element in elements {
                if let member = firstMember(in: element) { return member }
            }
            return nil
        case .string, .number, .bool, .null:
            return nil
        }
    }

    private func documentLineEnding() -> [UInt8] {
        guard let index = bytes.firstIndex(of: JSONGrammar.lineFeed) else { return lineFeed }
        return index > 0 && bytes[index - 1] == JSONGrammar.carriageReturn ? crlf : lineFeed
    }

    /// The leading whitespace of the first indented line, or two spaces.
    private func fileIndentUnit() -> [UInt8] {
        var lineStart = 0
        while lineStart < bytes.count {
            var index = lineStart
            while index < bytes.count, bytes[index] == JSONGrammar.space || bytes[index] == JSONGrammar.tab { index += 1 }
            if index > lineStart, index < bytes.count, !JSONGrammar.isWhitespace(bytes[index]) {
                return Array(bytes[lineStart..<index])
            }
            guard let lineFeedIndex = bytes[index...].firstIndex(of: JSONGrammar.lineFeed) else { break }
            lineStart = lineFeedIndex + 1
        }
        return [JSONGrammar.space, JSONGrammar.space]
    }

    private func lineIndent(at offset: Int) -> [UInt8] {
        let lineStart = bytes[..<offset].lastIndex(of: JSONGrammar.lineFeed).map { $0 + 1 } ?? 0
        var index = lineStart
        while index < offset, bytes[index] == JSONGrammar.space || bytes[index] == JSONGrammar.tab { index += 1 }
        return Array(bytes[lineStart..<index])
    }

    // MARK: Rendering

    private func render(
        _ value: JSONEdit.Value,
        nestedIn keys: ArraySlice<String>,
        indent: [UInt8],
        layout: Layout
    ) throws(JSONEditError) -> [UInt8] {
        if let key = keys.first {
            let inner = try render(value, nestedIn: keys.dropFirst(), indent: indent + layout.indentUnit, layout: layout)
            return container(
                open: JSONGrammar.openBrace, close: JSONGrammar.closeBrace, items: [JSONGrammar.quoted(key) + layout.colon + inner], indent: indent,
                layout: layout)
        }
        switch value {
        case .json(let json):
            return serialize(json, indent: indent, layout: layout)
        case .raw(let raw):
            do throws(JSONScanError) {
                let scanned = try JSONScanner.scan(raw)
                return Array(raw[scanned.root.range])
            } catch {
                throw .invalidRawValue(error)
            }
        }
    }

    private func serialize(_ value: JSONValue, indent: [UInt8], layout: Layout) -> [UInt8] {
        switch value {
        case .null:
            return Array("null".utf8)
        case .bool(let flag):
            return Array((flag ? "true" : "false").utf8)
        case .number(let number):
            return Array(number.text.utf8)
        case .string(let string):
            return JSONGrammar.quoted(string)
        case .array(let elements):
            guard !elements.isEmpty else { return [JSONGrammar.openBracket, JSONGrammar.closeBracket] }
            let items = elements.map { serialize($0, indent: indent + layout.indentUnit, layout: layout) }
            return container(open: JSONGrammar.openBracket, close: JSONGrammar.closeBracket, items: items, indent: indent, layout: layout)
        case .object(let members):
            guard !members.isEmpty else { return [JSONGrammar.openBrace, JSONGrammar.closeBrace] }
            let items = members.map { JSONGrammar.quoted($0.key) + layout.colon + serialize($0.value, indent: indent + layout.indentUnit, layout: layout) }
            return container(open: JSONGrammar.openBrace, close: JSONGrammar.closeBrace, items: items, indent: indent, layout: layout)
        }
    }

    private func container(open: UInt8, close: UInt8, items: [[UInt8]], indent: [UInt8], layout: Layout) -> [UInt8] {
        guard layout.multiLine else {
            return [open] + Array(items.joined(separator: [JSONGrammar.comma] + layout.inlineSpacing)) + [close]
        }
        let innerIndent = indent + layout.indentUnit
        let body = items.map { innerIndent + $0 }.joined(separator: [JSONGrammar.comma] + layout.lineEnding)
        return [open] + layout.lineEnding + Array(body) + layout.lineEnding + indent + [close]
    }
}

extension JSONGrammar {
    /// Quotes a string the way `JSON.stringify` does: only `"`, `\` and control
    /// characters are escaped, everything else stays raw UTF-8.
    static func quoted(_ string: String) -> [UInt8] {
        var output: [UInt8] = [JSONGrammar.quote]
        for byte in string.utf8 {
            switch byte {
            case JSONGrammar.quote: output += [JSONGrammar.backslash, JSONGrammar.quote]
            case JSONGrammar.backslash: output += [JSONGrammar.backslash, JSONGrammar.backslash]
            case 0x08: output += Array(#"\b"#.utf8)
            case 0x0C: output += Array(#"\f"#.utf8)
            case JSONGrammar.lineFeed: output += Array(#"\n"#.utf8)
            case JSONGrammar.carriageReturn: output += Array(#"\r"#.utf8)
            case JSONGrammar.tab: output += Array(#"\t"#.utf8)
            case 0x00..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                output += Array(#"\u00"#.utf8) + [hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
            default: output.append(byte)
            }
        }
        output.append(JSONGrammar.quote)
        return output
    }
}
