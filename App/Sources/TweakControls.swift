import PitotCore
import SwiftUI

/// The control for one row, chosen by the tweak's value type.
struct TweakControl: View {
    let model: SettingsModel
    let tweak: Tweak
    let state: RowState

    var body: some View {
        Group {
            switch tweak.valueType {
            case .flag, .fixedString:
                OnOffToggle(model: model, tweak: tweak, state: state)
            case .bool:
                BoolPicker(model: model, tweak: tweak, state: state)
            case .enumeration(let options):
                OptionPicker(model: model, tweak: tweak, state: state, options: options)
            case .string, .path:
                TextValueField(model: model, tweak: tweak, state: state)
            case .integer(let minimum, let maximum):
                IntegerField(model: model, tweak: tweak, state: state, range: (minimum, maximum))
            }
        }
        .disabled(!model.canEditScope || state.disabledReason != nil)
    }
}

/// Flags and fixed strings: off removes the key, so unset and off are the same.
private struct OnOffToggle: View {
    let model: SettingsModel
    let tweak: Tweak
    let state: RowState

    var body: some View {
        Toggle(tweak.title, isOn: Binding(get: { state.displayed?.isActive ?? false }, set: { model.requestChange(.bool($0), for: tweak) }))
            .labelsHidden()
            .toggleStyle(.switch)
    }
}

/// A bool setting has three states: unset follows Claude Code's default, which is on for some keys.
private struct BoolPicker: View {
    private enum Choice: Hashable {
        case unset, on, off, other
    }

    let model: SettingsModel
    let tweak: Tweak
    let state: RowState

    var body: some View {
        Picker(tweak.title, selection: Binding(get: { choice }, set: select)) {
            Text("Default").tag(Choice.unset)
            Text("On").tag(Choice.on)
            Text("Off").tag(Choice.off)
            if choice == .other {
                Text("Other").tag(Choice.other)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var choice: Choice {
        switch state.displayed {
        case .bool(true)?: .on
        case .bool(false)?: .off
        case nil: state.showsUnrecognized ? .other : .unset
        default: .other
        }
    }

    private func select(_ choice: Choice) {
        switch choice {
        case .unset: model.requestChange(nil, for: tweak)
        case .on: model.requestChange(.bool(true), for: tweak)
        case .off: model.requestChange(.bool(false), for: tweak)
        case .other: break
        }
    }
}

private struct OptionPicker: View {
    private enum Choice: Hashable {
        case unset
        case option(String)
        case other
    }

    let model: SettingsModel
    let tweak: Tweak
    let state: RowState
    let options: [Tweak.Option]

    var body: some View {
        Picker(tweak.title, selection: Binding(get: { choice }, set: select)) {
            Text("Default").tag(Choice.unset)
            ForEach(options, id: \.value) { option in
                Text(label(for: option)).tag(Choice.option(option.value))
            }
            if choice == .other {
                Text("Unrecognized").tag(Choice.other)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Values the selected layer cannot hold say so; picking one is refused with the reason.
    private func label(for option: Tweak.Option) -> String {
        guard model.scope != .user, tweak.userOnlyValues.contains(option.value) else { return option.label }
        return "\(option.label) (user settings only)"
    }

    private var choice: Choice {
        switch state.displayed {
        case .string(let text)? where options.contains(where: { $0.value == text }): .option(text)
        case nil where !state.showsUnrecognized: .unset
        default: .other
        }
    }

    private func select(_ choice: Choice) {
        switch choice {
        case .unset: model.requestChange(nil, for: tweak)
        case .option(let value): model.requestChange(.string(value), for: tweak)
        case .other: break
        }
    }
}

/// Typing edits a draft. The draft becomes a pending change on Return or when the field loses focus,
/// so a confirmation is asked once per edit, not once per keystroke.
private struct TextValueField: View {
    let model: SettingsModel
    let tweak: Tweak
    let state: RowState
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                TextField(tweak.title, text: $draft, prompt: Text("Not set"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: tweak.suggestions.isEmpty ? 220 : 194)
                    .focused($isFocused)
                    .onSubmit { model.commitText(draft, for: tweak) }
                if !tweak.suggestions.isEmpty {
                    SuggestionMenu(tweak: tweak) { value in
                        draft = value
                        model.commitText(value, for: tweak)
                    }
                }
            }
            if let message = model.validationMessage(for: tweak, text: draft) {
                Text(message).font(.caption).foregroundStyle(.red).frame(width: 220, alignment: .trailing)
            }
        }
        .onAppear { draft = shownText }
        .onChange(of: shownText) { _, text in
            if !isFocused { draft = text }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { model.commitText(draft, for: tweak) }
        }
        .onChange(of: model.confirmRequest == nil) { _, closed in
            if closed, !isFocused { draft = shownText }
        }
    }

    private var shownText: String {
        if case .string(let text)? = state.displayed { return text }
        return ""
    }
}

/// The named choices of a free-text row, such as model aliases. Typing any other value still works.
private struct SuggestionMenu: View {
    let tweak: Tweak
    let choose: (String) -> Void

    var body: some View {
        Menu {
            ForEach(tweak.suggestions, id: \.value) { suggestion in
                Button(suggestion.label == suggestion.value ? suggestion.value : "\(suggestion.label) · \(suggestion.value)") {
                    choose(suggestion.value)
                }
                .help(suggestion.note ?? "")
            }
        } label: {
            Image(systemName: "chevron.down.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a named value")
        .accessibilityLabel("Choose a suggested value for \(tweak.title)")
    }
}

private struct IntegerField: View {
    let model: SettingsModel
    let tweak: Tweak
    let state: RowState
    let range: (minimum: Int?, maximum: Int?)
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                TextField(tweak.title, text: $draft, prompt: Text("Not set"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .focused($isFocused)
                    .onSubmit { model.commitInteger(draft, for: tweak) }
                Stepper("Change \(tweak.title)", onIncrement: { step(by: 1) }, onDecrement: { step(by: -1) })
                    .labelsHidden()
            }
            if let message = model.validationMessage(for: tweak, text: draft) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { draft = shownText }
        .onChange(of: shownText) { _, text in
            if !isFocused { draft = text }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { model.commitInteger(draft, for: tweak) }
        }
    }

    private var shownText: String {
        if case .integer(let number)? = state.displayed { return String(number) }
        return ""
    }

    private func step(by delta: Int) {
        let base: Int
        if case .integer(let number)? = state.displayed {
            let (sum, overflow) = number.addingReportingOverflow(delta)
            base = overflow ? number : sum
        } else {
            base = range.minimum ?? 0
        }
        let clamped = min(max(base, range.minimum ?? .min), range.maximum ?? .max)
        model.requestChange(.integer(clamped), for: tweak)
    }
}
