import Foundation

/// A parsed key string such as `ctrl+k` or `ctrl+k ctrl+s`, used to compare keys the way Claude Code does.
/// It never rewrites what the user typed. Use `normalized` only as a lookup key.
public struct KeyString: Sendable, Equatable, Hashable {
    public struct Stroke: Sendable, Equatable, Hashable {
        /// Canonical modifier names, in the order of `KeySyntax.modifiers`, without repeats.
        public let modifiers: [String]
        public let key: String
    }

    public let strokes: [Stroke]

    /// Lowercase canonical form: aliases resolved, modifiers ordered, strokes joined by the chord separator.
    public let normalized: String

    public init?(_ text: String, syntax: KeySyntax = .claudeCode) {
        guard !syntax.chordSeparator.isEmpty else { return nil }
        let rawStrokes = text.components(separatedBy: syntax.chordSeparator)
        var strokes: [Stroke] = []
        for raw in rawStrokes {
            guard let stroke = Self.parseStroke(raw.lowercased(), syntax: syntax) else { return nil }
            strokes.append(stroke)
        }
        guard !strokes.isEmpty else { return nil }
        self.strokes = strokes
        normalized = strokes
            .map { ($0.modifiers + [$0.key]).joined(separator: "+") }
            .joined(separator: syntax.chordSeparator)
    }

    private static func parseStroke(_ text: String, syntax: KeySyntax) -> Stroke? {
        guard !text.isEmpty else { return nil }
        let keyPart: String
        let modifierParts: [String]
        if text == "+" {
            keyPart = "+"
            modifierParts = []
        } else if text.hasSuffix("++") {
            keyPart = "+"
            modifierParts = text.dropLast(2).split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        } else {
            var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            keyPart = parts.removeLast()
            modifierParts = parts
        }

        var present: Set<String> = []
        for part in modifierParts {
            let canonical = syntax.aliases[part] ?? part
            guard syntax.modifiers.contains(canonical) else { return nil }
            present.insert(canonical)
        }
        guard let key = canonicalKey(keyPart, syntax: syntax) else { return nil }
        return Stroke(modifiers: syntax.modifiers.filter(present.contains), key: key)
    }

    private static func canonicalKey(_ text: String, syntax: KeySyntax) -> String? {
        let canonical = syntax.aliases[text] ?? text
        if syntax.specialKeys.contains(canonical) { return canonical }
        guard text.count == 1, let character = text.first, !character.isWhitespace else { return nil }
        return text
    }
}

extension KeySyntax {
    /// The syntax from the Claude Code docs, for callers that have not loaded the catalog.
    public static let claudeCode = KeySyntax(
        modifiers: ["ctrl", "shift", "alt", "cmd"],
        aliases: [
            "control": "ctrl", "opt": "alt", "option": "alt", "meta": "alt",
            "command": "cmd", "super": "cmd", "win": "cmd", "esc": "escape", "return": "enter",
        ],
        specialKeys: [
            "escape", "enter", "tab", "space", "up", "down", "left", "right", "pageup", "pagedown",
            "home", "end", "backspace", "delete", "wheelup", "wheeldown",
        ],
        chordSeparator: " ",
        notes: []
    )
}
