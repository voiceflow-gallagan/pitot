import Foundation
import Testing

@testable import PitotCore

@Suite("Layers: layer ids and loading")
struct LayersLoaderTests {
    @Test func precedenceIsManagedLocalProjectUser() {
        #expect(LayerID.byPrecedence == [.managed, .local, .project, .user])
        #expect(LayerID.allCases == [.user, .project, .local, .managed])
        #expect(LayerID.local > LayerID.project)
        #expect(LayerID.managed > LayerID.local)
        #expect(LayerID.project > LayerID.user)
    }

    @Test func writableLayersMapToCatalogKinds() {
        for kind in SettingsLayerKind.allCases {
            #expect(LayerID(kind).writableKind == kind)
        }
        #expect(LayerID.managed.writableKind == nil)
    }

    @Test func missingFileIsNormal() throws {
        let folder = try TemporaryDirectory()
        let layer = LayerLoader.load(id: .user, url: folder.file("settings.json"))

        #expect(layer.state == .missing)
        #expect(layer.url == folder.file("settings.json"))
        #expect(layer.document == nil)
    }

    @Test func missingFolderIsMissing() throws {
        let folder = try TemporaryDirectory()
        #expect(LayersFixtures.isMissing(LayerLoader.load(id: .project, url: folder.file("absent/.claude/settings.json"))))

        try folder.write("claude-file", "{}")
        #expect(LayersFixtures.isMissing(LayerLoader.load(id: .project, url: folder.file("claude-file/settings.json"))))
    }

    @Test func loadsAnObjectFromDisk() throws {
        let folder = try TemporaryDirectory()
        let url = try folder.write("settings.json", #"{"model": "opus", "env": {"A": "1"}}"#)
        let layer = LayerLoader.load(id: .local, url: url)

        let document = try #require(layer.document)
        #expect(document.value(at: ["model"]) == "opus")
        #expect(document.bytes == (try readBytes(url)))
    }

    @Test func emptyFileCountsAsEmptyObject() throws {
        for text in ["", "  \n\t"] {
            let document = try #require(LayersFixtures.layer(.user, text).document)
            #expect(document.decode(document.root) == .object([]))
        }
    }

    @Test func invalidJSONIsAnErrorLayer() {
        let layer = LayersFixtures.layer(.project, #"{"model": "opus",}"#)

        guard case .syntax(.trailingComma)? = LayersFixtures.problem(of: layer) else {
            Issue.record("expected a syntax problem, got \(layer.state)")
            return
        }
        #expect(layer.document == nil)
    }

    @Test func topLevelMustBeAnObject() {
        #expect(LayersFixtures.problem(of: LayersFixtures.layer(.user, "[1, 2]")) == .notAnObject)
        #expect(LayersFixtures.problem(of: LayersFixtures.layer(.managed, "\"text\"")) == .notAnObject)
    }

    @Test func nullAtTypedKeyInvalidatesTheFile() throws {
        let layer = LayersFixtures.layer(.local, #"{"outputStyle": null, "model": "opus"}"#)
        let problem = try #require(LayersFixtures.problem(of: layer))

        #expect(problem == .nullValue(path: ["outputStyle"]))
        #expect(problem.description.contains("null value makes Claude Code ignore the file"))
    }

    @Test func nullObjectAndNestedNullInvalidateTheFile() {
        #expect(LayersFixtures.problem(of: LayersFixtures.layer(.user, #"{"permissions": null}"#)) == .nullValue(path: ["permissions"]))
        #expect(LayersFixtures.problem(of: LayersFixtures.layer(.user, #"{"env": null}"#)) == .nullValue(path: ["env"]))
        #expect(
            LayersFixtures.problem(of: LayersFixtures.layer(.user, #"{"permissions": {"allow": ["Read", null]}}"#))
                == .nullValue(path: ["permissions", "allow", "1"])
        )
    }

    @Test func nullEnvVariableIsAccepted() throws {
        let document = try #require(LayersFixtures.layer(.local, #"{"env": {"A": null, "B": "x"}}"#).document)
        #expect(document.value(at: ["env", "A"]) == .null)
    }

    @Test(.enabled(if: getuid() != 0, "root can read a file with mode 000"))
    func unreadableFileIsReported() throws {
        let folder = try TemporaryDirectory()
        let url = try folder.write("settings.json", "{}")
        chmod(url.path, 0)

        let layer = LayerLoader.load(id: .user, url: url)
        guard case .unreadable(let reason) = layer.state else {
            Issue.record("expected unreadable, got \(layer.state)")
            return
        }
        #expect(reason.contains(url.path))
    }

    @Test func folderInPlaceOfFileIsUnreadable() throws {
        let folder = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: folder.file("settings.json"), withIntermediateDirectories: false)

        #expect(LayersFixtures.isUnreadable(LayerLoader.load(id: .user, url: folder.file("settings.json"))))
    }

    @Test func managedNullRemovesTheKeyInsteadOfTheFile() throws {
        let layer = LayersFixtures.layer(.managed, #"{"model": null, "outputStyle": "x", "env": {"A": null}, "permissions": {"deny": ["Bash", null], "ask": null}}"#)
        let document = try #require(layer.document)

        #expect(document.value(at: ["model"]) == nil)
        #expect(document.value(at: ["outputStyle"]) == "x")
        #expect(document.value(at: ["env", "A"]) == .null)
        #expect(document.value(at: ["permissions"]) == ["deny": ["Bash"]])
    }

    @Test func problemDescriptionsNameTheCause() {
        #expect(LayerProblem.notAnObject.description == "the top level is not a JSON object")
        #expect(LayerProblem.syntax(.emptyInput).description.contains("invalid JSON"))
        #expect(
            LayerProblem.managedFile(name: "managed-settings.d/20-x.json", problem: .notAnObject).description
                == "managed-settings.d/20-x.json: the top level is not a JSON object"
        )
    }
}
