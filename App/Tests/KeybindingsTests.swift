import PitotCore
import Foundation
import Testing

@testable import Pitot

@MainActor
struct KeybindingsTests {
    static let chatFile = """
        {
          "bindings": [
            {
              "context": "Chat",
              "bindings": {
                "ctrl+k": "chat:clearInput"
              }
            }
          ]
        }

        """

    private func decoded(_ fixture: ModelFixture) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.model.keybindings.url)) as? NSDictionary)
    }

    private func chatBindings(_ fixture: ModelFixture) throws -> NSDictionary? {
        let blocks = try #require(try decoded(fixture)["bindings"] as? [NSDictionary])
        return blocks.first { $0["context"] as? String == "Chat" }?["bindings"] as? NSDictionary
    }

    @Test func addingToAMissingFileCreatesItWithTheHeaderAndUndoRemovesIt() async throws {
        let fixture = try await ModelFixture.make()
        let keybindings = fixture.model.keybindings
        #expect(keybindings.isMissing)

        keybindings.request(.add(context: "Chat", key: "ctrl+k", action: "chat:clearInput"))
        #expect(keybindings.preview.createsFile)
        await keybindings.apply()
        let file = try decoded(fixture)
        #expect(file["$schema"] as? String == keybindings.catalog.header.schema)
        #expect(file["$docs"] as? String == keybindings.catalog.header.docs)
        #expect(try chatBindings(fixture) == ["ctrl+k": "chat:clearInput"])
        #expect(try fixture.backupCount() == 0)

        await keybindings.undo()
        #expect(!FileManager.default.fileExists(atPath: keybindings.url.path))
        #expect(keybindings.isMissing)
        #expect(!keybindings.canUndo)
    }

    @Test func changeActionWritesTheNewAction() async throws {
        let fixture = try await ModelFixture.make(keybindings: Self.chatFile)
        let keybindings = fixture.model.keybindings
        keybindings.request(.change(context: "Chat", key: "ctrl+k", action: "chat:clearScreen"))
        #expect(keybindings.groups().first?.rows.first?.isPending == true)
        await keybindings.apply()
        #expect(try chatBindings(fixture) == ["ctrl+k": "chat:clearScreen"])
        #expect(try fixture.backupCount() == 1)
    }

    @Test func unbindWritesNullAndUndoRestoresTheAction() async throws {
        let fixture = try await ModelFixture.make(keybindings: Self.chatFile)
        let keybindings = fixture.model.keybindings
        keybindings.request(.unbind(context: "Chat", key: "ctrl+k"))
        await keybindings.apply()
        #expect(try chatBindings(fixture)?["ctrl+k"] is NSNull)
        #expect(keybindings.groups().first?.rows.first?.action == nil)

        await keybindings.undo()
        #expect(try chatBindings(fixture) == ["ctrl+k": "chat:clearInput"])
    }

    @Test func removingTheLastBindingRemovesItsBlock() async throws {
        let fixture = try await ModelFixture.make(keybindings: Self.chatFile)
        let keybindings = fixture.model.keybindings
        keybindings.request(.remove(context: "Chat", key: "ctrl+k"))
        await keybindings.apply()
        #expect((try decoded(fixture)["bindings"] as? [Any])?.isEmpty == true)
        #expect(keybindings.groups().isEmpty)
    }

    @Test func duplicateAndReservedKeysAreRefused() async throws {
        let fixture = try await ModelFixture.make(keybindings: Self.chatFile)
        let keybindings = fixture.model.keybindings
        let duplicate = keybindings.request(.add(context: "Chat", key: "CTRL+K", action: "chat:clearScreen"))
        #expect(duplicate.contains { $0.kind == .duplicateKey })

        let reserved = keybindings.request(.add(context: "Global", key: "ctrl+c", action: "app:redraw"))
        #expect(reserved.contains { $0.kind == .reservedKey })
        let capsLock = keybindings.request(.add(context: "Global", key: "Caps Lock", action: "app:redraw"))
        #expect(capsLock.contains { $0.kind == .malformedKey })
        #expect(!keybindings.hasPending)

        let unknown = keybindings.request(.add(context: "Chat", key: "ctrl+y", action: "chat:somethingNew"))
        #expect(unknown.contains { $0.kind == .unknownAction && $0.severity == .warning })
        #expect(keybindings.hasPending)
    }

    @Test func legacyActionIsShownButNotOffered() async throws {
        let file = """
            {
              "bindings": [
                {"context": "MessageSelector", "bindings": {"k": "messageSelector:up"}}
              ]
            }
            """
        let fixture = try await ModelFixture.make(keybindings: file)
        let keybindings = fixture.model.keybindings
        let row = try #require(keybindings.groups().first?.rows.first)
        #expect(row.isLegacy)
        #expect(row.replacedBy == "select:previous")

        let offered = keybindings.actions(for: "MessageSelector").map(\.id)
        #expect(!offered.contains("messageSelector:up"))
        #expect(offered.contains("select:previous"))
        #expect(keybindings.actions(for: "Chat").allSatisfy { !$0.legacy })
    }

    @Test func pendingEditsApplyAsOneGroup() async throws {
        let fixture = try await ModelFixture.make(keybindings: Self.chatFile)
        let keybindings = fixture.model.keybindings
        keybindings.request(.add(context: "Chat", key: "ctrl+y", action: "chat:clearScreen"))
        keybindings.request(.remove(context: "Chat", key: "ctrl+k"))
        #expect(keybindings.pending.count == 2)
        await keybindings.apply()
        #expect(try chatBindings(fixture) == ["ctrl+y": "chat:clearScreen"])
        #expect(keybindings.undoLog.entries.count == 1)

        let entry = try #require(fixture.model.history.first)
        #expect(entry.layer == "Keybindings")
        #expect(entry.keys == ["Add Chat ctrl+y: chat:clearScreen", "Remove Chat ctrl+k"])
        #expect(entry.kind == nil)
    }

    @Test func outsideEditShowsTheBanner() async throws {
        let fixture = try await ModelFixture.make(keybindings: Self.chatFile)
        let keybindings = fixture.model.keybindings
        keybindings.startWatching()
        try Self.chatFile.replacingOccurrences(of: "chat:clearInput", with: "chat:clearScreen")
            .write(to: keybindings.url, atomically: true, encoding: .utf8)
        for _ in 0..<40 where !keybindings.externalChangeBanner {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(keybindings.externalChangeBanner)
        #expect(keybindings.groups().first?.rows.first?.action == "chat:clearScreen")
        keybindings.stopWatching()
    }

    @Test func settingsRejectNullButKeybindingsAcceptIt() async throws {
        let fixture = try await ModelFixture.make(keybindings: Self.chatFile)
        #expect(fixture.model.user.file.nullValuePolicy == .reject)
        #expect(fixture.model.keybindings.file.nullValuePolicy == .allow)
        let user = fixture.model.user
        let result = Result { () throws(SettingsFileError) in
            try user.file.apply(operations: [.set(path: ["model"], value: .json(.null))], expectedHash: user.expectedHash)
        }
        #expect(result.failureValue == .nullValueNotAllowed(path: ["model"]))

        fixture.model.keybindings.request(.unbind(context: "Chat", key: "ctrl+k"))
        await fixture.model.keybindings.apply()
        #expect(try chatBindings(fixture)?["ctrl+k"] is NSNull)
    }

    @Test func invalidFileDisablesEditing() async throws {
        let fixture = try await ModelFixture.make(keybindings: "{\"bindings\": {}}\n")
        let keybindings = fixture.model.keybindings
        #expect(keybindings.problem != nil)
        #expect(!keybindings.canEdit)
        keybindings.request(.add(context: "Chat", key: "ctrl+y", action: "chat:clearScreen"))
        #expect(!keybindings.hasPending)
    }

    @Test func keyPressesBecomeKeyStrings() {
        #expect(KeyStrokeText.text(keyCode: 40, base: "k", control: true, shift: true, option: false, command: false) == "ctrl+shift+k")
        #expect(KeyStrokeText.text(keyCode: 18, base: "1", control: false, shift: true, option: false, command: false) == "shift+1")
        #expect(KeyStrokeText.text(keyCode: 53, base: "\u{1B}", control: false, shift: false, option: false, command: false) == "escape")
        #expect(KeyStrokeText.text(keyCode: 36, base: "\r", control: true, shift: false, option: false, command: false) == "ctrl+enter")
        #expect(KeyStrokeText.text(keyCode: 40, base: "k", control: false, shift: false, option: true, command: true) == "alt+cmd+k")
        #expect(KeyStrokeText.text(keyCode: 122, base: "\u{F704}", control: false, shift: false, option: false, command: false) == nil)
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
