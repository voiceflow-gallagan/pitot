import Testing

@testable import PitotCore

@Suite("Confirmation")
struct ConfirmationTests {
    private func row(_ trigger: Tweak.Confirmation.AppliesWhen, valueType: Tweak.ValueType = .bool, defaultValue: TweakValue? = nil) -> Tweak {
        var tweak = CatalogSamples.tweak("row", valueType: valueType, confirm: Tweak.Confirmation(message: "Sure?", appliesWhen: trigger))
        tweak.defaultValue = defaultValue
        return tweak
    }

    private func asks(_ tweak: Tweak, from old: TweakReading, to new: TweakValue?) -> Bool {
        Tweak.Confirmation.isRequired(for: tweak, old: old, new: new)
    }

    @Test func rowWithoutConfirmNeverAsks() {
        #expect(!asks(CatalogSamples.tweak("plain"), from: .value(true), to: false))
        #expect(!asks(CatalogSamples.tweak("plain"), from: .unrecognized(1), to: nil))
    }

    // MARK: onDisable

    @Test("onDisable asks when an on row goes off or is reset", arguments: [TweakValue.bool(false), nil])
    func onDisableAsksWhenTurnedOff(new: TweakValue?) {
        #expect(asks(row(.onDisable), from: .value(true), to: new))
    }

    @Test(
        "onDisable stays quiet when the row stays off or turns on",
        arguments: [
            (TweakReading.unset, TweakValue?.some(false)), (.value(false), nil), (.unset, nil), (.unset, true), (.value(false), true),
            (.value(true), true),
        ])
    func onDisableQuietOtherwise(old: TweakReading, new: TweakValue?) {
        #expect(!asks(row(.onDisable), from: old, to: new))
    }

    @Test func onDisableAsksWhenTheFileHoldsAnUnreadableValue() {
        #expect(asks(row(.onDisable), from: .unrecognized("yes"), to: nil))
        #expect(asks(row(.onDisable), from: .unrecognized("yes"), to: false))
        #expect(!asks(row(.onDisable), from: .unrecognized("yes"), to: true))
    }

    @Test func onDisableReadsAnUnsetKeyAsTheDefault() {
        let defaultOn = row(.onDisable, defaultValue: true)

        #expect(asks(defaultOn, from: .unset, to: false))
        #expect(!asks(defaultOn, from: .value(true), to: nil))
        #expect(!asks(defaultOn, from: .value(false), to: nil))
        #expect(asks(row(.onDisable, defaultValue: false), from: .value(true), to: nil))
    }

    @Test func onDisableWorksForFlagsAndFixedStrings() {
        let flag = row(.onDisable, valueType: .flag)
        let fixed = row(.onDisable, valueType: .fixedString("disable"))

        #expect(asks(flag, from: .value(true), to: false))
        #expect(asks(flag, from: .value(true), to: nil))
        #expect(!asks(flag, from: .value(false), to: nil))
        #expect(asks(fixed, from: .value(true), to: false))
        #expect(asks(fixed, from: .value(true), to: nil))
        #expect(!asks(fixed, from: .unset, to: false))
    }

    // MARK: onEnable, whenValue, onAnyChange

    @Test func onEnableReadsAnUnsetKeyAsTheDefault() {
        let defaultOn = row(.onEnable, defaultValue: true)

        #expect(!asks(defaultOn, from: .unset, to: true))
        #expect(asks(defaultOn, from: .value(false), to: nil))
        #expect(asks(defaultOn, from: .value(false), to: true))
    }

    @Test func onEnableAsksWhenTheFileHoldsAnUnreadableValue() {
        #expect(asks(row(.onEnable, valueType: .string), from: .unrecognized(5), to: "https://proxy.example"))
    }

    @Test func whenValueReadsAnUnsetKeyAsTheDefault() {
        let tweak = row(.whenValue(false), defaultValue: false)

        #expect(asks(tweak, from: .value(true), to: nil))
        #expect(!asks(tweak, from: .unset, to: false))
        #expect(!asks(tweak, from: .unset, to: nil))
    }

    @Test func onAnyChangeAsksForEveryChange() {
        let tweak = row(.onAnyChange, valueType: .string)

        #expect(asks(tweak, from: .value("a"), to: "b"))
        #expect(asks(tweak, from: .value("a"), to: nil))
        #expect(asks(tweak, from: .unrecognized(1), to: nil))
        #expect(!asks(tweak, from: .value("a"), to: "a"))
        #expect(!asks(tweak, from: .unset, to: nil))
    }

    // MARK: changingFrom:to:

    @Test func confirmationOnEnable() {
        let confirm = Tweak.Confirmation(message: "Sure?", appliesWhen: .onEnable)

        #expect(confirm.isRequired(changingFrom: nil, to: true))
        #expect(confirm.isRequired(changingFrom: false, to: true))
        #expect(confirm.isRequired(changingFrom: nil, to: "https://proxy.example"))
        #expect(!confirm.isRequired(changingFrom: true, to: false))
        #expect(!confirm.isRequired(changingFrom: true, to: true))
        #expect(!confirm.isRequired(changingFrom: "a", to: "b"))
    }

    @Test func confirmationOnAnyChange() {
        let confirm = Tweak.Confirmation(message: "Sure?", appliesWhen: .onAnyChange)

        #expect(confirm.isRequired(changingFrom: "a", to: "b"))
        #expect(confirm.isRequired(changingFrom: "a", to: nil))
        #expect(!confirm.isRequired(changingFrom: "a", to: "a"))
    }

    @Test func confirmationWhenValue() {
        let confirm = Tweak.Confirmation(message: "Sure?", appliesWhen: .whenValue("bypassPermissions"))

        #expect(confirm.isRequired(changingFrom: "default", to: "bypassPermissions"))
        #expect(confirm.isRequired(changingFrom: nil, to: "bypassPermissions"))
        #expect(!confirm.isRequired(changingFrom: "bypassPermissions", to: "bypassPermissions"))
        #expect(!confirm.isRequired(changingFrom: "default", to: "plan"))
    }

    @Test func confirmationOnDisable() {
        let confirm = Tweak.Confirmation(message: "Sure?", appliesWhen: .onDisable)

        #expect(confirm.isRequired(changingFrom: true, to: false))
        #expect(confirm.isRequired(changingFrom: true, to: nil))
        #expect(!confirm.isRequired(changingFrom: nil, to: false))
    }

    @Test func bothFormsAgreeForARowWithoutADefault() {
        let triggers: [Tweak.Confirmation.AppliesWhen] = [.onEnable, .onDisable, .onAnyChange, .whenValue(false), .whenValue("x")]
        let values: [TweakValue?] = [nil, true, false, "x", "", 0, 3]
        for trigger in triggers {
            let tweak = row(trigger)
            let confirm = Tweak.Confirmation(message: "Sure?", appliesWhen: trigger)
            for old in values {
                for new in values {
                    #expect(
                        asks(tweak, from: old.map(TweakReading.value) ?? .unset, to: new) == confirm.isRequired(changingFrom: old, to: new),
                        "\(trigger) \(String(describing: old)) -> \(String(describing: new))")
                }
            }
        }
    }
}
