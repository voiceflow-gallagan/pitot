import Foundation
import Testing

@testable import PitotCore

@Suite struct KeybindingsEditorTests {
    static let sample = """
        {
          "bindings": [
            {
              "context": "Global",
              "bindings": {
                "ctrl+t": "app:toggleTodos",
                "ctrl+o": null
              }
            },
            {
              "context": "Chat",
              "bindings": {
                "ctrl+e": "chat:externalEditor"
              }
            }
          ]
        }

        """

    static func catalog() throws -> KeybindingsCatalog {
        try KeybindingsCatalogLoader.load(data: Data(try Fixtures.bytes(atRepoPath: "Catalog/keybindings.json")))
    }

    static func editor(_ text: String?) throws -> KeybindingsEditor {
        let document = try text.map { try JSONScanner.scan(Array($0)) }
        return try KeybindingsEditor(catalog: catalog(), document: document)
    }

    /// Applies the plan's operations in order and returns the final text and each result.
    static func run(_ plan: KeybindingsEditor.Plan, on text: String) throws -> (text: String, results: [JSONEdit.Result]) {
        var bytes = Array(text)
        var results: [JSONEdit.Result] = []
        for operation in plan.operations {
            let result = try JSONEdit.apply(operation, to: bytes)
            bytes = result.bytes
            results.append(result)
        }
        return (bytes.text, results)
    }

    private func edited(_ text: String, _ plan: (KeybindingsEditor) -> KeybindingsEditor.Plan) throws -> String {
        let result = plan(try Self.editor(text))
        #expect(!result.isBlocked)
        return try Self.run(result, on: text).text
    }

