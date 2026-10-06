import Foundation
import Testing

@testable import PitotCore

@Suite("Edit fuzz")
struct JSONEditFuzzTests {
    @Test("1000 random documents and edits keep every untouched byte and key order")
    func randomEdits() throws {
        var random = SplitMix64(seed: 0xC0C4_F117)
        for iteration in 0..<1000 {
            let style = FuzzStyle.random(using: &random)
            var model = FuzzGenerator.object(depth: 0, using: &random)
            var bytes = [UInt8](FuzzWriter(style: style).document(model))
            for step in 0..<Int.random(in: 1...3, using: &random) {
                let context = "iteration \(iteration) step \(step)"
                let before = try JSONScanner.scan(bytes)
                let operation = FuzzGenerator.operation(for: model, using: &random)
                let result = try JSONEdit.apply(operation, to: bytes)

                #expect(throws: Never.self, "\(context): JSONSerialization") {
                    _ = try JSONSerialization.jsonObject(with: Data(result.bytes))
                }
                let after = try JSONScanner.scan(result.bytes)
                let touched = operation.path
                for path in memberPaths(in: before.root, document: before, prefix: []) where !related(path, touched) {
                    let original = before.node(at: path).map(before.rawBytes)
                    let edited = after.node(at: path).map(after.rawBytes)
                    #expect(original == edited, "\(context): bytes of \(path) changed")
                }
                for objectPath in objectPaths(in: before.root, document: before, prefix: []) where !touched.isPrefix(of: objectPath) {
                    let untouched = (before.node(at: objectPath)?.members ?? []).map(\.key).filter { !related(objectPath + [$0], touched) }
                    let resultKeys = (after.node(at: objectPath)?.members ?? []).map(\.key).filter { key in
                        untouched.contains { Array($0.utf16) == Array(key.utf16) }
                    }
                    #expect(resultKeys == untouched, "\(context): key order of \(objectPath) changed")
                }
                model = FuzzModel.apply(operation, to: model)
                #expect(after.value(at: []) == model, "\(context): decoded result differs from model")

                if !isOnlyMemberRemoval(operation, in: before) {
                    #expect(try JSONEdit.apply(result.inverse, to: result.bytes).bytes == bytes, "\(context): inverse")
                }
                bytes = result.bytes
            }
        }
    }

    @Test("1000 random lists of object and array edits keep untouched elements and undo as a group")
    func randomArrayEdits() throws {
        var random = SplitMix64(seed: 0xA77A_7E57)
        for iteration in 0..<1000 {
            let style = FuzzStyle.random(using: &random)
            let originalModel = ArrayFuzz.document(using: &random)
            let original = [UInt8](FuzzWriter(style: style).document(originalModel))
            var model = originalModel
            var bytes = original
            var changes: [JSONEdit.Change] = []
            var emptiedAContainer = false
            for step in 0..<Int.random(in: 1...4, using: &random) {
                let context = "iteration \(iteration) step \(step)"
                let before = try JSONScanner.scan(bytes)
                let operation = ArrayFuzz.operation(for: model, using: &random)
                emptiedAContainer = emptiedAContainer || ArrayFuzz.emptiesAContainer(operation, in: model)
                let result = try JSONEdit.apply(operation, to: bytes)

                #expect(throws: Never.self, "\(context): JSONSerialization") {
                    _ = try JSONSerialization.jsonObject(with: Data(result.bytes))
                }
                let after = try JSONScanner.scan(result.bytes)
                let touched = operation.path
                for path in memberPaths(in: before.root, document: before, prefix: []) where !related(path, touched) {
                    let original = before.node(at: path).map(before.rawBytes)
                    let edited = after.node(at: path).map(after.rawBytes)
                    #expect(original == edited, "\(context): bytes of \(path) changed")
                }
                for objectPath in objectPaths(in: before.root, document: before, prefix: []) where !touched.isPrefix(of: objectPath) {
                    let untouched = (before.node(at: objectPath)?.members ?? []).map(\.key).filter { !related(objectPath + [$0], touched) }
                    let resultKeys = (after.node(at: objectPath)?.members ?? []).map(\.key).filter { key in
                        untouched.contains { Array($0.utf16) == Array(key.utf16) }
                    }
                    #expect(resultKeys == untouched, "\(context): key order of \(objectPath) changed")
                }
                if let expected = ArrayFuzz.untouchedElements(of: operation, before: before, after: after) {
                    #expect(expected.after == expected.before, "\(context): untouched elements of \(touched) changed")
                }
                model = FuzzModel.apply(operation, to: model)
                #expect(after.value(at: []) == model, "\(context): decoded result differs from model")
                changes.append(result.change)
                bytes = result.bytes
            }
            var undone = bytes
            for change in changes.reversed() {
                undone = try JSONEdit.apply(change.inverse, to: undone).bytes
            }
            #expect(try JSONScanner.scan(undone).value(at: []) == originalModel, "iteration \(iteration): group undo")
            if !emptiedAContainer {
                #expect(undone == original, "iteration \(iteration): group undo bytes")
            }
        }
    }

    private func related(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.isPrefix(of: rhs) || rhs.isPrefix(of: lhs)
    }

    private func isOnlyMemberRemoval(_ operation: JSONEdit.Operation, in document: JSONDocument) -> Bool {
        guard case .remove(let path) = operation else { return false }
        return document.node(at: Array(path.dropLast()))?.members?.count == 1
    }
}

