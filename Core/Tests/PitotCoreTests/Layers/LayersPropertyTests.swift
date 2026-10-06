import Foundation
import Testing

@testable import PitotCore

@Suite("Layers: randomized merge")
struct LayersPropertyTests {
    private static let iterations = 500
    private static let plainKeys = ["a", "b", "c", "env"]
    private static let specialKeys = [
        "a", "b", "modelPicker", "fallbackModel", "extraKnownMarketplaces", "managedMcpServers",
        "availableModels", "deniedModels", "maxEffortLevel", "crossSessionInbound", "disableClaudeAiConnectors",
    ]
    private static let words: [JSONValue] = ["x", "y", "hold", "refuse", "low", "max"]

    /// Objects merge key by key, arrays join with repeated primitives removed, anything else is replaced.
    private static func referenceMerge(_ lower: JSONValue?, _ upper: JSONValue) -> JSONValue {
        switch (lower, upper) {
        case (.object(let lowerMembers)?, .object(let upperMembers)):
            var members = lowerMembers
            for member in upperMembers {
                if let index = members.firstIndex(where: { $0.key == member.key }) {
                    members[index] = JSONValue.Member(key: member.key, value: referenceMerge(members[index].value, member.value))
                } else {
                    members.append(member)
                }
            }
            return .object(members)
        case (.array(let lowerElements)?, .array(let upperElements)):
            var elements: [JSONValue] = []
            for element in lowerElements + upperElements {
                if case .object = element {
                    elements.append(element)
                } else if !elements.contains(element) {
                    elements.append(element)
                }
            }
            return .array(elements)
        default:
            return upper
        }
    }

    private static func lookup(_ value: JSONValue, _ path: [String]) -> JSONValue? {
        var node = value
        for key in path {
            guard case .object(let members) = node, let member = members.first(where: { $0.key == key }) else { return nil }
            node = member.value
        }
        return node
    }

    private static func objectPaths(in value: JSONValue, prefix: [String] = []) -> [[String]] {
        guard case .object(let members) = value else { return [] }
        return members.flatMap { [prefix + [$0.key]] + objectPaths(in: $0.value, prefix: prefix + [$0.key]) }
    }

    private static func scalar(using random: inout LayersRandom) -> JSONValue {
        switch Int.random(in: 0..<4, using: &random) {
        case 0: .number(JSONNumber(Int.random(in: 0...3, using: &random)))
        case 1: .bool(Bool.random(using: &random))
        case 2: ["k": .number(JSONNumber(Int.random(in: 0...1, using: &random)))]
        default: words[Int.random(in: 0..<words.count, using: &random)]
        }
    }

    private static func value(depth: Int, keys: [String], using random: inout LayersRandom) -> JSONValue {
        switch Int.random(in: 0..<(depth >= 3 ? 3 : 5), using: &random) {
        case 0, 1: return scalar(using: &random)
        case 2: return .array((0..<Int.random(in: 0...3, using: &random)).map { _ in scalar(using: &random) })
        default: return object(depth: depth + 1, keys: keys, using: &random)
        }
    }

    private static func object(depth: Int, keys: [String], using random: inout LayersRandom) -> JSONValue {
        var members: [JSONValue.Member] = []
        for _ in 0..<Int.random(in: 0...4, using: &random) {
            let key = keys[Int.random(in: 0..<keys.count, using: &random)]
            guard !members.contains(where: { $0.key == key }) else { continue }
            members.append(JSONValue.Member(key: key, value: value(depth: depth, keys: keys, using: &random)))
        }
        return .object(members)
    }

    private static func randomRoots(keys: [String], using random: inout LayersRandom) -> [LayerID: JSONValue] {
        var roots: [LayerID: JSONValue] = [:]
        for id in LayerID.allCases where Int.random(in: 0..<5, using: &random) > 0 {
            roots[id] = object(depth: 0, keys: keys, using: &random)
        }
        return roots
    }

    private static func settings(_ roots: [LayerID: JSONValue]) -> EffectiveSettings {
        EffectiveSettings(layers: roots.map { SettingsLayer(id: $0.key, url: nil, state: .loaded(JSONWriter.document($0.value))) })
    }

    private static func randomPaths(keys: [String], using random: inout LayersRandom) -> [[String]] {
        (0..<8).map { _ in
            (0..<Int.random(in: 1...3, using: &random)).map { _ in keys[Int.random(in: 0..<keys.count, using: &random)] }
        }
    }

    @Test func effectiveValuesMatchAReferenceMerge() throws {
        var random = LayersRandom(seed: 0x00C0_C917_2026_1006)
        for _ in 0..<Self.iterations {
            let roots = Self.randomRoots(keys: Self.plainKeys, using: &random)
            let settings = Self.settings(roots)
            let reference = LayerID.allCases.compactMap { roots[$0] }.reduce(JSONValue.object([])) { Self.referenceMerge($0, $1) }

            #expect(settings.merged == reference)
            for path in Self.objectPaths(in: reference) {
                let expected = try #require(Self.lookup(reference, path))
                let highest = LayerID.byPrecedence.first { id in roots[id].flatMap { Self.lookup($0, path) } != nil }
                let effective = try #require(settings.value(at: path), "no effective value at \(path)")

                #expect(effective.value == expected, "value at \(path)")
                #expect(effective.winner == highest, "winner at \(path)")
                if case .object = expected { continue }
                if case .array = expected { continue }
                #expect(roots[effective.winner].flatMap { Self.lookup($0, path) } == expected, "scalar at \(path) comes from the winner")
            }
            for path in Self.randomPaths(keys: Self.plainKeys, using: &random) where Self.lookup(reference, path) == nil {
                #expect(settings.value(at: path) == nil, "value at absent \(path)")
            }
        }
    }

    @Test func pathResolutionAgreesWithTheMergedTree() throws {
        var random = LayersRandom(seed: 0x1A7E_25ED_0000_0001)
        for _ in 0..<Self.iterations {
            let roots = Self.randomRoots(keys: Self.specialKeys, using: &random)
            let settings = Self.settings(roots)
            let layerPaths = roots.values.flatMap { Self.objectPaths(in: $0) }
            let paths = Self.objectPaths(in: settings.merged) + layerPaths + Self.randomPaths(keys: Self.specialKeys, using: &random)

            for path in paths {
                let resolved = settings.resolver.resolve(path)
                #expect(resolved.value == SettingsTree.value(in: settings.merged, at: path), "resolution at \(path)")
                #expect((settings.value(at: path) == nil) == (resolved.value == nil), "presence at \(path)")
            }
        }
    }

    @Test func writtenDocumentsScanBackUnchanged() throws {
        var random = LayersRandom(seed: 0xD0C5_0000_0000_0002)
        for _ in 0..<Self.iterations {
            let root = Self.object(depth: 0, keys: Self.specialKeys + ["quote\"d", "ü\n\u{1}"], using: &random)
            let document = JSONWriter.document(root)

            #expect(try JSONScanner.scan(document.bytes) == document)
            #expect(document.decode(document.root) == root)
        }
    }
}
