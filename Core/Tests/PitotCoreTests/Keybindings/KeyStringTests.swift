import Testing

@testable import PitotCore

@Suite struct KeyStringTests {
    private func normalized(_ text: String) -> String? {
        KeyString(text)?.normalized
    }

    @Test func caseDoesNotMatter() {
        #expect(normalized("ctrl+k") == "ctrl+k")
        #expect(normalized("Ctrl+K") == "ctrl+k")
        #expect(normalized("CTRL+K") == "ctrl+k")
    }

    @Test func modifierAliasesResolve() {
        #expect(normalized("control+k") == "ctrl+k")
        #expect(normalized("opt+p") == "alt+p")
        #expect(normalized("option+p") == "alt+p")
        #expect(normalized("meta+p") == "alt+p")
        #expect(normalized("command+k") == "cmd+k")
        #expect(normalized("super+k") == "cmd+k")
        #expect(normalized("win+k") == "cmd+k")
    }

    @Test func modifierOrderDoesNotMatter() {
        #expect(normalized("shift+ctrl+c") == "ctrl+shift+c")
        #expect(normalized("cmd+alt+ctrl+shift+x") == "ctrl+shift+alt+cmd+x")
    }

    @Test func repeatedModifierCollapses() {
        #expect(normalized("ctrl+control+k") == "ctrl+k")
    }

    @Test func specialKeyAliasesResolve() {
        #expect(normalized("esc") == "escape")
        #expect(normalized("Return") == "enter")
        #expect(normalized("shift+Tab") == "shift+tab")
        #expect(normalized("wheelup") == "wheelup")
    }

    @Test func chordsNormalizeEachStroke() {
        #expect(normalized("Ctrl+K Control+S") == "ctrl+k ctrl+s")
        #expect(KeyString("ctrl+x ctrl+k")?.strokes.count == 2)
    }

    @Test func punctuationKeysAreValid() {
        #expect(normalized("ctrl+[") == "ctrl+[")
        #expect(normalized("ctrl+_") == "ctrl+_")
        #expect(normalized("ctrl+shift+-") == "ctrl+shift+-")
        #expect(normalized("/") == "/")
        #expect(normalized("ctrl++") == "ctrl++")
        #expect(normalized("+") == "+")
    }

    @Test func malformedStringsAreRejected() {
        #expect(KeyString("") == nil)
        #expect(KeyString("ctl+k") == nil)
        #expect(KeyString("ctrl+") == nil)
        #expect(KeyString("+k") == nil)
        #expect(KeyString("ctrl+kk") == nil)
        #expect(KeyString("ctrl+k  ctrl+s") == nil)
        #expect(KeyString(" ctrl+k") == nil)
        #expect(KeyString("ctrl+k ") == nil)
        #expect(KeyString("k+ctrl") == nil)
        #expect(KeyString("ctrl+ k") == nil)
    }
}