extension Array where Element == String {
    func isPrefix(of other: [String]) -> Bool {
        count <= other.count && zip(self, other).allSatisfy { [UInt16]($0.utf16) == [UInt16]($1.utf16) }
    }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

struct FuzzStyle {
    var multiLine: Bool
    var indentUnit: String
    var lineEnding: String
    var colon: String
    var inlineSpacing: String
    var trailingNewline: Bool

    static func random(using random: inout SplitMix64) -> FuzzStyle {
        let trailingNewline = Bool.random(using: &random)
        switch Int.random(in: 0..<6, using: &random) {
        case 0: return FuzzStyle(multiLine: false, indentUnit: "", lineEnding: "\n", colon: ":", inlineSpacing: "", trailingNewline: trailingNewline)
        case 1: return FuzzStyle(multiLine: false, indentUnit: "", lineEnding: "\n", colon: ": ", inlineSpacing: " ", trailingNewline: trailingNewline)
        case 2: return FuzzStyle(multiLine: true, indentUnit: "  ", lineEnding: "\n", colon: ": ", inlineSpacing: "", trailingNewline: trailingNewline)
        case 3: return FuzzStyle(multiLine: true, indentUnit: "    ", lineEnding: "\r\n", colon: ": ", inlineSpacing: "", trailingNewline: trailingNewline)
        case 4: return FuzzStyle(multiLine: true, indentUnit: "\t", lineEnding: "\n", colon: ": ", inlineSpacing: "", trailingNewline: trailingNewline)
        default: return FuzzStyle(multiLine: true, indentUnit: "  ", lineEnding: "\n", colon: " : ", inlineSpacing: "", trailingNewline: trailingNewline)
        }
    }
}

enum FuzzGenerator {
    static let keys = ["a", "b", "c", "theme", "10", "2", "\u{E9}", "e\u{301}", "k\"q", "sp ace", "back\\slash", "env"]
    static let strings = ["", "plain", "with \"quote\"", "back\\slash", "line\nfeed", "tab\t", "ctl\u{1}", "caf\u{E9} \u{1F600}", "\u{2028}", "/"]
    static let numbers = ["0", "-0", "1e3", "0.10", "12345678901234567890", "-12.5E-3", "1E+2", "42"]

    static func object(depth: Int, using random: inout SplitMix64) -> JSONValue {
        let count = Int.random(in: 0...(depth == 0 ? 6 : 4), using: &random)
        var members: [JSONValue.Member] = []
        for key in keys.shuffled(using: &random).prefix(count) {
            members.append(JSONValue.Member(key: key, value: value(depth: depth + 1, using: &random)))
        }
        return .object(members)
    }

    static func value(depth: Int, using random: inout SplitMix64) -> JSONValue {
        let roll = Int.random(in: 0..<10, using: &random)
        switch roll {
        case 0: return .null
        case 1: return .bool(Bool.random(using: &random))
        case 2, 3: return .number(JSONNumber(validatedText: numbers.randomElement(using: &random) ?? "0"))
        case 4, 5: return .string(strings.randomElement(using: &random) ?? "")
        case 6 where depth < 3:
            return .array((0..<Int.random(in: 0...3, using: &random)).map { _ in value(depth: depth + 1, using: &random) })
        case 7 where depth < 3, 8 where depth < 3:
            return object(depth: depth, using: &random)
        default:
            return .string("leaf")
        }
    }

