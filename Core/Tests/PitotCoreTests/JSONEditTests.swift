import Foundation
import Testing

@testable import PitotCore

struct GoldenCase: Sendable, CustomTestStringConvertible {
    let name: String
    let fixture: String
    let operation: JSONEdit.Operation
    let expectedPath: String
    let deviatesFromOracle: Bool

    var testDescription: String { name }

    static let all: [GoldenCase] = (try? load()) ?? []

    private static func load() throws -> [GoldenCase] {
        let opsBytes = [UInt8](try Data(contentsOf: Fixtures.repoRoot.appendingPathComponent("Tools/oracle/ops.json")))
        guard case .array(let entries) = try JSONScanner.scan(opsBytes).value(at: []) else { return [] }
        var counters: [String: Int] = [:]
        return entries.compactMap { entry -> GoldenCase? in
            guard case .object(let members) = entry else { return nil }
            let fields = Dictionary(members.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            guard case .string(let fixture) = fields["fixture"],
                case .string(let op) = fields["op"],
                case .array(let path) = fields["path"],
                let operation = oracleOperation(op, path: path[...], value: fields["value"])
            else { return nil }
            let index = counters[fixture, default: 0] + 1
            counters[fixture] = index
            let name = "\(fixture).\(index).json"
            var swiftExpected: String?
            if case .string(let path) = fields["swiftExpected"] { swiftExpected = path }
            return GoldenCase(
                name: name,
                fixture: fixture,
                operation: operation,
                expectedPath: swiftExpected ?? "Fixtures/expected/\(name)",
                deviatesFromOracle: swiftExpected != nil
            )
        }
    }

    /// The operation that `modify` in the oracle performs. A number in the path is an array index;
    /// `insert` at `-1` appends.
    private static func oracleOperation(_ op: String, path: ArraySlice<JSONValue>, value: JSONValue?) -> JSONEdit.Operation? {
        var keys: [String] = []
        for (position, segment) in zip(path.indices, path) {
            switch segment {
            case .string(let key):
                keys.append(key)
            case .number(let number):
                guard let index = Int(number.text) else { return nil }
                let rest = path[(position + 1)...]
                if !rest.isEmpty {
                    return oracleOperation(op, path: rest, value: value).map { .editElement(path: keys, index: index, inner: $0) }
                }
                switch (op, value) {
                case ("insert", let value?) where index == -1: return .appendElement(path: keys, value: .json(value))
                case ("insert", let value?): return .insertElement(path: keys, index: index, value: .json(value))
                case ("set", let value?): return .replaceElement(path: keys, index: index, value: .json(value))
                case ("remove", nil): return .removeElement(path: keys, index: index)
                default: return nil
                }
            default:
                return nil
            }
        }
        switch (op, value) {
        case ("set", let value?): return .set(path: keys, value: .json(value))
        case ("remove", nil): return .remove(path: keys)
        default: return nil
        }
    }
}

@Suite("Edit")
struct JSONEditTests {
    // MARK: Golden

    @Test func goldenCasesLoaded() {
        #expect(GoldenCase.all.count == 81)
        #expect(
            GoldenCase.all.filter(\.deviatesFromOracle).map(\.name).sorted() == [
                "array-numbers.5.json", "array-single-line.2.json", "array-single-line.3.json", "array-single-line.4.json",
                "array-single-line.5.json", "integer-like-keys.3.json", "integer-like-keys.4.json", "keybindings.10.json",
                "nested-arrays.3.json", "settings-synthetic.9.json", "single-line.2.json", "single-line.3.json", "tabs.3.json",
            ])
    }

    @Test("matches the expected file byte for byte", arguments: GoldenCase.all)
    func golden(_ golden: GoldenCase) throws {
        let input = try Fixtures.bytes(golden.fixture)
        let expected = try Fixtures.bytes(atRepoPath: golden.expectedPath)
        let result = try JSONEdit.apply(golden.operation, to: input)
        #expect(result.bytes == expected)
    }

    // MARK: Properties over fixtures

