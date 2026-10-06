import Foundation
import Testing

@testable import PitotCore

@Suite("Edit arrays")
struct JSONEditArrayTests {
    private static let probes: [JSONEdit.Value] = [.json(["pitotProbe": [1, "two"]]), .json("probe"), .raw([UInt8](" [ 1,2 ] "))]

    private let keybindings = [UInt8](
        """
        {
          "bindings": [
            {
              "context": "Global",
              "bindings": {
                "ctrl+t": "app:toggleTodos"
              }
            },
            {
              "context": "Chat",
              "bindings": {}
            }
          ]
        }

        """)

    // MARK: Properties over fixtures

    @Test("insert then remove at the same index restores the original bytes", arguments: Fixtures.validNames)
    func insertThenRemove(fixture: String) throws {
        let original = try Fixtures.bytes(fixture)
        let document = try JSONScanner.scan(original)
        for path in arrayPaths(in: document.root, prefix: []) {
            let count = elements(of: try #require(document.node(at: path))).count
            for index in 0...count {
                for probe in Self.probes {
                    let inserted = try JSONEdit.apply(.insertElement(path: path, index: index, value: probe), to: original)
                    #expect(inserted.inverse == .removeElement(path: path, index: index))
                    let removed = try JSONEdit.apply(.removeElement(path: path, index: index), to: inserted.bytes)
                    #expect(removed.bytes == original, "\(path) at \(index)")
                }
            }
        }
    }

    @Test("append then remove of the last element restores the original bytes", arguments: Fixtures.validNames)
    func appendThenRemoveLast(fixture: String) throws {
        let original = try Fixtures.bytes(fixture)
        let document = try JSONScanner.scan(original)
        for path in arrayPaths(in: document.root, prefix: []) {
            let count = elements(of: try #require(document.node(at: path))).count
            for probe in Self.probes {
                let appended = try JSONEdit.apply(.appendElement(path: path, value: probe), to: original)
                #expect(appended.inverse == .removeElement(path: path, index: count))
                let removed = try JSONEdit.apply(.removeElement(path: path, index: count), to: appended.bytes)
                #expect(removed.bytes == original, "\(path)")
                #expect(try JSONEdit.apply(appended.inverse, to: appended.bytes).bytes == original, "\(path)")
            }
        }
    }

    @Test("replacing an element rewrites only its bytes and is undone by the inverse", arguments: Fixtures.validNames)
    func replaceThenInverse(fixture: String) throws {
        let original = try Fixtures.bytes(fixture)
        let document = try JSONScanner.scan(original)
        for path in arrayPaths(in: document.root, prefix: []) {
            for (index, element) in elements(of: try #require(document.node(at: path))).enumerated() {
                let replaced = try JSONEdit.apply(.replaceElement(path: path, index: index, value: .json(["x": [1, 2]])), to: original)
                let tail = original.count - element.range.upperBound
                #expect(replaced.bytes.prefix(element.range.lowerBound).elementsEqual(original.prefix(element.range.lowerBound)), "\(path) at \(index)")
                #expect(replaced.bytes.suffix(tail).elementsEqual(original.suffix(tail)), "\(path) at \(index)")
                #expect(try JSONEdit.apply(replaced.inverse, to: replaced.bytes).bytes == original, "\(path) at \(index)")
            }
        }
    }

    @Test("removing an element is undone by the inverse in place", arguments: Fixtures.validNames)
    func removeThenInverse(fixture: String) throws {
        let original = try Fixtures.bytes(fixture)
        let document = try JSONScanner.scan(original)
        for path in arrayPaths(in: document.root, prefix: []) {
            for (index, element) in elements(of: try #require(document.node(at: path))).enumerated() {
                let removed = try JSONEdit.apply(.removeElement(path: path, index: index), to: original)
                #expect(removed.inverse == .insertElement(path: path, index: index, value: .raw(document.rawBytes(of: element))))
                #expect(try JSONEdit.apply(removed.inverse, to: removed.bytes).bytes == original, "\(path) at \(index)")
            }
        }
    }

    @Test("edits inside every object element are undone by the inverse", arguments: Fixtures.validNames)
    func editInsideElementsThenInverse(fixture: String) throws {
        let original = try Fixtures.bytes(fixture)
        let document = try JSONScanner.scan(original)
        for path in arrayPaths(in: document.root, prefix: []) {
            for (index, element) in elements(of: try #require(document.node(at: path))).enumerated() {
                guard case .object = element.kind else { continue }
                var inner: [JSONEdit.Operation] = [.set(path: ["pitotProbe"], value: .json("v"))]
                inner += arrayPaths(in: element, prefix: []).map { .appendElement(path: $0, value: .json(["id": 0])) }
                for operation in inner {
                    let edited = try JSONEdit.apply(.editElement(path: path, index: index, inner: operation), to: original)
                    #expect(edited.bytes != original)
                    #expect(try JSONEdit.apply(edited.inverse, to: edited.bytes).bytes == original, "\(path) at \(index): \(operation)")
                }
            }
        }
    }

    // MARK: Layout rules

    @Test func appendCopiesTheLastElementLayoutInAMultiLineArray() throws {
        let value: JSONValue = ["context": "Help", "bindings": ["ctrl+h": "help:dismiss"]]
        let result = try JSONEdit.apply(.appendElement(path: ["bindings"], value: .json(value)), to: keybindings)
        #expect(
            result.bytes.text == """
                {
                  "bindings": [
                    {
                      "context": "Global",
                      "bindings": {
                        "ctrl+t": "app:toggleTodos"
                      }
                    },
                    {
                      "context": "Chat",
                      "bindings": {}
                    },
                    {
                      "context": "Help",
                      "bindings": {
                        "ctrl+h": "help:dismiss"
                      }
                    }
                  ]
                }

                """)
    }

    @Test func insertsAtTheStartAndInTheMiddleOfAMultiLineArray() throws {
        let input = [UInt8]("{\n  \"a\": [\n    1,\n    2\n  ]\n}\n")
        let start = try JSONEdit.apply(.insertElement(path: ["a"], index: 0, value: .json(0)), to: input)
        #expect(start.bytes.text == "{\n  \"a\": [\n    0,\n    1,\n    2\n  ]\n}\n")
        let middle = try JSONEdit.apply(.insertElement(path: ["a"], index: 1, value: .json(["x": 9])), to: input)
        #expect(middle.bytes.text == "{\n  \"a\": [\n    1,\n    {\n      \"x\": 9\n    },\n    2\n  ]\n}\n")
        let end = try JSONEdit.apply(.insertElement(path: ["a"], index: 2, value: .json(3)), to: input)
        #expect(end.bytes == (try JSONEdit.apply(.appendElement(path: ["a"], value: .json(3)), to: input).bytes))
        #expect(end.bytes.text == "{\n  \"a\": [\n    1,\n    2,\n    3\n  ]\n}\n")
    }

    @Test func singleLineArraysStaySingleLineWithTheirSpacing() throws {
        let spaced = [UInt8](#"{"a": [1, 2]}"#)
        #expect(try JSONEdit.apply(.appendElement(path: ["a"], value: .json(3)), to: spaced).bytes.text == #"{"a": [1, 2, 3]}"#)
        #expect(try JSONEdit.apply(.insertElement(path: ["a"], index: 0, value: .json(0)), to: spaced).bytes.text == #"{"a": [0, 1, 2]}"#)
        #expect(try JSONEdit.apply(.insertElement(path: ["a"], index: 1, value: .json(9)), to: spaced).bytes.text == #"{"a": [1, 9, 2]}"#)
        #expect(try JSONEdit.apply(.appendElement(path: ["a"], value: .json(["x": [1]])), to: spaced).bytes.text == #"{"a": [1, 2, {"x": [1]}]}"#)
        let minified = [UInt8](#"{"a":[1,2]}"#)
        #expect(try JSONEdit.apply(.appendElement(path: ["a"], value: .json(3)), to: minified).bytes.text == #"{"a":[1,2,3]}"#)
        #expect(try JSONEdit.apply(.insertElement(path: ["a"], index: 0, value: .json(0)), to: minified).bytes.text == #"{"a":[0,1,2]}"#)
    }

    @Test func aSingleElementArrayTakesItsSeparatorFromThePaddingOrTheColons() throws {
        #expect(try JSONEdit.apply(.appendElement(path: ["a"], value: .json(2)), to: [UInt8](#"{"a": [1]}"#)).bytes.text == #"{"a": [1, 2]}"#)
        #expect(try JSONEdit.apply(.appendElement(path: ["a"], value: .json(2)), to: [UInt8](#"{"a":[1]}"#)).bytes.text == #"{"a":[1,2]}"#)
        #expect(
            try JSONEdit.apply(.insertElement(path: ["a"], index: 0, value: .json(0)), to: [UInt8](#"{ "a": [ 1 ] }"#)).bytes.text
                == #"{ "a": [ 0, 1 ] }"#)
    }

    @Test func anEmptyArrayTakesTheLayoutOfTheFile() throws {
        let pretty = try JSONEdit.apply(.appendElement(path: ["a"], value: .json(1)), to: [UInt8]("{\n  \"a\": []\n}\n"))
        #expect(pretty.bytes.text == "{\n  \"a\": [\n    1\n  ]\n}\n")
        let minified = try JSONEdit.apply(.insertElement(path: ["a"], index: 0, value: .json(["k": 1])), to: [UInt8](#"{"a":[]}"#))
        #expect(minified.bytes.text == #"{"a":[{"k":1}]}"#)
        let tabsCRLF = try JSONEdit.apply(.appendElement(path: ["a"], value: .json(["k": "v"])), to: [UInt8]("{\r\n\t\"a\": []\r\n}\r\n"))
        #expect(tabsCRLF.bytes.text == "{\r\n\t\"a\": [\r\n\t\t{\r\n\t\t\t\"k\": \"v\"\r\n\t\t}\r\n\t]\r\n}\r\n")
    }

    @Test func removesTheElementWithItsCommaAndItsLine() throws {
        let input = [UInt8]("{\n  \"a\": [\n    1,\n    {\n      \"x\": 2\n    },\n    3\n  ]\n}\n")
        #expect(try JSONEdit.apply(.removeElement(path: ["a"], index: 0), to: input).bytes.text == "{\n  \"a\": [\n    {\n      \"x\": 2\n    },\n    3\n  ]\n}\n")
        #expect(try JSONEdit.apply(.removeElement(path: ["a"], index: 1), to: input).bytes.text == "{\n  \"a\": [\n    1,\n    3\n  ]\n}\n")
        #expect(try JSONEdit.apply(.removeElement(path: ["a"], index: 2), to: input).bytes.text == "{\n  \"a\": [\n    1,\n    {\n      \"x\": 2\n    }\n  ]\n}\n")
        let inline = [UInt8](#"{"a": [1, 2, 3]}"#)
        #expect(try JSONEdit.apply(.removeElement(path: ["a"], index: 0), to: inline).bytes.text == #"{"a": [2, 3]}"#)
        #expect(try JSONEdit.apply(.removeElement(path: ["a"], index: 1), to: inline).bytes.text == #"{"a": [1, 3]}"#)
        #expect(try JSONEdit.apply(.removeElement(path: ["a"], index: 2), to: inline).bytes.text == #"{"a": [1, 2]}"#)
    }

    @Test func removingTheOnlyElementYieldsAnEmptyArray() throws {
        #expect(try JSONEdit.apply(.removeElement(path: ["a"], index: 0), to: [UInt8]("{\n  \"a\": [\n    1\n  ]\n}\n")).bytes.text == "{\n  \"a\": []\n}\n")
        #expect(try JSONEdit.apply(.removeElement(path: ["a"], index: 0), to: [UInt8](#"{"a": [ 1 ]}"#)).bytes.text == #"{"a": []}"#)
    }

    @Test func replaceRewritesOnlyTheElementAndKeepsNumberText() throws {
        let input = [UInt8](#"{"v": [1e3, 0.10, -0]}"#)
        let result = try JSONEdit.apply(.replaceElement(path: ["v"], index: 1, value: .json(5)), to: input)
        #expect(result.bytes.text == #"{"v": [1e3, 5, -0]}"#)
        #expect(
            result.change
                == JSONEdit.Change(
                    path: ["v"],
                    before: [UInt8]("[1e3, 0.10, -0]"),
                    after: [UInt8]("[1e3, 5, -0]"),
                    restorePlacement: .start,
                    element: .replaced(index: 1, before: [UInt8]("0.10"), after: [UInt8]("5"))
                ))
        #expect(result.inverse == .replaceElement(path: ["v"], index: 1, value: .raw([UInt8]("0.10"))))
    }

    @Test func replaceRendersAContainerAtTheElementIndent() throws {
        let result = try JSONEdit.apply(.replaceElement(path: ["a"], index: 1, value: .json(["x": [1]])), to: [UInt8]("{\n  \"a\": [\n    1,\n    2\n  ]\n}"))
        #expect(result.bytes.text == "{\n  \"a\": [\n    1,\n    {\n      \"x\": [\n        1\n      ]\n    }\n  ]\n}")
    }

    @Test func editElementChangesAKeyInsideTheObject() throws {
        let result = try JSONEdit.apply(
            .editElement(path: ["bindings"], index: 0, inner: .set(path: ["bindings", "ctrl+k"], value: .json("app:new"))), to: keybindings)
        #expect(
            result.bytes.text == """
                {
                  "bindings": [
                    {
                      "context": "Global",
                      "bindings": {
                        "ctrl+t": "app:toggleTodos",
                        "ctrl+k": "app:new"
                      }
                    },
                    {
                      "context": "Chat",
                      "bindings": {}
                    }
                  ]
                }

                """)
        let before = try JSONScanner.scan(keybindings)
        let after = try JSONScanner.scan(result.bytes)
        let inner = JSONEdit.Change(path: ["bindings", "ctrl+k"], before: nil, after: [UInt8](#""app:new""#), restorePlacement: .end)
        #expect(result.change.path == ["bindings"])
        #expect(result.change.before == before.node(at: ["bindings"]).map(before.rawBytes))
        #expect(result.change.after == after.node(at: ["bindings"]).map(after.rawBytes))
        #expect(result.change.element == .inside(index: 0, change: inner))
        #expect(result.inverse == .editElement(path: ["bindings"], index: 0, inner: .remove(path: ["bindings", "ctrl+k"])))
    }

    @Test func editElementFillsAnEmptyObjectAndEmptiesItAgain() throws {
        let set = JSONEdit.Operation.editElement(path: ["bindings"], index: 1, inner: .set(path: ["bindings", "ctrl+e"], value: .json("chat:externalEditor")))
        let filled = try JSONEdit.apply(set, to: keybindings)
        #expect(filled.bytes.text.contains("\"context\": \"Chat\",\n      \"bindings\": {\n        \"ctrl+e\": \"chat:externalEditor\"\n      }\n    }\n  ]"))
        let remove = JSONEdit.Operation.editElement(path: ["bindings"], index: 1, inner: .remove(path: ["bindings", "ctrl+e"]))
        #expect(try JSONEdit.apply(remove, to: filled.bytes).bytes == keybindings)
        let removeOnly = JSONEdit.Operation.editElement(path: ["bindings"], index: 0, inner: .remove(path: ["bindings", "ctrl+t"]))
        #expect(try JSONEdit.apply(removeOnly, to: keybindings).bytes.text.contains("\"context\": \"Global\",\n      \"bindings\": {}\n    },"))
    }

    @Test func editElementNestsThroughArraysOfObjects() throws {
        let input = try Fixtures.bytes("nested-array-objects")
        let nestedSet = JSONEdit.Operation.editElement(
            path: ["groups"], index: 0, inner: .editElement(path: ["items"], index: 1, inner: .set(path: ["id"], value: .json(9))))
        let result = try JSONEdit.apply(nestedSet, to: input)
        #expect(result.bytes.text.contains("\"id\": 1\n        },\n        {\n          \"id\": 9\n        }"))
        #expect(
            result.inverse
                == .editElement(path: ["groups"], index: 0, inner: .editElement(path: ["items"], index: 1, inner: .set(path: ["id"], value: .raw([UInt8]("2")), placement: .start))))
        #expect(try JSONEdit.apply(result.inverse, to: result.bytes).bytes == input)
        let nestedAppend = JSONEdit.Operation.editElement(path: ["groups"], index: 1, inner: .appendElement(path: ["items"], value: .json(["id": 1])))
        let appended = try JSONEdit.apply(nestedAppend, to: input)
        #expect(appended.bytes.text.contains("\"name\": \"second\",\n      \"items\": [\n        {\n          \"id\": 1\n        }\n      ]\n    }"))
        #expect(appended.inverse == .editElement(path: ["groups"], index: 1, inner: .removeElement(path: ["items"], index: 0)))
    }

    @Test func insertsRawElementsVerbatim() throws {
        let result = try JSONEdit.apply(.appendElement(path: ["a"], value: .raw([UInt8](" {\"k\" :  1} "))), to: [UInt8]("{\n  \"a\": [\n    0\n  ]\n}"))
        #expect(result.bytes.text == "{\n  \"a\": [\n    0,\n    {\"k\" :  1}\n  ]\n}")
        #expect(result.change.element == .added(index: 1, raw: [UInt8]("{\"k\" :  1}")))
    }

    @Test func appendRecordsTheWholeArrayAndTheAddedElement() throws {
        let result = try JSONEdit.apply(.appendElement(path: ["a"], value: .json(3)), to: [UInt8](#"{"z": 0, "a": [1, 2]}"#))
        #expect(
            result.change
                == JSONEdit.Change(
                    path: ["a"],
                    before: [UInt8]("[1, 2]"),
                    after: [UInt8]("[1, 2, 3]"),
                    restorePlacement: .after("z"),
                    element: .added(index: 2, raw: [UInt8]("3"))
                ))
        #expect(result.inverse == .removeElement(path: ["a"], index: 2))
        let removed = try JSONEdit.apply(.removeElement(path: ["a"], index: 0), to: result.bytes)
        #expect(removed.change.element == .removed(index: 0, raw: [UInt8]("1")))
        #expect(removed.inverse == .insertElement(path: ["a"], index: 0, value: .raw([UInt8]("1"))))
    }

    // MARK: Errors

    @Test func rejectsAPathThatIsNotAnArray() {
        #expect(throws: JSONEditError.notAnArray(path: ["a"])) {
            try JSONEdit.apply(.appendElement(path: ["a"], value: .json(1)), to: [UInt8](#"{"a": {"b": 1}}"#))
        }
        #expect(throws: JSONEditError.notAnArray(path: ["a"])) {
            try JSONEdit.apply(.removeElement(path: ["a"], index: 0), to: [UInt8](#"{"a": "x"}"#))
        }
    }

    @Test func rejectsAMissingArrayOrAPathThroughANonObject() {
        #expect(throws: JSONEditError.keyNotFound(path: ["missing"])) {
            try JSONEdit.apply(.appendElement(path: ["missing"], value: .json(1)), to: [UInt8](#"{"a": []}"#))
        }
        #expect(throws: JSONEditError.keyNotFound(path: ["a", "missing"])) {
            try JSONEdit.apply(.insertElement(path: ["a", "missing"], index: 0, value: .json(1)), to: [UInt8](#"{"a": {}}"#))
        }
        #expect(throws: JSONEditError.notAnObject(path: ["a"])) {
            try JSONEdit.apply(.appendElement(path: ["a", "b"], value: .json(1)), to: [UInt8](#"{"a": [1]}"#))
        }
        #expect(throws: JSONEditError.notAnObject(path: [])) {
            try JSONEdit.apply(.appendElement(path: ["a"], value: .json(1)), to: [UInt8]("[1]"))
        }
    }

    @Test func rejectsAnIndexOutsideTheArray() {
        let input = [UInt8](#"{"a": [1, 2]}"#)
        #expect(throws: JSONEditError.indexOutOfRange(path: ["a"], index: 3, count: 2)) {
            try JSONEdit.apply(.insertElement(path: ["a"], index: 3, value: .json(0)), to: input)
        }
        #expect(throws: JSONEditError.indexOutOfRange(path: ["a"], index: -1, count: 2)) {
            try JSONEdit.apply(.insertElement(path: ["a"], index: -1, value: .json(0)), to: input)
        }
        #expect(throws: JSONEditError.indexOutOfRange(path: ["a"], index: 2, count: 2)) {
            try JSONEdit.apply(.replaceElement(path: ["a"], index: 2, value: .json(0)), to: input)
        }
        #expect(throws: JSONEditError.indexOutOfRange(path: ["a"], index: 2, count: 2)) {
            try JSONEdit.apply(.removeElement(path: ["a"], index: 2), to: input)
        }
        #expect(throws: JSONEditError.indexOutOfRange(path: ["a"], index: 5, count: 2)) {
            try JSONEdit.apply(.editElement(path: ["a"], index: 5, inner: .set(path: ["x"], value: .json(1))), to: input)
        }
        #expect(throws: JSONEditError.indexOutOfRange(path: ["a"], index: 0, count: 0)) {
            try JSONEdit.apply(.removeElement(path: ["a"], index: 0), to: [UInt8](#"{"a": []}"#))
        }
    }

    @Test func rejectsAnEditInsideAnElementThatIsNotAnObject() {
        let input = [UInt8](#"{"a": [1, [2], {"x": 1}]}"#)
        for index in 0..<2 {
            #expect(throws: JSONEditError.elementNotAnObject(path: ["a"], index: index)) {
                try JSONEdit.apply(.editElement(path: ["a"], index: index, inner: .set(path: ["x"], value: .json(1))), to: input)
            }
        }
    }

    @Test func errorsInsideAnElementUsePathsFromThatElement() {
        let input = [UInt8](#"{"a": [{"x": 1}]}"#)
        #expect(throws: JSONEditError.keyNotFound(path: ["y"])) {
            try JSONEdit.apply(.editElement(path: ["a"], index: 0, inner: .remove(path: ["y"])), to: input)
        }
        #expect(throws: JSONEditError.notAnObject(path: ["x"])) {
            try JSONEdit.apply(.editElement(path: ["a"], index: 0, inner: .set(path: ["x", "y"], value: .json(1))), to: input)
        }
        #expect(throws: JSONEditError.emptyPath) {
            try JSONEdit.apply(.editElement(path: ["a"], index: 0, inner: .set(path: [], value: .json(1))), to: input)
        }
    }

    @Test func rejectsAnEmptyArrayPathAndAnInvalidRawElement() {
        #expect(throws: JSONEditError.emptyPath) {
            try JSONEdit.apply(.appendElement(path: [], value: .json(1)), to: [UInt8]("[]"))
        }
        #expect(throws: JSONEditError.invalidRawValue(.trailingContent(offset: 2))) {
            try JSONEdit.apply(.appendElement(path: ["a"], value: .raw([UInt8]("1 2"))), to: [UInt8](#"{"a": []}"#))
        }
    }
}

func arrayPaths(in node: JSONNode, prefix: [String]) -> [[String]] {
    switch node.kind {
    case .object(let members): members.flatMap { arrayPaths(in: $0.value, prefix: prefix + [$0.key]) }
    case .array: [prefix]
    case .string, .number, .bool, .null: []
    }
}

func elements(of node: JSONNode) -> [JSONNode] {
    if case .array(let elements) = node.kind { return elements }
    return []
}
