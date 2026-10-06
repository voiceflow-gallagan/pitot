import PitotCore
import Foundation
import Testing

@testable import ConformanceKit

@Suite("Catalog")
struct CatalogTests {
    @Test func fitsTheRunBudget() {
        #expect(Catalog.batches.count <= Catalog.maximumRuns)
    }

    @Test func caseIDsAreUnique() {
        let ids = Catalog.cases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func batchNamesAreUnique() {
        let names = Catalog.batches.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test(arguments: Catalog.batches.map(\.name))
    func batchWritesBothLayersWithOneProbePerEvent(name: String) throws {
        let batch = try #require(Catalog.batches.first { $0.name == name })
        #expect(Set(batch.settings.keys) == Set(Catalog.layers))
        #expect(Set(batch.probes.map(\.marker)).count == batch.probes.count)
        #expect(Set(batch.probes.map(\.layer)) == Set(Catalog.layers))
    }

    @Test(arguments: Catalog.batches.map(\.name))
    func everyCheckReadsSomethingTheBatchWrites(name: String) throws {
        let batch = try #require(Catalog.batches.first { $0.name == name })
        for check in batch.cases.flatMap(\.checks) {
            switch check {
            case .env(let variable):
                let setters = batch.settings.values.filter { $0["env"]?[variable] != nil }
                #expect(!setters.isEmpty, "\(variable) is in no file of \(name)")
            case .hook(let probe):
                #expect(batch.probes.contains(probe), "\(probe) is not a probe of \(name)")
            case .initField(let field):
                let setters = batch.settings.values.filter { root in
                    field.settingsPath.reduce(Optional(root)) { $0?[$1] } != nil
                }
                #expect(!setters.isEmpty, "\(field) is set by no file of \(name)")
            }
        }
    }

    @Test func variablesBelongToOneBatch() {
        var owners: [String: String] = [:]
        for batch in Catalog.batches {
            for root in batch.settings.values {
                guard case .object(let variables)? = root["env"] else { continue }
                for variable in variables {
                    #expect(owners[variable.key, default: batch.name] == batch.name, "\(variable.key) is in two batches")
                    owners[variable.key] = batch.name
                }
            }
        }
        #expect(owners.keys.allSatisfy { $0.hasPrefix("PITOT_CONF_") })
    }

    @Test func mutationTargetExists() throws {
        let target = Catalog.mutationTarget
        let conformanceCase = try #require(Catalog.cases.first { $0.id == target.caseID })
        #expect(conformanceCase.checks.contains(target.check))
    }
}
