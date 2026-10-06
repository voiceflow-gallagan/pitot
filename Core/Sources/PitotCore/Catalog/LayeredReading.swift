/// What the merged settings hold for one tweak, and which layer it comes from.
public struct LayeredReading: Sendable, Equatable {
    public let reading: TweakReading
    /// The layer whose value is in effect. Nil when no layer sets the tweak.
    public let winner: LayerID?
    /// Layers that set the tweak but lose, highest first.
    public let overridden: [LayerID]

    public init(reading: TweakReading, winner: LayerID?, overridden: [LayerID]) {
        self.reading = reading
        self.winner = winner
        self.overridden = overridden
    }
}

extension Tweak {
    /// Reads this tweak from the settings a session gets from all layers.
    public func reading(in effective: EffectiveSettings) -> LayeredReading {
        guard let value = effective.value(for: self) else { return LayeredReading(reading: .unset, winner: nil, overridden: []) }
        return LayeredReading(reading: reading(from: value.value), winner: value.winner, overridden: value.overriddenLayers)
    }
}

extension Tweak.Confirmation {
    /// `isRequired(for:old:new:)` with the value in effect across all layers as the old value, so
    /// turning a row off in one layer confirms even when the on value comes from another layer.
    public static func isRequired(for tweak: Tweak, old: LayeredReading, new: TweakValue?) -> Bool {
        isRequired(for: tweak, old: old.reading, new: new)
    }
}
