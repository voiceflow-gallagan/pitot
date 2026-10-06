import Foundation
import Testing

@testable import PitotCore

@Suite("Scanner")
struct JSONScannerTests {
    @Test("scanner ranges rebuild the original bytes", arguments: Fixtures.validNames)
    func roundTrip(fixture: String) throws {
        let bytes = try Fixtures.bytes(fixture)
        let document = try JSONScanner.scan(bytes)
        #expect(rebuild(document) == bytes)
    }

    @Test func reportsKeyAndValueRanges() throws {
        let bytes = [UInt8](#"{ "a" : [1, {"b": null}], "c": "x\"y" }"#)
        let document = try JSONScanner.scan(bytes)
        guard case .object(let members) = document.root.kind else {
            Issue.record("root is not an object")
            return
        }
        #expect(members.map(\.key) == ["a", "c"])
        #expect(Array(bytes[members[0].keyRange]).text == #""a""#)
        #expect(Array(bytes[members[0].value.range]).text == #"[1, {"b": null}]"#)
        #expect(Array(bytes[members[1].value.range]).text == #""x\"y""#)
        #expect(members[0].commaOffset == 24)
        #expect(members[1].commaOffset == nil)
        #expect(document.root.range == 0..<bytes.count)
    }

    @Test func keepsNumberTextExactly() throws {
        let bytes = try Fixtures.bytes("numbers")
        let document = try JSONScanner.scan(bytes)
        let texts = ["a", "b", "c", "d", "e"].compactMap { key -> String? in
            guard let node = document.node(at: [key]) else { return nil }
            return Array(bytes[node.range]).text
        }
        #expect(texts == ["1e3", "0.10", "-0", "1E+2", "12345678901234567890"])
        #expect(document.value(at: ["b"]) == .number(try #require(JSONNumber(text: "0.10"))))
    }

    @Test func decodesEscapedAndRawUnicodeToTheSameString() throws {
        let document = try JSONScanner.scan(try Fixtures.bytes("unicode-escapes"))
        #expect(document.value(at: ["escaped"]) == .string("café 😀"))
        #expect(document.value(at: ["raw"]) == .string("café 😀"))
    }

    @Test func keepsIntegerLikeKeyOrder() throws {
        let document = try JSONScanner.scan(try Fixtures.bytes("integer-like-keys"))
        guard case .object(let members) = document.root.kind else {
            Issue.record("root is not an object")
            return
        }
        #expect(members.map(\.key) == ["10", "2", "a"])
    }

    @Test func decodesWholeDocument() throws {
        let document = try JSONScanner.scan([UInt8](#"{"a":[true,false,null],"b":{"c":"\nA"}}"#))
        let expected: JSONValue = ["a": [true, false, nil], "b": ["c": "\nA"]]
        #expect(document.value(at: []) == expected)
    }

    @Test func findsNodesByEscapedKey() throws {
        let document = try JSONScanner.scan([UInt8](#"{"ab": 1}"#))
        #expect(document.node(at: ["ab"]) != nil)
        #expect(document.node(at: ["a"]) == nil)
    }

    @Test func lookupDistinguishesAbsentFromBlocked() throws {
        let document = try JSONScanner.scan([UInt8](#"{"a": "text", "b": {}}"#))
        #expect(document.lookup(["a", "x"]) == .blocked(at: ["a"]))
        #expect(document.lookup(["b", "x"]) == .absent)
        #expect(document.lookup(["missing", "x"]) == .absent)
    }

    // MARK: Errors

    @Test func rejectsCommentFixture() throws {
        #expect(throws: JSONScanError.comment(offset: 4)) {
            try JSONScanner.scan(try Fixtures.bytes("invalid-comment"))
        }
    }

    @Test func rejectsBlockComment() {
        #expect(throws: JSONScanError.comment(offset: 9)) {
            try JSONScanner.scan([UInt8](#"{"a": 1, /* x */ "b": 2}"#))
        }
    }

    @Test func rejectsTrailingCommaFixture() throws {
        #expect(throws: JSONScanError.trailingComma(offset: 19)) {
            try JSONScanner.scan(try Fixtures.bytes("invalid-trailing-comma"))
        }
    }

    @Test func rejectsTrailingCommaInArray() {
        #expect(throws: JSONScanError.trailingComma(offset: 9)) {
            try JSONScanner.scan([UInt8](#"{"a":[1,2,]}"#))
        }
    }

    @Test func rejectsInvalidUTF8Fixture() throws {
        #expect(throws: JSONScanError.invalidUTF8(offset: 6)) {
            try JSONScanner.scan(try Fixtures.bytes("invalid-utf8"))
        }
    }

    @Test(
        "rejects invalid UTF-8 sequences",
        arguments: [
            [0xC0, 0xAF],
            [0xED, 0xA0, 0x80],
            [0xF4, 0x90, 0x80, 0x80],
            [0xE2, 0x82],
        ] as [[UInt8]])
    func rejectsInvalidUTF8(sequence: [UInt8]) {
        let bytes = [UInt8](#"{"a":""#) + sequence + [UInt8](#""}"#)
        #expect(throws: JSONScanError.invalidUTF8(offset: 6)) {
            try JSONScanner.scan(bytes)
        }
    }

    @Test func rejectsEmptyFixture() throws {
        #expect(throws: JSONScanError.emptyInput) {
            try JSONScanner.scan(try Fixtures.bytes("empty"))
        }
    }

    @Test func rejectsWhitespaceOnlyInputAsEmpty() {
        #expect(throws: JSONScanError.emptyInput) {
            try JSONScanner.scan([UInt8](" \n\t\r\n"))
        }
    }

    @Test("rejects a UTF-8 BOM because Claude Code settings are plain JSON")
    func rejectsByteOrderMarkBecauseClaudeCodeSettingsArePlainJSON() {
        #expect(throws: JSONScanError.byteOrderMark) {
            try JSONScanner.scan([0xEF, 0xBB, 0xBF] + [UInt8]("{}"))
        }
    }

    @Test func rejectsDuplicateKeysAtTheSameLevel() {
        #expect(throws: JSONScanError.duplicateKey(offset: 9)) {
            try JSONScanner.scan([UInt8](#"{"a": 1, "a": 2}"#))
        }
    }

    @Test func rejectsDuplicateKeysWrittenWithDifferentEscapes() {
        #expect(throws: JSONScanError.duplicateKey(offset: 9)) {
            try JSONScanner.scan([UInt8](#"{"a": 1, "a": 2}"#))
        }
    }

    @Test func allowsTheSameKeyAtDifferentLevels() throws {
        let document = try JSONScanner.scan([UInt8](#"{"a": {"a": 1}}"#))
        #expect(document.value(at: ["a", "a"]) == 1)
    }

    @Test func treatsCanonicallyEquivalentKeysAsDistinct() throws {
        let document = try JSONScanner.scan([UInt8]("{\"\u{E9}\": 1, \"e\u{301}\": 2}"))
        #expect(document.value(at: ["\u{E9}"]) == 1)
        #expect(document.value(at: ["e\u{301}"]) == 2)
    }

    @Test func rejectsUnterminatedString() {
        #expect(throws: JSONScanError.unterminatedString(offset: 6)) {
            try JSONScanner.scan([UInt8](#"{"a": "abc"#))
        }
        #expect(throws: JSONScanError.unterminatedString(offset: 6)) {
            try JSONScanner.scan([UInt8]("{\"a\": \"abc\n\"}"))
        }
    }

    @Test func rejectsControlCharacterInString() {
        #expect(throws: JSONScanError.controlCharacterInString(offset: 8)) {
            try JSONScanner.scan([UInt8]("{\"a\": \"x\u{1}\"}"))
        }
    }

    @Test func rejectsInvalidEscape() {
        #expect(throws: JSONScanError.invalidEscape(offset: 7)) {
            try JSONScanner.scan([UInt8](#"{"a": "\x"}"#))
        }
        #expect(throws: JSONScanError.invalidEscape(offset: 7)) {
            try JSONScanner.scan([UInt8](#"{"a": "\u12G4"}"#))
        }
    }

    @Test("rejects malformed numbers", arguments: ["01", "1.", ".5", "-", "1e", "1e+", "+1", "0x1"])
    func rejectsMalformedNumber(text: String) {
        #expect(throws: JSONScanError.self) {
            try JSONScanner.scan([UInt8]("{\"a\": \(text)}"))
        }
    }

    @Test func rejectsTrailingGarbage() {
        #expect(throws: JSONScanError.trailingContent(offset: 3)) {
            try JSONScanner.scan([UInt8]("{} x"))
        }
        #expect(throws: JSONScanError.trailingContent(offset: 3)) {
            try JSONScanner.scan([UInt8]("{}\n{}"))
        }
    }

    @Test func rejectsCommentAfterRootValue() {
        #expect(throws: JSONScanError.comment(offset: 3)) {
            try JSONScanner.scan([UInt8]("{}\n// trailing"))
        }
    }

    @Test func rejectsTruncatedInput() {
        #expect(throws: JSONScanError.unexpectedEnd) {
            try JSONScanner.scan([UInt8](#"{"a": 1"#))
        }
    }

    @Test func rejectsBadLiteral() {
        #expect(throws: JSONScanError.unexpectedByte(offset: 6)) {
            try JSONScanner.scan([UInt8](#"{"a": tru}"#))
        }
    }

    @Test func rejectsExcessiveNesting() {
        let bytes = [UInt8](repeating: UInt8(ascii: "["), count: 10_000) + [UInt8](repeating: UInt8(ascii: "]"), count: 10_000)
        #expect(throws: JSONScanError.nestingTooDeep(offset: JSONScanner.maximumDepth)) {
            try JSONScanner.scan(bytes)
        }
    }

    @Test func acceptsSeparatorCharactersInStrings() throws {
        let document = try JSONScanner.scan([UInt8]("{\"a\": \"\u{2028}\u{2029}\"}"))
        #expect(document.value(at: ["a"]) == .string("\u{2028}\u{2029}"))
    }

    @Test func acceptsLoneSurrogateEscapesLikeJavaScript() throws {
        let document = try JSONScanner.scan([UInt8](#"{"a": "\ud800"}"#))
        #expect(document.node(at: ["a"]) != nil)
    }
}

/// Rebuilds a document from scanner ranges only: gaps between ranges must be
/// whitespace or structural punctuation, and leaf ranges supply every other byte.
private func rebuild(_ document: JSONDocument) -> [UInt8] {
    var ranges: [Range<Int>] = []
    collectLeafRanges(document.root, into: &ranges)
    var output: [UInt8] = []
    var cursor = 0
    let allowedGapBytes = Set(" \t\r\n{}[],:".utf8)
    for range in ranges {
        guard range.lowerBound >= cursor else { return [] }
        let gap = document.bytes[cursor..<range.lowerBound]
        guard gap.allSatisfy(allowedGapBytes.contains) else { return [] }
        output += gap
        output += document.bytes[range]
        cursor = range.upperBound
    }
    let tail = document.bytes[cursor...]
    guard tail.allSatisfy(allowedGapBytes.contains) else { return [] }
    return output + tail
}

private func collectLeafRanges(_ node: JSONNode, into ranges: inout [Range<Int>]) {
    switch node.kind {
    case .object(let members):
        for member in members {
            ranges.append(member.keyRange)
            collectLeafRanges(member.value, into: &ranges)
        }
    case .array(let elements):
        for element in elements {
            collectLeafRanges(element, into: &ranges)
        }
    case .string, .number, .bool, .null:
        ranges.append(node.range)
    }
}