    @Test("set then remove of a new top-level key restores the original bytes", arguments: Fixtures.validNames)
    func setThenRemoveNewKey(fixture: String) throws {
        let original = try Fixtures.bytes(fixture)
        let added = try JSONEdit.set(["pitotProbe"], to: .json(["nested": [1, "two"]]), in: original)
        #expect(added.bytes != original)
        let removed = try JSONEdit.remove(["pitotProbe"], in: added.bytes)
        #expect(removed.bytes == original)
        #expect(try JSONEdit.apply(added.inverse, to: added.bytes).bytes == original)
    }

    @Test("set of a new key with new parents is undone by its inverse", arguments: Fixtures.validNames)
    func setWithIntermediatesThenInverse(fixture: String) throws {
        let original = try Fixtures.bytes(fixture)
        let added = try JSONEdit.set(["pitotA", "b", "c"], to: .json(true), in: original)
        #expect(added.inverse == .remove(path: ["pitotA"]))
        #expect(try JSONEdit.apply(added.inverse, to: added.bytes).bytes == original)
    }

    @Test("set of a new key inside every existing object is undone by remove", arguments: Fixtures.validNames)
    func setInsideEveryObjectThenRemove(fixture: String) throws {
        let original = try Fixtures.bytes(fixture)
        let document = try JSONScanner.scan(original)
        for objectPath in objectPaths(in: document.root, document: document, prefix: []) {
            let path = objectPath + ["pitotProbe"]
            let added = try JSONEdit.set(path, to: .json("v"), in: original)
            let removed = try JSONEdit.remove(path, in: added.bytes)
            #expect(removed.bytes == original, "path \(path)")
        }
    }

    @Test("replacing a value is undone by the inverse", arguments: Fixtures.validNames)
    func replaceThenInverse(fixture: String) throws {
        let original = try Fixtures.bytes(fixture)
        let document = try JSONScanner.scan(original)
        for path in memberPaths(in: document.root, document: document, prefix: []) {
            let replaced = try JSONEdit.set(path, to: .json(["x": [1, 2]]), in: original)
            #expect(try JSONEdit.apply(replaced.inverse, to: replaced.bytes).bytes == original, "path \(path)")
        }
    }

    @Test("removing a key that has siblings is undone by the inverse in place", arguments: Fixtures.validNames)
    func removeThenInverse(fixture: String) throws {
        let original = try Fixtures.bytes(fixture)
        let document = try JSONScanner.scan(original)
        for path in memberPaths(in: document.root, document: document, prefix: []) {
            guard let parent = document.node(at: Array(path.dropLast())), let siblings = parent.members, siblings.count > 1 else { continue }
            let removed = try JSONEdit.remove(path, in: original)
            #expect(try JSONEdit.apply(removed.inverse, to: removed.bytes).bytes == original, "path \(path)")
        }
    }

    // MARK: Errors