    static func operation(for model: JSONValue, using random: inout SplitMix64) -> JSONEdit.Operation {
        let members = FuzzModel.memberPaths(model)
        let objects = FuzzModel.objectPaths(model)
        let newValue: JSONEdit.Value =
            Int.random(in: 0..<10, using: &random) == 0
            ? .raw([UInt8](FuzzWriter(style: FuzzStyle.random(using: &random)).value(value(depth: 1, using: &random))))
            : .json(value(depth: 1, using: &random))
        let roll = Int.random(in: 0..<10, using: &random)
        if roll < 3, let path = members.randomElement(using: &random) {
            return .set(path: path, value: newValue)
        }
        if roll < 6, let path = members.randomElement(using: &random) {
            return .remove(path: path)
        }
        let parent = objects.randomElement(using: &random) ?? []
        let existing = FuzzModel.keys(at: parent, in: model)
        let fresh = (keys + ["new1", "new2", "new3"]).filter { key in !existing.contains { Array($0.utf16) == Array(key.utf16) } }
        let key = fresh.randomElement(using: &random) ?? "fallback"
        let extra = roll == 9 ? ["deeper", "leaf"].prefix(Int.random(in: 1...2, using: &random)) : []
        let placement: JSONEdit.Placement =
            switch Int.random(in: 0..<4, using: &random) {
            case 0: .start
            case 1: .after(existing.randomElement(using: &random) ?? "none")
            default: .end
            }
        return .set(path: parent + [key] + extra, value: newValue, placement: placement)
    }
}

enum FuzzModel {
    static func memberPaths(_ value: JSONValue, prefix: [String] = []) -> [[String]] {
        guard case .object(let members) = value else { return [] }
        return members.flatMap { [prefix + [$0.key]] + memberPaths($0.value, prefix: prefix + [$0.key]) }
    }

    static func objectPaths(_ value: JSONValue, prefix: [String] = []) -> [[String]] {
        guard case .object(let members) = value else { return [] }
        return [prefix] + members.flatMap { objectPaths($0.value, prefix: prefix + [$0.key]) }
    }

    static func keys(at path: [String], in value: JSONValue) -> [String] {
        guard case .object(let members) = lookup(path, in: value) else { return [] }
        return members.map(\.key)
    }

    static func lookup(_ path: [String], in value: JSONValue) -> JSONValue? {
        guard let key = path.first else { return value }
        guard case .object(let members) = value,
            let member = members.first(where: { Array($0.key.utf16) == Array(key.utf16) })
        else { return nil }
        return lookup(Array(path.dropFirst()), in: member.value)
    }

    static func apply(_ operation: JSONEdit.Operation, to value: JSONValue) -> JSONValue {
        switch operation {
        case .set(let path, let newValue, let placement):
            return set(path[...], to: decode(newValue), placement: placement, in: value)
        case .remove(let path):
            return remove(path[...], in: value)
        case .appendElement(let path, let newValue):
            return updateArray(path[...], in: value) { $0 + [decode(newValue)] }
        case .insertElement(let path, let index, let newValue):
            return updateArray(path[...], in: value) { elements in
                var elements = elements
                elements.insert(decode(newValue), at: index)
                return elements
            }
        case .replaceElement(let path, let index, let newValue):
            return updateArray(path[...], in: value) { elements in
                var elements = elements
                elements[index] = decode(newValue)
                return elements
            }
        case .removeElement(let path, let index):
            return updateArray(path[...], in: value) { elements in
                var elements = elements
                elements.remove(at: index)
                return elements
            }
        case .editElement(let path, let index, let inner):
            return updateArray(path[...], in: value) { elements in
                var elements = elements
                elements[index] = apply(inner, to: elements[index])
                return elements
            }
        }
    }

    static func decode(_ value: JSONEdit.Value) -> JSONValue {
        switch value {
        case .json(let json): json
        case .raw(let raw): (try? JSONScanner.scan(raw).value(at: [])) ?? .null
        }
    }

