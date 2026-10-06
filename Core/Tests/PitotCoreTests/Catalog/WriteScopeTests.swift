import Foundation
import Testing

@testable import PitotCore

@Suite("Write scope")
struct WriteScopeTests {
    private static let sharedLayers: [SettingsLayerKind] = [.project, .local]

    private let mode: Tweak = {
        let options = ["default", "plan", "auto", "bypassPermissions"].map { Tweak.Option(value: $0, label: $0) }
        var tweak = CatalogSamples.tweak("mode", valueType: .enumeration(options))
        tweak.userOnlyValues = ["auto", "bypassPermissions"]
        return tweak
    }()

    private let userOnlyRow = CatalogSamples.tweak("askUserQuestionTimeout", valueType: .string, scope: .userOnly)

    @Test func layerKindsAreUserProjectLocal() throws {
        #expect(SettingsLayerKind.allCases == [.user, .project, .local])
        #expect(try JSONEncoder().encode(SettingsLayerKind.local) == Data(#""local""#.utf8))
    }

    @Test("every value is allowed in the user layer", arguments: [TweakValue?.some("auto"), "bypassPermissions", "plan", nil])
    func userLayerAllowsEverything(value: TweakValue?) {
        #expect(mode.canWrite(in: .user, value: value) == .allowed)
        #expect(userOnlyRow.canWrite(in: .user, value: value) == .allowed)
    }

    @Test("user-only values are refused in project and local", arguments: sharedLayers)
    func userOnlyValuesRefusedInSharedLayers(layer: SettingsLayerKind) {
        for value: TweakValue in ["auto", "bypassPermissions"] {
            guard case .refused(let reason) = mode.canWrite(in: layer, value: value) else {
                Issue.record("\(value) was allowed in \(layer)")
                continue
            }
            #expect(reason.contains(value.displayText))
        }
    }

    @Test("other values and removal are allowed in project and local", arguments: sharedLayers)
    func otherValuesAllowedInSharedLayers(layer: SettingsLayerKind) {
        #expect(mode.canWrite(in: layer, value: "plan") == .allowed)
        #expect(mode.canWrite(in: layer, value: "default") == .allowed)
        #expect(mode.canWrite(in: layer, value: nil) == .allowed)
    }

    @Test("a user-only row is refused in project and local for any value", arguments: sharedLayers)
    func userOnlyRowRefusedInSharedLayers(layer: SettingsLayerKind) {
        for value: TweakValue? in ["5m", nil] {
            guard case .refused(let reason) = userOnlyRow.canWrite(in: layer, value: value) else {
                Issue.record("\(String(describing: value)) was allowed in \(layer)")
                continue
            }
            #expect(!reason.isEmpty)
        }
    }

    @Test("a row without limits is allowed everywhere", arguments: SettingsLayerKind.allCases)
    func plainRowAllowedEverywhere(layer: SettingsLayerKind) {
        #expect(CatalogSamples.tweak("plain").canWrite(in: layer, value: true) == .allowed)
    }
}
