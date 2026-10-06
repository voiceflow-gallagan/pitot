extension Tweak.Confirmation {
    /// Whether changing `tweak` from what the file holds to `new` needs the row's confirmation.
    /// A nil `new` removes the key. False when the row has no confirmation.
    ///
    /// An unset key means the row's `defaultValue`, or off when it has none. A value the row cannot
    /// read never skips a confirmation: it counts as off for `onEnable` and as on for `onDisable`.
    public static func isRequired(for tweak: Tweak, old: TweakReading, new: TweakValue?) -> Bool {
        tweak.confirm?.applies(old: old, new: new, defaultValue: tweak.defaultValue) ?? false
    }

    /// The same rule for a row whose default is not known, so an unset key counts as off.
    public func isRequired(changingFrom old: TweakValue?, to new: TweakValue?) -> Bool {
        applies(old: old.map(TweakReading.value) ?? .unset, new: new, defaultValue: nil)
    }

    private func applies(old: TweakReading, new: TweakValue?, defaultValue: TweakValue?) -> Bool {
        let newValue = new ?? defaultValue
        let newIsOn = newValue?.isActive ?? false
        switch appliesWhen {
        case .onEnable:
            return Self.isOn(old, defaultValue: defaultValue) != true && newIsOn
        case .onDisable:
            return Self.isOn(old, defaultValue: defaultValue) != false && !newIsOn
        case .onAnyChange:
            return old != (new.map(TweakReading.value) ?? .unset)
        case .whenValue(let value):
            let oldValue = old == .unset ? defaultValue : old.value
            return newValue == value && oldValue != value
        }
    }

    /// Nil when the file holds something the row cannot read.
    private static func isOn(_ reading: TweakReading, defaultValue: TweakValue?) -> Bool? {
        switch reading {
        case .unset: defaultValue?.isActive ?? false
        case .value(let value): value.isActive
        case .unrecognized: nil
        }
    }
}