    private static func updateArray(_ path: ArraySlice<String>, in value: JSONValue, _ transform: ([JSONValue]) -> [JSONValue]) -> JSONValue {
        guard let key = path.first else {
            guard case .array(let elements) = value else { return value }
            return .array(transform(elements))
        }
        guard case .object(var members) = value,
            let index = members.firstIndex(where: { Array($0.key.utf16) == Array(key.utf16) })
        else { return value }
        members[index] = JSONValue.Member(key: members[index].key, value: updateArray(path.dropFirst(), in: members[index].value, transform))
        return .object(members)
    }

    private static func set(_ path: ArraySlice<String>, to newValue: JSONValue, placement: JSONEdit.Placement, in value: JSONValue) -> JSONValue {
        guard let key = path.first, case .object(var members) = value else { return newValue }
        let rest = path.dropFirst()
        if let index = members.firstIndex(where: { Array($0.key.utf16) == Array(key.utf16) }) {
            members[index] = JSONValue.Member(key: key, value: set(rest, to: newValue, placement: placement, in: members[index].value))
            return .object(members)
        }
        let member = JSONValue.Member(key: key, value: set(rest, to: newValue, placement: placement, in: .object([])))
        let insertAt: Int =
            switch rest.isEmpty ? placement : .end {
            case .end: members.count
            case .start: 0
            case .after(let sibling): members.firstIndex(where: { Array($0.key.utf16) == Array(sibling.utf16) }).map { $0 + 1 } ?? members.count
            }
        members.insert(member, at: insertAt)
        return .object(members)
    }

    private static func remove(_ path: ArraySlice<String>, in value: JSONValue) -> JSONValue {
        guard let key = path.first, case .object(var members) = value,
            let index = members.firstIndex(where: { Array($0.key.utf16) == Array(key.utf16) })
        else { return value }
        if path.count == 1 {
            members.remove(at: index)
        } else {
            members[index] = JSONValue.Member(key: key, value: remove(path.dropFirst(), in: members[index].value))
        }
        return .object(members)
    }
}

/// Documents with arrays of objects, like keybinding blocks, and operations that mix key and element edits.
enum ArrayFuzz {
    static func document(using random: inout SplitMix64) -> JSONValue {
        var members: [JSONValue.Member] = []
        for key in FuzzGenerator.keys.shuffled(using: &random).prefix(Int.random(in: 1...5, using: &random)) {
            let value: JSONValue =
                switch Int.random(in: 0..<4, using: &random) {
                case 0, 1: array(depth: 1, using: &random)
                case 2: element(depth: 1, using: &random)
                default: FuzzGenerator.value(depth: 1, using: &random)
                }
            members.append(JSONValue.Member(key: key, value: value))
        }
        return .object(members)
    }

    static func operation(for model: JSONValue, using random: inout SplitMix64) -> JSONEdit.Operation {
        let arrays = arrayPaths(model)
        guard Int.random(in: 0..<10, using: &random) >= 3,
            let path = arrays.randomElement(using: &random),
            case .array(let elements)? = FuzzModel.lookup(path, in: model)
        else { return FuzzGenerator.operation(for: model, using: &random) }
        let objectIndices = elements.indices.filter { index in
            if case .object = elements[index] { return true }
            return false
        }
        switch Int.random(in: 0..<5, using: &random) {
        case 1:
            return .insertElement(path: path, index: Int.random(in: 0...elements.count, using: &random), value: newValue(using: &random))
        case 2 where !elements.isEmpty:
            return .replaceElement(path: path, index: Int.random(in: elements.indices, using: &random), value: newValue(using: &random))
        case 3 where !elements.isEmpty:
            return .removeElement(path: path, index: Int.random(in: elements.indices, using: &random))
        case 4 where !objectIndices.isEmpty:
            let index = objectIndices.randomElement(using: &random) ?? 0
            return .editElement(path: path, index: index, inner: operation(for: elements[index], using: &random))
        default:
            return .appendElement(path: path, value: newValue(using: &random))
        }
    }

    /// True when the operation removes the only key of an object or the only element of an array.
    /// The container becomes `{}` or `[]`, which loses its inside padding, so undo restores the value but not every byte.
    static func emptiesAContainer(_ operation: JSONEdit.Operation, in model: JSONValue) -> Bool {
        switch operation {
        case .remove(let path):
            guard case .object(let members)? = FuzzModel.lookup(Array(path.dropLast()), in: model) else { return false }
            return members.count == 1
        case .removeElement(let path, _):
            guard case .array(let elements)? = FuzzModel.lookup(path, in: model) else { return false }
            return elements.count == 1
        case .editElement(let path, let index, let inner):
            guard case .array(let elements)? = FuzzModel.lookup(path, in: model), elements.indices.contains(index) else { return false }
            return emptiesAContainer(inner, in: elements[index])
        case .set, .appendElement, .insertElement, .replaceElement:
            return false
        }
    }

