import Testing

@testable import PitotCore

@Suite struct KeybindingsFileTests {
    private func read(_ text: String) throws(KeybindingsFileError) -> KeybindingsFile {
        let document: JSONDocument
        do {
            document = try JSONScanner.scan(Array(text))
        } catch {
            preconditionFailure("Test sample is not valid JSON: \(error)")
        }
        return try KeybindingsFile(document: document)
    }

    @Test func readsMultiLineFileInOrder() throws {
        let file = try read("""
            {
              "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
              "$docs": "https://code.claude.com/docs/en/keybindings",
              "bindings": [
                {
                  "context": "Chat",
                  "bindings": {
                    "ctrl+e": "chat:externalEditor",
                    "ctrl+s": null
                  }
                },
                {
                  "context": "Confirmation",
                  "bindings": { "y": "confirm:yes" }
                }
              ]
            }
            """)
        #expect(file.schema == "https://www.schemastore.org/claude-code-keybindings.json")
        #expect(file.docs == "https://code.claude.com/docs/en/keybindings")
        #expect(file.blocks.map(\.context) == ["Chat", "Confirmation"])
        #expect(file.blocks[0].bindings == [
            .init(key: "ctrl+e", action: "chat:externalEditor"),
            .init(key: "ctrl+s", action: nil),
        ])
        #expect(file.blocks[1].bindings == [.init(key: "y", action: "confirm:yes")])
        #expect(file.extras.isEmpty)
    }

    @Test func readsEmptyBindingsArray() throws {
        let file = try read(#"{"bindings": []}"#)
        #expect(file.blocks.isEmpty)
        #expect(file.schema == nil)
    }

    @Test func readsEmptyObjectAndEmptyBlock() throws {
        #expect(try read("{}").blocks.isEmpty)
        let file = try read(#"{"bindings": [{"context": "Chat", "bindings": {}}, {"context": "Task"}]}"#)
        #expect(file.blocks.map(\.context) == ["Chat", "Task"])
        #expect(file.blocks.allSatisfy { $0.bindings.isEmpty })
    }

    @Test func preservesUnknownTopLevelAndBlockFields() throws {
        let file = try read("""
            {
              "version": 2,
              "bindings": [
                {"context": "Chat", "note": "mine", "bindings": {"ctrl+e": "chat:externalEditor"}}
              ],
              "future": {"a": [1, 2]}
            }
            """)
        #expect(file.extras == [
            .init(key: "version", value: 2),
            .init(key: "future", value: .object([.init(key: "a", value: [1, 2])])),
        ])
        #expect(file.blocks[0].extras == [.init(key: "note", value: "mine")])
        #expect(file.blocks[0].bindings.count == 1)
    }

    @Test func keepsNonStringHeaderAsExtra() throws {
        let file = try read(#"{"$schema": 5, "bindings": []}"#)
        #expect(file.schema == nil)
        #expect(file.extras == [.init(key: "$schema", value: 5)])
    }

    @Test func rejectsWrongShapes() {
        #expect(throws: KeybindingsFileError.rootNotObject) { try read("[]") }
        #expect(throws: KeybindingsFileError.bindingsNotArray) { try read(#"{"bindings": {}}"#) }
        #expect(throws: KeybindingsFileError.blockNotObject(index: 1)) { try read(#"{"bindings": [{"context": "Chat"}, "x"]}"#) }
        #expect(throws: KeybindingsFileError.contextMissing(block: 0)) { try read(#"{"bindings": [{"bindings": {}}]}"#) }
        #expect(throws: KeybindingsFileError.contextNotString(block: 0)) { try read(#"{"bindings": [{"context": 3}]}"#) }
        #expect(throws: KeybindingsFileError.blockBindingsNotObject(block: 0)) { try read(#"{"bindings": [{"context": "Chat", "bindings": []}]}"#) }
        #expect(throws: KeybindingsFileError.actionNotStringOrNull(block: 0, key: "ctrl+k")) {
            try read(#"{"bindings": [{"context": "Chat", "bindings": {"ctrl+k": 1}}]}"#)
        }
        #expect(throws: KeybindingsFileError.actionNotStringOrNull(block: 0, key: "ctrl+k")) {
            try read(#"{"bindings": [{"context": "Chat", "bindings": {"ctrl+k": ["a"]}}]}"#)
        }
    }
}