    @Test func addsToExistingBlock() throws {
        let text = try edited(Self.sample) { $0.addBinding(context: "Chat", key: "ctrl+k", action: "chat:stash") }
        #expect(text == Self.sample.replacingOccurrences(
            of: "        \"ctrl+e\": \"chat:externalEditor\"\n",
            with: "        \"ctrl+e\": \"chat:externalEditor\",\n        \"ctrl+k\": \"chat:stash\"\n"))
    }

    @Test func addsNewBlockForUnknownContextAfterTheLastBlock() throws {
        let text = try edited(Self.sample) { $0.addBinding(context: "Task", key: "ctrl+b", action: "task:background") }
        #expect(text == Self.expectedNewBlock)
    }

    static let expectedNewBlock = """
        {
          "bindings": [
            {
              "context": "Global",
              "bindings": {
                "ctrl+t": "app:toggleTodos",
                "ctrl+o": null
              }
            },
            {
              "context": "Chat",
              "bindings": {
                "ctrl+e": "chat:externalEditor"
              }
            },
            {
              "context": "Task",
              "bindings": {
                "ctrl+b": "task:background"
              }
            }
          ]
        }

        """

    @Test func addsBindingsArrayWhenMissing() throws {
        let original = "{\n  \"version\": 1\n}\n"
        let text = try edited(original) { $0.addBinding(context: "Chat", key: "ctrl+k", action: "chat:stash") }
        #expect(text == """
            {
              "version": 1,
              "bindings": [
                {
                  "context": "Chat",
                  "bindings": {
                    "ctrl+k": "chat:stash"
                  }
                }
              ]
            }

            """)
    }

    @Test func addsBindingsObjectToBlockWithoutOne() throws {
        let original = "{\n  \"bindings\": [\n    {\n      \"context\": \"Chat\"\n    }\n  ]\n}\n"
        let text = try edited(original) { $0.addBinding(context: "Chat", key: "ctrl+k", action: "chat:stash") }
        let file = try KeybindingsFile(document: JSONScanner.scan(Array(text)))
        #expect(file.blocks.map(\.context) == ["Chat"])
        #expect(file.blocks[0].bindings == [.init(key: "ctrl+k", action: "chat:stash")])
    }

    @Test func missingFileStartsFromTheDocsHeader() throws {
        let catalog = try Self.catalog()
        let initial = try KeybindingsEditor.initialContent(catalog: catalog).text
        #expect(initial == """
            {
              "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
              "$docs": "https://code.claude.com/docs/en/keybindings",
              "bindings": []
            }

            """)
        let editor = try Self.editor(nil)
        let plan = editor.addBinding(context: "Chat", key: "ctrl+e", action: "chat:externalEditor")
        #expect(plan.createsFile)
        #expect(try Self.run(plan, on: initial).text == """
            {
              "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
              "$docs": "https://code.claude.com/docs/en/keybindings",
              "bindings": [
                {
                  "context": "Chat",
                  "bindings": {
                    "ctrl+e": "chat:externalEditor"
                  }
                }
              ]
            }

            """)
        #expect(!(try Self.editor(Self.sample)).addBinding(context: "Chat", key: "ctrl+k", action: "chat:stash").createsFile)
    }

    @Test func contentThatDoesNotScanGivesATypedError() {
        #expect(throws: KeybindingsFileError.initialContentInvalid(.invalidUTF8(offset: 1))) {
            try KeybindingsEditor.scanInitialContent([0x7B, 0xFF, 0x7D])
        }
    }

    @Test func headerWithQuotesAndControlCharactersStillScans() throws {
        var catalog = try Self.catalog()
        catalog.header = .init(schema: "a\"b\\c\nd", docs: "https://x.test/\u{1}")
        let document = try JSONScanner.scan(KeybindingsEditor.initialContent(catalog: catalog))
        #expect(document.value(at: ["$schema"]) == "a\"b\\c\nd")
    }

    @Test func changesAnAction() throws {
        let text = try edited(Self.sample) { $0.changeAction(context: "Chat", key: "Ctrl+E", newAction: "chat:stash") }
        #expect(text == Self.sample.replacingOccurrences(of: "\"chat:externalEditor\"", with: "\"chat:stash\""))
    }

    @Test func unbindsWithNull() throws {
        let text = try edited(Self.sample) { $0.unbind(context: "Chat", key: "ctrl+e") }
        #expect(text == Self.sample.replacingOccurrences(of: "\"chat:externalEditor\"", with: "null"))
        #expect(try Self.editor(Self.sample).unbind(context: "Chat", key: "ctrl+e").allowsNullValues)
    }

    @Test func removesOneKeyAndKeepsTheBlock() throws {
        let text = try edited(Self.sample) { $0.removeBinding(context: "Global", key: "ctrl+o") }
        #expect(text == Self.sample.replacingOccurrences(of: ",\n        \"ctrl+o\": null", with: ""))
    }

    @Test func removingTheLastBindingRemovesTheBlock() throws {
        let text = try edited(Self.sample) { $0.removeBinding(context: "Chat", key: "ctrl+e") }
        #expect(text == Self.sample.replacingOccurrences(
            of: ",\n    {\n      \"context\": \"Chat\",\n      \"bindings\": {\n        \"ctrl+e\": \"chat:externalEditor\"\n      }\n    }", with: ""))
    }

    @Test func removingTheLastBindingKeepsABlockWithOtherFields() throws {
        let original = "{\n  \"bindings\": [\n    {\n      \"context\": \"Chat\",\n      \"note\": \"mine\",\n      \"bindings\": {\n        \"ctrl+e\": null\n      }\n    }\n  ]\n}\n"
        let text = try edited(original) { $0.removeBinding(context: "Chat", key: "ctrl+e") }
        let file = try KeybindingsFile(document: JSONScanner.scan(Array(text)))
        #expect(file.blocks.count == 1)
        #expect(file.blocks[0].bindings.isEmpty)
        #expect(file.blocks[0].extras == [.init(key: "note", value: "mine")])
    }

    @Test func refusesDuplicateKeysByNormalizedForm() throws {
        let editor = try Self.editor(Self.sample)
        for key in ["ctrl+e", "Ctrl+E", "control+e"] {
            let plan = editor.addBinding(context: "Chat", key: key, action: "chat:stash")
            #expect(plan.isBlocked)
            #expect(plan.operations.isEmpty)
            #expect(plan.issues.map(\.kind) == [.duplicateKey])
        }
        #expect(!editor.addBinding(context: "Global", key: "ctrl+e", action: "chat:stash").isBlocked)
    }

    @Test func refusesMalformedKeysAndMissingBindings() throws {
        let editor = try Self.editor(Self.sample)
        let malformed = editor.addBinding(context: "Chat", key: "ctl+k", action: "chat:stash")
        #expect(malformed.isBlocked && malformed.operations.isEmpty)
        for plan in [
            editor.changeAction(context: "Chat", key: "ctrl+x", newAction: "chat:stash"),
            editor.unbind(context: "Chat", key: "ctrl+x"),
            editor.removeBinding(context: "Nowhere", key: "ctrl+e"),
        ] {
            #expect(plan.isBlocked)
            #expect(plan.operations.isEmpty)
            #expect(plan.issues.map(\.kind) == [.bindingNotFound])
        }
    }

    @Test func acceptsLegacyActionWithANote() throws {
        let plan = try Self.editor(Self.sample).addBinding(context: "MessageSelector", key: "o", action: "messageSelector:select")
        #expect(!plan.isBlocked)
        #expect(plan.notes.count == 1)
        #expect(plan.notes[0].contains("select:accept"))
        #expect(!plan.operations.isEmpty)
    }

    @Test func allowsUnknownActionWithAWarning() throws {
        let plan = try Self.editor(Self.sample).addBinding(context: "Chat", key: "ctrl+k", action: "chat:levitate")
        #expect(!plan.isBlocked)
        #expect(plan.issues.map(\.kind) == [.unknownAction])
        #expect(plan.issues.first?.severity == .warning)
        #expect(!plan.operations.isEmpty)
    }

    @Test func keepsUnknownTopLevelKeysAndBlockFields() throws {
        let original = """
            {
              "$schema": "x",
              "version": 2,
              "bindings": [
                {
                  "context": "Chat",
                  "note": "mine",
                  "bindings": {
                    "ctrl+e": "chat:externalEditor"
                  }
                }
              ]
            }

            """
        let text = try edited(original) { $0.addBinding(context: "Chat", key: "ctrl+k", action: "chat:stash") }
        #expect(text == original.replacingOccurrences(
            of: "        \"ctrl+e\": \"chat:externalEditor\"\n",
            with: "        \"ctrl+e\": \"chat:externalEditor\",\n        \"ctrl+k\": \"chat:stash\"\n"))
    }

    @Test func everyOperationUndoesToTheOriginalBytes() throws {
        let editor = try Self.editor(Self.sample)
        let plans = [
            editor.addBinding(context: "Chat", key: "ctrl+k", action: "chat:stash"),
            editor.addBinding(context: "Task", key: "ctrl+b", action: "task:background"),
            editor.changeAction(context: "Chat", key: "ctrl+e", newAction: "chat:stash"),
            editor.changeAction(context: "Global", key: "ctrl+o", newAction: "app:toggleTranscript"),
            editor.unbind(context: "Global", key: "ctrl+t"),
            editor.removeBinding(context: "Global", key: "ctrl+o"),
            editor.removeBinding(context: "Chat", key: "ctrl+e"),
        ]
        for plan in plans {
            let (_, results) = try Self.run(plan, on: Self.sample)
            var bytes = try #require(results.last).bytes
            for result in results.reversed() {
                bytes = try JSONEdit.apply(result.inverse, to: bytes).bytes
            }
            #expect(bytes.text == Self.sample)
        }
    }

    @Test func summaryListsRowsInFileOrderWithCatalogData() throws {
        let original = """
            {"bindings": [
              {"context": "Chat", "bindings": {"ctrl+e": "chat:externalEditor", "ctrl+x": "chat:nope", "ctrl+c": null}},
              {"context": "MessageSelector", "bindings": {"o": "messageSelector:select"}}
            ]}
            """
        let editor = try Self.editor(original)
        let summary = editor.summary()
        #expect(summary.map(\.context) == ["Chat", "MessageSelector"])
        let chat = summary[0].rows
        #expect(chat.map(\.key) == ["ctrl+e", "ctrl+x", "ctrl+c"])
        #expect(chat[0].action == "chat:externalEditor")
        #expect(chat[0].description == "Opens the prompt in your external editor")
        #expect(chat[0].defaultKey == "Ctrl+G, Ctrl+X Ctrl+E")
        #expect(chat[0].issues.isEmpty)
        #expect(chat[1].issues.map(\.kind) == [.unknownAction])
        #expect(chat[1].description == nil)
        #expect(chat[2].action == nil)
        #expect(chat[2].issues.map(\.kind) == [.reservedKey])
        #expect(summary[1].rows[0].isLegacyAction)
        #expect(chat[0].isLegacyAction == false)
    }
}
