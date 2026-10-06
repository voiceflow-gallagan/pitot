import AppKit
import SwiftUI

/// Turns a key press into a Claude Code key string such as `ctrl+shift+k`.
enum KeyStrokeText {
    /// Key codes of the special keys the docs name, by their key string name.
    static let specialKeys: [UInt16: String] = [
        53: "escape", 36: "enter", 76: "enter", 48: "tab", 49: "space", 126: "up", 125: "down", 123: "left", 124: "right",
        116: "pageup", 121: "pagedown", 115: "home", 119: "end", 51: "backspace", 117: "delete",
    ]

    /// `base` is the character of the key with no modifier applied, so Shift+1 gives `1`, not `!`.
    /// Nil for a key the docs give no name for, such as a function key.
    static func text(keyCode: UInt16, base: String?, control: Bool, shift: Bool, option: Bool, command: Bool) -> String? {
        let key: String
        if let special = specialKeys[keyCode] {
            key = special
        } else if let base, base.count == 1, let character = base.first, !character.isWhitespace,
            character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 })
        {
            key = base.lowercased()
        } else {
            return nil
        }
        let modifiers = [(control, "ctrl"), (shift, "shift"), (option, "alt"), (command, "cmd")].filter(\.0).map(\.1)
        return (modifiers + [key]).joined(separator: "+")
    }

    static func text(for event: NSEvent) -> String? {
        let flags = event.modifierFlags
        return text(
            keyCode: event.keyCode, base: event.characters(byApplyingModifiers: []),
            control: flags.contains(.control), shift: flags.contains(.shift), option: flags.contains(.option), command: flags.contains(.command))
    }
}

/// A button that records the next key press, and a second one within three seconds for a chord.
struct KeyCaptureField: View {
    @Binding var key: String
    @State private var isRecording = false
    @State private var strokes: [String] = []
    @State private var chordTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            TextField("Key", text: $key, prompt: Text("ctrl+k or ctrl+k ctrl+s"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .accessibilityLabel("Key string")
            Button(isRecording ? "Recording…" : "Record", systemImage: isRecording ? "record.circle.fill" : "keyboard") {
                isRecording ? finish() : start()
            }
            .foregroundStyle(isRecording ? .red : .primary)
            .accessibilityLabel(isRecording ? "Stop recording the key" : "Record a key by pressing it")
            .background(KeyRecorder(isRecording: isRecording, onStroke: record))
        }
        .help(isRecording ? "Press the keys. A second key within 3 seconds makes a chord." : "Type a key string, or press Record and then the keys.")
        .onDisappear(perform: finish)
    }

    private func start() {
        strokes = []
        isRecording = true
    }

    private func record(_ stroke: String) {
        strokes.append(stroke)
        key = strokes.joined(separator: " ")
        chordTask?.cancel()
        guard strokes.count < 2 else { return finish() }
        chordTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { finish() }
        }
    }

    private func finish() {
        chordTask?.cancel()
        chordTask = nil
        isRecording = false
    }
}

/// Takes keyboard focus while recording and reports each key press, Command combinations included,
/// before the menu bar can act on them.
private struct KeyRecorder: NSViewRepresentable {
    let isRecording: Bool
    let onStroke: (String) -> Void

    func makeNSView(context: Context) -> RecorderView {
        RecorderView()
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onStroke = onStroke
        view.isRecording = isRecording
        if isRecording, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
    }

    final class RecorderView: NSView {
        var isRecording = false
        var onStroke: ((String) -> Void)?

        override var acceptsFirstResponder: Bool { isRecording }

        override func keyDown(with event: NSEvent) {
            guard isRecording, let text = KeyStrokeText.text(for: event) else { return super.keyDown(with: event) }
            onStroke?(text)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording, window?.firstResponder === self, event.type == .keyDown, let text = KeyStrokeText.text(for: event) else {
                return super.performKeyEquivalent(with: event)
            }
            onStroke?(text)
            return true
        }
    }
}