    /// The raw bytes of the elements an element operation did not touch, in order, before and after it.
    static func untouchedElements(
        of operation: JSONEdit.Operation,
        before: JSONDocument,
        after: JSONDocument
    ) -> (before: [[UInt8]], after: [[UInt8]])? {
        guard let oldArray = before.node(at: operation.path), let newArray = after.node(at: operation.path) else { return nil }
        let old = elements(of: oldArray).map(before.rawBytes)
        let new = elements(of: newArray).map(after.rawBytes)
        let touched: (before: Int?, after: Int?)
        switch operation {
        case .set, .remove: return nil
        case .appendElement: touched = (nil, old.count)
        case .insertElement(_, let index, _): touched = (nil, index)
        case .replaceElement(_, let index, _), .editElement(_, let index, _): touched = (index, index)
        case .removeElement(_, let index): touched = (index, nil)
        }
        return (without(touched.before, in: old), without(touched.after, in: new))
    }

    private static func without(_ index: Int?, in list: [[UInt8]]) -> [[UInt8]] {
        list.enumerated().filter { $0.offset != index }.map(\.element)
    }

    private static func arrayPaths(_ value: JSONValue, prefix: [String] = []) -> [[String]] {
        switch value {
        case .object(let members): members.flatMap { arrayPaths($0.value, prefix: prefix + [$0.key]) }
        case .array: prefix.isEmpty ? [] : [prefix]
        case .null, .bool, .number, .string: []
        }
    }

    private static func array(depth: Int, using random: inout SplitMix64) -> JSONValue {
        .array((0..<Int.random(in: 0...4, using: &random)).map { _ in element(depth: depth + 1, using: &random) })
    }

    /// Mostly objects, some of them holding arrays of their own.
    private static func element(depth: Int, using random: inout SplitMix64) -> JSONValue {
        switch Int.random(in: 0..<10, using: &random) {
        case 0..<5:
            var members: [JSONValue.Member] = []
            for key in FuzzGenerator.keys.shuffled(using: &random).prefix(Int.random(in: 0...3, using: &random)) {
                let value =
                    depth < 3 && Int.random(in: 0..<3, using: &random) == 0
                    ? array(depth: depth, using: &random) : FuzzGenerator.value(depth: 3, using: &random)
                members.append(JSONValue.Member(key: key, value: value))
            }
            return .object(members)
        case 5 where depth < 3:
            return array(depth: depth, using: &random)
        default:
            return FuzzGenerator.value(depth: 3, using: &random)
        }
    }

    private static func newValue(using random: inout SplitMix64) -> JSONEdit.Value {
        let value = element(depth: 1, using: &random)
        guard Int.random(in: 0..<10, using: &random) == 0 else { return .json(value) }
        return .raw([UInt8](FuzzWriter(style: FuzzStyle.random(using: &random)).value(value)))
    }
}

struct FuzzWriter {
    let style: FuzzStyle

    func document(_ value: JSONValue) -> String {
        self.value(value, indent: "") + (style.trailingNewline ? style.lineEnding : "")
    }

    func value(_ value: JSONValue, indent: String = "") -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return number.text
        case .string(let string): return quote(string)
        case .array(let elements):
            return container("[", "]", elements.map { self.value($0, indent: indent + style.indentUnit) }, indent: indent)
        case .object(let members):
            return container("{", "}", members.map { quote($0.key) + style.colon + self.value($0.value, indent: indent + style.indentUnit) }, indent: indent)
        }
    }

    private func container(_ open: String, _ close: String, _ items: [String], indent: String) -> String {
        guard !items.isEmpty else { return open + close }
        guard style.multiLine else {
            let padding = style.inlineSpacing
            return open + padding + items.joined(separator: "," + style.inlineSpacing) + padding + close
        }
        let inner = indent + style.indentUnit
        return open + style.lineEnding + items.map { inner + $0 }.joined(separator: "," + style.lineEnding) + style.lineEnding + indent + close
    }

    private func quote(_ string: String) -> String {
        var output = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\t": output += "\\t"
            case "\u{0}"..."\u{1F}": output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }
}
