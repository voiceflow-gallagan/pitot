import PitotCore
import Foundation
import Testing

@testable import Pitot

@MainActor
struct UnverifiedTests {
    @Test func bundledListLoadsAndGroupsByStatusAndKind() async throws {
        let catalog = try bundledUnverified()
        #expect(catalog.keys.count == 15)
        let sections = UnverifiedList.sections(catalog, layers: [], search: "")
        #expect(sections.map(\.title) == ["Not documented settings", "Unverified settings", "Unverified env vars"])
        #expect(sections.map(\.rows.count) == [11, 2, 2])
        #expect(sections.flatMap(\.rows).allSatisfy { $0.presence == "Not found in your files" })
    }

    @Test func shippedListHoldsNamesOnly() throws {
        let keys = try bundledUnverified().keys
        #expect(keys.allSatisfy { $0.description.isEmpty })
        #expect(keys.allSatisfy { $0.seenIn == ["schema"] || $0.notes.isEmpty })
        #expect(UnverifiedList.sections(try bundledUnverified(), layers: [], search: "").flatMap(\.rows).allSatisfy { $0.description == "No description" })
        let internalNames = ["doneMeansMerged", "modelProposedGoals", "remoteControl", "remoteTools", "skipWorkflowUsageWarning", "totalTokensReminder"]
        #expect(keys.allSatisfy { key in !internalNames.contains(where: { key.name.hasPrefix($0) }) })
        #expect(UnverifiedList.header.contains("not an endorsement"))
    }

    @Test func noUnverifiedKeyIsAnEditableTweak() async throws {
        let tweaks = try bundledCatalog().tweaks
        var editable = Set(tweaks.map(\.id))
        for tweak in tweaks {
            editable.insert(tweak.keyText)
            if let first = tweak.location.path.first, tweak.location.envName == nil { editable.insert(first) }
            if let name = tweak.location.envName { editable.insert(name) }
        }
        let overlap = try bundledUnverified().keys.map(\.name).filter(editable.contains)
        #expect(overlap.isEmpty)
    }

    @Test func presenceNamesTheLayersThatHoldTheKey() async throws {
        let fixture = try await ModelFixture.make("{\n  \"autoDreamEnabled\": true,\n  \"env\": {\n    \"CLAUDE_TMPDIR\": \"/tmp/claude\"\n  }\n}\n")
        let project = try fixture.makeProject(local: "{\n  \"autoDreamEnabled\": false\n}\n")
        await fixture.model.selectProject(project)
        let rows = fixture.model.unverifiedSections.flatMap(\.rows)
        #expect(rows.first { $0.name == "autoDreamEnabled" }?.presence == "Present in your files: Project-local, User")
        #expect(rows.first { $0.name == "CLAUDE_TMPDIR" }?.presence == "Present in your files: User")
        #expect(rows.first { $0.name == "daemonColdStart" }?.presence == "Not found in your files")
    }

    @Test func searchFiltersTheList() async throws {
        let fixture = try await ModelFixture.make()
        fixture.model.searchText = "tmpdir"
        #expect(fixture.model.unverifiedSections.flatMap(\.rows).map(\.name) == ["CLAUDE_TMPDIR"])
    }

    @Test func rowsHoldTextOnlyAndNoActions() async throws {
        let row = try #require(UnverifiedList.sections(try bundledUnverified(), layers: [], search: "").first?.rows.first)
        for child in Mirror(reflecting: row).children {
            #expect(child.value is String, "\(child.label ?? "?") is not text")
        }
        #expect(row.description == "No description" || !row.description.isEmpty)
    }

    @Test func descriptionAndNotesMayBeLeftOut() throws {
        let text = """
            {"researchDate": "x", "claudeCodeVersionChecked": "2.1.291", "docsChecked": [], "note": "n",
             "keys": [{"name": "a", "kind": "setting", "status": "hidden", "seenIn": ["binary"]}]}
            """
        let key = try #require(try JSONDecoder().decode(UnverifiedCatalog.self, from: Data(text.utf8)).keys.first)
        #expect(key.description.isEmpty && key.notes.isEmpty)
    }

    @Test func strictDecodingRejectsUnknownKeys() {
        let text = """
            {"researchDate": "x", "claudeCodeVersionChecked": "2.1.291", "docsChecked": [], "note": "n",
             "keys": [{"name": "a", "kind": "setting", "status": "hidden", "seenIn": [], "description": "", "notes": "", "editable": true}]}
            """
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(UnverifiedCatalog.self, from: Data(text.utf8)) }
    }
}