    @Test(
        "rejects input that does not scan",
        arguments: [
            ("invalid-comment", JSONScanError.comment(offset: 4)),
            ("invalid-trailing-comma", JSONScanError.trailingComma(offset: 19)),
            ("invalid-utf8", JSONScanError.invalidUTF8(offset: 6)),
            ("empty", JSONScanError.emptyInput),
        ])
    func rejectsInvalidFixtures(fixture: String, error: JSONScanError) throws {
        let bytes = try Fixtures.bytes(fixture)
        #expect(throws: JSONEditError.invalidJSON(error)) {
            try JSONEdit.set(["theme"], to: .json("light"), in: bytes)
        }
        #expect(throws: JSONEditError.invalidJSON(error)) {
            try JSONEdit.remove(["theme"], in: bytes)
        }
    }

    @Test func rejectsEmptyPath() {
        #expect(throws: JSONEditError.emptyPath) {
            try JSONEdit.set([], to: .json(1), in: [UInt8]("{}"))
        }
        #expect(throws: JSONEditError.emptyPath) {
            try JSONEdit.remove([], in: [UInt8]("{}"))
        }
    }

    @Test func rejectsRootThatIsNotAnObject() {
        #expect(throws: JSONEditError.notAnObject(path: [])) {
            try JSONEdit.set(["a"], to: .json(1), in: [UInt8]("[1]"))
        }
    }

    @Test func rejectsPathThroughNonObject() {
        #expect(throws: JSONEditError.notAnObject(path: ["theme"])) {
            try JSONEdit.set(["theme", "x"], to: .json(1), in: [UInt8](#"{"theme": "dark"}"#))
        }
        #expect(throws: JSONEditError.notAnObject(path: ["theme"])) {
            try JSONEdit.remove(["theme", "x"], in: [UInt8](#"{"theme": "dark"}"#))
        }
    }

    @Test func rejectsRemovingMissingKey() {
        #expect(throws: JSONEditError.keyNotFound(path: ["nope"])) {
            try JSONEdit.remove(["nope"], in: [UInt8](#"{"a": 1}"#))
        }
        #expect(throws: JSONEditError.keyNotFound(path: ["a", "b"])) {
            try JSONEdit.remove(["a", "b"], in: [UInt8](#"{"a": {}}"#))
        }
    }

    @Test func rejectsInvalidRawValue() {
        #expect(throws: JSONEditError.invalidRawValue(.trailingContent(offset: 2))) {
            try JSONEdit.set(["a"], to: .raw([UInt8]("1 2")), in: [UInt8]("{}"))
        }
        #expect(throws: JSONEditError.invalidRawValue(.emptyInput)) {
            try JSONEdit.set(["a"], to: .raw([]), in: [UInt8]("{}"))
        }
    }

    // MARK: Layout rules

    @Test func replacesOnlyTheValueRange() throws {
        let result = try JSONEdit.set(["a"], to: .json(false), in: [UInt8]("{ \"a\" :  true , \"b\":1}"))
        #expect(result.bytes.text == "{ \"a\" :  false , \"b\":1}")
        #expect(result.change == JSONEdit.Change(path: ["a"], before: [UInt8]("true"), after: [UInt8]("false"), restorePlacement: .start))
    }

    @Test func copiesKeyColonSpacingFromLastSibling() throws {
        let result = try JSONEdit.set(["c"], to: .json(3), in: [UInt8]("{\n  \"a\" : 1,\n  \"b\" : 2\n}\n"))
        #expect(result.bytes.text == "{\n  \"a\" : 1,\n  \"b\" : 2,\n  \"c\" : 3\n}\n")
    }

    @Test func insertsInlineInSpacedSingleLineObject() throws {
        let result = try JSONEdit.set(["b"], to: .json(2), in: [UInt8]("{ \"a\": 1 }"))
        #expect(result.bytes.text == "{ \"a\": 1, \"b\": 2 }")
    }

    @Test func createsIntermediateObjectsWithFileLineEndings() throws {
        let result = try JSONEdit.set(["b", "c"], to: .json(1), in: [UInt8]("{\r\n    \"a\": 1\r\n}\r\n"))
        #expect(result.bytes.text == "{\r\n    \"a\": 1,\r\n    \"b\": {\r\n        \"c\": 1\r\n    }\r\n}\r\n")
    }

    @Test func createsIntermediateObjectsInlineWhenMinified() throws {
        let result = try JSONEdit.set(["b", "c"], to: .json(1), in: [UInt8](#"{"a":1}"#))
        #expect(result.bytes.text == #"{"a":1,"b":{"c":1}}"#)
    }

    @Test func expandsEmptyNestedObjectInPrettyFile() throws {
        let result = try JSONEdit.set(["env", "A"], to: .json("1"), in: [UInt8]("{\n\t\"env\": {}\n}\n"))
        #expect(result.bytes.text == "{\n\t\"env\": {\n\t\t\"A\": \"1\"\n\t}\n}\n")
    }

    @Test func fillsEmptyNestedObjectInlineWhenMinified() throws {
        let result = try JSONEdit.set(["a", "c"], to: .json(1), in: [UInt8](#"{"a":{},"b":1}"#))
        #expect(result.bytes.text == #"{"a":{"c":1},"b":1}"#)
    }

    @Test func removingTheOnlyKeyYieldsEmptyObject() throws {
        #expect(try JSONEdit.remove(["a"], in: [UInt8]("{\n  \"a\": 1\n}\n")).bytes.text == "{}\n")
        #expect(try JSONEdit.remove(["a", "b"], in: [UInt8]("{\"a\": {\n    \"b\": 1\n  }}")).bytes.text == "{\"a\": {}}")
    }

    @Test func removesWholeLineInMultiLineObject() throws {
        let input = [UInt8]("{\n  \"a\": 1,\n  \"b\": [\n    2\n  ],\n  \"c\": 3\n}\n")
        #expect(try JSONEdit.remove(["a"], in: input).bytes.text == "{\n  \"b\": [\n    2\n  ],\n  \"c\": 3\n}\n")
        #expect(try JSONEdit.remove(["b"], in: input).bytes.text == "{\n  \"a\": 1,\n  \"c\": 3\n}\n")
        #expect(try JSONEdit.remove(["c"], in: input).bytes.text == "{\n  \"a\": 1,\n  \"b\": [\n    2\n  ]\n}\n")
    }

    @Test func prettyPrintsTypedContainersAtTheKeyIndent() throws {
        let input = [UInt8]("{\n  \"env\": {\n    \"A\": \"1\"\n  }\n}\n")
        let result = try JSONEdit.set(["env", "list"], to: .json(["x", ["y": nil], [], [:]]), in: input)
        #expect(
            result.bytes.text == """
                {
                  "env": {
                    "A": "1",
                    "list": [
                      "x",
                      {
                        "y": null
                      },
                      [],
                      {}
                    ]
                  }
                }

                """)
    }

    @Test func insertsRawValueVerbatim() throws {
        let result = try JSONEdit.set(["a"], to: .raw([UInt8](" [1,  2] ")), in: [UInt8]("{\n  \"b\": 0\n}"))
        #expect(result.bytes.text == "{\n  \"b\": 0,\n  \"a\": [1,  2]\n}")
        #expect(result.change.after == [UInt8]("[1,  2]"))
    }

    @Test func escapesKeysAndStrings() throws {
        let result = try JSONEdit.set(["k\"q\\"], to: .json(.string("line\nbreak\u{1}\t\u{7F}é/")), in: [UInt8]("{}"))
        #expect(result.bytes.text == "{\n  \"k\\\"q\\\\\": \"line\\nbreak\\u0001\\t\u{7F}é/\"\n}")
        let decoded = try JSONScanner.scan(result.bytes).value(at: ["k\"q\\"])
        #expect(decoded == .string("line\nbreak\u{1}\t\u{7F}é/"))
    }

    @Test func keepsIntegerLikeKeysAndNumberText() throws {
        let input = try Fixtures.bytes("numbers")
        let result = try JSONEdit.set(["10"], to: .json(.number(try #require(JSONNumber(text: "1.50")))), in: input)
        #expect(result.bytes.text.contains("\"a\": 1e3,\n  \"b\": 0.10,"))
        #expect(result.bytes.text.hasSuffix("\"name\": \"keep\",\n  \"10\": 1.50\n}\n"))
    }

    @Test func placementAfterInsertsBetweenSiblings() throws {
        let input = [UInt8]("{\n  \"a\": 1,\n  \"c\": 3\n}\n")
        let after = try JSONEdit.set(["b"], to: .json(2), placement: .after("a"), in: input)
        #expect(after.bytes.text == "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}\n")
        let start = try JSONEdit.set(["z"], to: .json(0), placement: .start, in: input)
        #expect(start.bytes.text == "{\n  \"z\": 0,\n  \"a\": 1,\n  \"c\": 3\n}\n")
        let missingAnchor = try JSONEdit.set(["b"], to: .json(2), placement: .after("nope"), in: input)
        #expect(missingAnchor.bytes.text == "{\n  \"a\": 1,\n  \"c\": 3,\n  \"b\": 2\n}\n")
    }

    @Test func removeRecordsPlacementForRestore() throws {
        let input = [UInt8](#"{"a":1,"b":2,"c":3}"#)
        #expect(try JSONEdit.remove(["a"], in: input).change.restorePlacement == .start)
        let removed = try JSONEdit.remove(["b"], in: input)
        #expect(removed.change == JSONEdit.Change(path: ["b"], before: [UInt8]("2"), after: nil, restorePlacement: .after("a")))
        #expect(removed.inverse == .set(path: ["b"], value: .raw([UInt8]("2")), placement: .after("a")))
    }

    @Test func undoingTheRemovalOfTheFirstKeyKeepsTheSpaceAfterTheComma() throws {
        let original = try Fixtures.bytes("array-single-line")
        let removed = try JSONEdit.remove(["list"], in: original)
        #expect(removed.bytes.text == "{\"words\": [\"a\", \"b\"], \"one\": [true]}\n")
        #expect(try JSONEdit.apply(removed.inverse, to: removed.bytes).bytes == original)
    }

    @Test func aSingleKeyObjectTakesItsSeparatorFromThePaddingOrTheColon() throws {
        #expect(try JSONEdit.set(["b"], to: .json(2), in: [UInt8](#"{"a": 1}"#)).bytes.text == #"{"a": 1, "b": 2}"#)
        #expect(try JSONEdit.set(["b"], to: .json(2), in: [UInt8](#"{"a":1}"#)).bytes.text == #"{"a":1,"b":2}"#)
        #expect(try JSONEdit.set(["z"], to: .json(0), placement: .start, in: [UInt8](#"{ "a": 1 }"#)).bytes.text == #"{ "z": 0, "a": 1 }"#)
        #expect(try JSONEdit.set(["z"], to: .json(0), placement: .start, in: [UInt8](#"{"a": 1, "b": 2}"#)).bytes.text == #"{"z": 0, "a": 1, "b": 2}"#)
    }

    @Test(
        "removing the first, a middle or the last key then undoing restores the original bytes",
        arguments: [
            #"{"a": 1, "b": [1, 2], "c": {"d": 3, "e": 4, "f": 5}}"#,
            #"{"a":1,"b":[1,2],"c":{"d":3,"e":4,"f":5}}"#,
            #"{ "a": 1, "b": 2, "c": { "d": 3, "e": 4, "f": 5 } }"#,
            "{\n  \"a\": 1,\n  \"b\": [\n    1\n  ],\n  \"c\": {\n    \"d\": 3,\n    \"e\": 4,\n    \"f\": 5\n  }\n}\n",
            "{\n\t\"a\": 1,\n\t\"b\": 2,\n\t\"c\": {\n\t\t\"d\": 3,\n\t\t\"e\": 4,\n\t\t\"f\": 5\n\t}\n}\n",
            "{\r\n    \"a\": 1,\r\n    \"b\": 2,\r\n    \"c\": {\r\n        \"d\": 3,\r\n        \"e\": 4,\r\n        \"f\": 5\r\n    }\r\n}\r\n",
        ])
    func removeThenUndoAtEveryPosition(_ text: String) throws {
        let original = [UInt8](text)
        for path in [["a"], ["b"], ["c"], ["c", "d"], ["c", "e"], ["c", "f"]] {
            let removed = try JSONEdit.remove(path, in: original)
            #expect(try JSONEdit.apply(removed.inverse, to: removed.bytes).bytes == original, "path \(path)")
        }
    }
}

func memberPaths(in node: JSONNode, document: JSONDocument, prefix: [String]) -> [[String]] {
    guard let members = node.members else { return [] }
    return members.flatMap { member in
        [prefix + [member.key]] + memberPaths(in: member.value, document: document, prefix: prefix + [member.key])
    }
}

func objectPaths(in node: JSONNode, document: JSONDocument, prefix: [String]) -> [[String]] {
    guard let members = node.members else { return [] }
    return [prefix]
        + members.flatMap { member in
            objectPaths(in: member.value, document: document, prefix: prefix + [member.key])
        }
}
