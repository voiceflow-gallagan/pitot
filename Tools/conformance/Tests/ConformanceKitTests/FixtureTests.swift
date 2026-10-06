import PitotCore
import Foundation
import Testing

@testable import ConformanceKit

@Suite("Fixtures")
struct FixtureTests {
    static let workDirectory = URL(fileURLWithPath: "/tmp/pitot conformance/it's here", isDirectory: true)

    static var plans: [BatchPlan] {
        Catalog.batches.map { BatchPlan(batch: $0, workDirectory: workDirectory) }
    }

    @Test func renderedFilesParseBackToTheSameContent() throws {
        for plan in Self.plans {
            for layer in Catalog.layers {
                let document = try JSONScanner.scan(plan.bytes(for: layer))
                #expect(document.decode(document.root) == plan.content(for: layer), "\(plan.batch.name) \(layer)")
            }
        }
    }

    @Test func renderEscapesStrings() throws {
        let value: JSONValue = ["text": "a \"quote\", a \\ backslash, a\ttab, a\nline and \u{1}"]
        let document = try JSONScanner.scan(Array(JSONText.render(value).utf8))
        #expect(document.decode(document.root) == value)
    }

    @Test func renderKeepsEmptyContainersAndNull() {
        #expect(JSONText.render(["env": [:], "list": [], "nothing": nil]) == """
            {
              "env": {},
              "list": [],
              "nothing": null
            }

            """)
    }

    @Test func processTextMatchesWhatAShellSees() {
        #expect(JSONText.processText("value") == "value")
        #expect(JSONText.processText(nil) == "null")
        #expect(JSONText.processText(true) == "true")
        #expect(JSONText.processText(42) == "42")
    }

    @Test func shellQuoteSurvivesSingleQuotes() {
        #expect(Shell.quote("plain") == "'plain'")
        #expect(Shell.quote("it's") == #"'it'\''s'"#)
    }

    @Test func everyProbeCommandMapsBackToItsProbe() {
        for plan in Self.plans {
            for probe in plan.batch.probes {
                #expect(plan.probe(forCommand: plan.command(for: probe)) == probe)
            }
            #expect(plan.probe(forCommand: "/bin/sh other.sh") == nil)
        }
    }

    @Test func hooksGoInTheirLayerFileUnderTheirEvent() throws {
        for plan in Self.plans {
            for probe in plan.batch.probes {
                let groups = plan.content(for: probe.layer)["hooks"]?[probe.event]?.elements ?? []
                let commands = groups.flatMap { $0["hooks"]?.elements ?? [] }.compactMap { handler -> String? in
                    guard case .string(let command)? = handler["command"] else { return nil }
                    return command
                }
                #expect(commands == [plan.command(for: probe)])
            }
        }
    }

    @Test func settingsFilesAreTheProjectAndLocalFiles() {
        let plan = BatchPlan(batch: Catalog.batches[0], workDirectory: Self.workDirectory)
        #expect(plan.settingsURL(for: .project).path.hasSuffix("/merge/.claude/settings.json"))
        #expect(plan.settingsURL(for: .local).path.hasSuffix("/merge/.claude/settings.local.json"))
    }

    @Test func runNeverLoadsTheUserLayerOrAnExtraSettingsFile() throws {
        let arguments = BatchPlan(batch: Catalog.batches[0], workDirectory: Self.workDirectory).arguments()
        let sources = try #require(arguments.firstIndex(of: "--setting-sources"))
        #expect(arguments[sources + 1] == "project,local")
        #expect(!arguments.contains("--settings"))
        let model = try #require(arguments.firstIndex(of: "--model"))
        #expect(arguments[model + 1] == "haiku")
        #expect(arguments.prefix(2) == ["-p", BatchPlan.prompt])
    }

    @Test func childEnvironmentDropsVariablesThatCouldFakeAResult() {
        let environment = ClaudeRunner.environment(from: ["PATH": "/bin", "PITOT_CONF_1": "x", "CONFORMANCE_MUTATE": "1"])
        #expect(environment == ["PATH": "/bin"])
    }
}
