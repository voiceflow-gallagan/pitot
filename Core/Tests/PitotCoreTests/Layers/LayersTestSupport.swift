import Foundation

@testable import PitotCore

enum LayersFixtures {
    static func layer(_ id: LayerID, _ json: String) -> SettingsLayer {
        LayerLoader.layer(id: id, url: nil, bytes: Array(json.utf8))
    }

    static func settings(_ layers: (LayerID, String)...) -> EffectiveSettings {
        EffectiveSettings(layers: layers.map { layer($0.0, $0.1) })
    }

    static func problem(of layer: SettingsLayer) -> LayerProblem? {
        if case .invalid(let problem) = layer.state { return problem }
        return nil
    }

    static func isMissing(_ layer: SettingsLayer) -> Bool {
        layer.state == .missing
    }

    static func isUnreadable(_ layer: SettingsLayer) -> Bool {
        if case .unreadable = layer.state { return true }
        return false
    }

    static func tweak(_ id: String, _ location: Tweak.Location, _ valueType: Tweak.ValueType) -> Tweak {
        Tweak(
            id: id,
            location: location,
            valueType: valueType,
            defaultDescription: "unset",
            title: id,
            description: id,
            category: "Test",
            docURL: "https://code.claude.com/docs/en/settings"
        )
    }
}

/// SplitMix64, so the randomized layer tests repeat exactly for one seed.
struct LayersRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
