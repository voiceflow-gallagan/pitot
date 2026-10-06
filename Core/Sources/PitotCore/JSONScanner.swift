/// Errors from `JSONScanner`. Offsets are byte offsets into the scanned input.
///
/// Decisions beyond RFC 8259:
/// - `duplicateKey`: a key that repeats inside one object is rejected. Claude Code
///   keeps the last copy, so editing either copy could silently do nothing.
///   Keys are compared after unescaping, as UTF-16 code units, like JavaScript.
/// - `byteOrderMark`: a leading UTF-8 BOM is rejected. Claude Code settings are
///   plain JSON and `JSON.parse` fails on a BOM.
/// - `emptyInput`: zero bytes, or whitespace only.
public enum JSONScanError: Error, Equatable, Sendable {
    case emptyInput
    case byteOrderMark
    case invalidUTF8(offset: Int)
    case comment(offset: Int)
    case trailingComma(offset: Int)
    case duplicateKey(offset: Int)
    case unterminatedString(offset: Int)
    case invalidEscape(offset: Int)
    case controlCharacterInString(offset: Int)
    case invalidNumber(offset: Int)
    case unexpectedByte(offset: Int)
    case unexpectedEnd
    case trailingContent(offset: Int)
    case nestingTooDeep(offset: Int)
}

/// One value in a scanned document. `range` covers the value's bytes, including
/// quotes for strings and brackets for containers.
public struct JSONNode: Sendable, Equatable {
    public let range: Range<Int>
    public let kind: Kind

    public enum Kind: Sendable, Equatable {
        case object([Member])
        case array([JSONNode])
        case string
        case number
        case bool(Bool)
        case null
    }

    public struct Member: Sendable, Equatable {
        /// The key's bytes, including both quotes.
        public let keyRange: Range<Int>
        /// The unescaped key as UTF-16 code units, the unit JavaScript compares keys by.
        public let keyUnits: [UInt16]
        public let value: JSONNode
        /// Offset of the comma after this member's value, if another member follows.
        public let commaOffset: Int?

        public var key: String {
            String(decoding: keyUnits, as: UTF16.self)
        }

        func hasKey(_ key: String) -> Bool {
            keyUnits.elementsEqual(key.utf16)
        }
    }

    var members: [Member]? {
        if case .object(let members) = kind { return members }
        return nil
    }

    /// Follows object keys from this node.
    func lookup(_ path: [String]) -> JSONDocument.Lookup {
        var node = self
        for (index, key) in path.enumerated() {
            guard let members = node.members else { return .blocked(at: Array(path[..<index])) }
            guard let member = members.first(where: { $0.hasKey(key) }) else { return .absent }
            node = member.value
        }
        return .found(node)
    }
}

public struct JSONDocument: Sendable, Equatable {
    public let bytes: [UInt8]
    public let root: JSONNode

    public enum Lookup: Sendable, Equatable {
        case found(JSONNode)
        case absent
        /// A value on the way to the key is not an object.
        case blocked(at: [String])
    }

    public func lookup(_ path: [String]) -> Lookup {
        root.lookup(path)
    }

    public func node(at path: [String]) -> JSONNode? {
        if case .found(let node) = lookup(path) { return node }
        return nil
    }

    public func value(at path: [String]) -> JSONValue? {
        node(at: path).map(decode)
    }

    public func rawBytes(of node: JSONNode) -> [UInt8] {
        Array(bytes[node.range])
    }

    public func decode(_ node: JSONNode) -> JSONValue {
        switch node.kind {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .number:
            return .number(JSONNumber(validatedText: String(decoding: bytes[node.range], as: UTF8.self)))
        case .string:
            return .string(String(decoding: JSONScanner.unescape(bytes, stringAt: node.range), as: UTF16.self))
        case .array(let elements):
            return .array(elements.map(decode))
        case .object(let members):
            return .object(members.map { JSONValue.Member(key: $0.key, value: decode($0.value)) })
        }
    }
}

/// Strict JSON scanner (RFC 8259) that records the byte range of every key and value.
public enum JSONScanner {
    /// Deeper input is rejected so the recursive parser stays well inside a
    /// 512 KB secondary-thread stack, even in debug builds.
    public static let maximumDepth = 128

    public static func scan(_ bytes: [UInt8]) throws(JSONScanError) -> JSONDocument {
        guard bytes.contains(where: { !JSONGrammar.isWhitespace($0) }) else { throw .emptyInput }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { throw .byteOrderMark }
        if let offset = firstInvalidUTF8Offset(bytes) { throw .invalidUTF8(offset: offset) }
        var parser = Parser(bytes: bytes)
        parser.skipWhitespace()
        let root = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        if parser.index < bytes.count {
            if parser.isAtComment { throw .comment(offset: parser.index) }
            throw .trailingContent(offset: parser.index)
        }
        return JSONDocument(bytes: bytes, root: root)
    }

    /// Unescapes the string whose bytes (including quotes) are at `range`.
    /// Assumes the string was validated by `scan`.
    static func unescape(_ bytes: [UInt8], stringAt range: Range<Int>) -> [UInt16] {
        var units: [UInt16] = []
        units.reserveCapacity(range.count)
        var index = range.lowerBound + 1
        let end = range.upperBound - 1
        while index < end {
            let byte = bytes[index]
            if byte == JSONGrammar.backslash {
                let escape = bytes[index + 1]
                switch escape {
                case UInt8(ascii: "b"): units.append(0x08)
                case UInt8(ascii: "f"): units.append(0x0C)
                case UInt8(ascii: "n"): units.append(0x0A)
                case UInt8(ascii: "r"): units.append(0x0D)
                case UInt8(ascii: "t"): units.append(0x09)
                case UInt8(ascii: "u"):
                    units.append(hexValue(bytes[(index + 2)..<(index + 6)]))
                    index += 4
                default: units.append(UInt16(escape))
                }
                index += 2
            } else if byte < 0x80 {
                units.append(UInt16(byte))
                index += 1
            } else {
                let length = utf8SequenceLength(byte)
                var scalarValue = UInt32(byte) & (0xFF >> (length + 1))
                for offset in 1..<length {
                    scalarValue = (scalarValue << 6) | (UInt32(bytes[index + offset]) & 0x3F)
                }
                if let scalar = Unicode.Scalar(scalarValue) {
                    units.append(contentsOf: scalar.utf16)
                }
                index += length
            }
        }
        return units
    }

    private static func hexValue(_ digits: ArraySlice<UInt8>) -> UInt16 {
        digits.reduce(0) { $0 << 4 | UInt16(hexDigitValue($1) ?? 0) }
    }

    fileprivate static func hexDigitValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    private static func utf8SequenceLength(_ lead: UInt8) -> Int {
        switch lead {
        case 0xC0...0xDF: 2
        case 0xE0...0xEF: 3
        default: 4
        }
    }

    /// Validates UTF-8 per RFC 3629: no overlong forms, no surrogates, nothing above U+10FFFF.
    static func firstInvalidUTF8Offset(_ bytes: [UInt8]) -> Int? {
        var index = 0
        while index < bytes.count {
            let lead = bytes[index]
            if lead < 0x80 {
                index += 1
                continue
            }
            let length: Int
            var secondRange: ClosedRange<UInt8> = 0x80...0xBF
            switch lead {
            case 0xC2...0xDF: length = 2
            case 0xE0:
                length = 3
                secondRange = 0xA0...0xBF
            case 0xE1...0xEC, 0xEE...0xEF: length = 3
            case 0xED:
                length = 3
                secondRange = 0x80...0x9F
            case 0xF0:
                length = 4
                secondRange = 0x90...0xBF
            case 0xF1...0xF3: length = 4
            case 0xF4:
                length = 4
                secondRange = 0x80...0x8F
            default: return index
            }
            guard index + length <= bytes.count, secondRange.contains(bytes[index + 1]) else { return index }
            for offset in 2..<length where !(0x80...0xBF).contains(bytes[index + offset]) {
                return index
            }
            index += length
        }
        return nil
    }
}

private struct Parser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtComment: Bool {
        index + 1 < bytes.count
            && bytes[index] == JSONGrammar.slash
            && (bytes[index + 1] == JSONGrammar.slash || bytes[index + 1] == JSONGrammar.star)
    }

    mutating func skipWhitespace() {
        while index < bytes.count, JSONGrammar.isWhitespace(bytes[index]) { index += 1 }
    }

    func unexpected() -> JSONScanError {
        if index >= bytes.count { return .unexpectedEnd }
        if isAtComment { return .comment(offset: index) }
        return .unexpectedByte(offset: index)
    }

    mutating func parseValue(depth: Int) throws(JSONScanError) -> JSONNode {
        guard index < bytes.count else { throw .unexpectedEnd }
        let start = index
        switch bytes[index] {
        case JSONGrammar.openBrace:
            return try parseObject(depth: depth + 1)
        case JSONGrammar.openBracket:
            return try parseArray(depth: depth + 1)
        case JSONGrammar.quote:
            try scanString()
            return JSONNode(range: start..<index, kind: .string)
        case JSONGrammar.minus, JSONGrammar.zero...JSONGrammar.nine:
            guard let end = JSONGrammar.numberEnd(in: bytes, from: index) else { throw .invalidNumber(offset: start) }
            if end < bytes.count, isNumberContinuation(bytes[end]) { throw .invalidNumber(offset: start) }
            index = end
            return JSONNode(range: start..<index, kind: .number)
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return JSONNode(range: start..<index, kind: .bool(true))
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return JSONNode(range: start..<index, kind: .bool(false))
        case UInt8(ascii: "n"):
            try expectLiteral("null")
            return JSONNode(range: start..<index, kind: .null)
        default:
            throw unexpected()
        }
    }

    private func isNumberContinuation(_ byte: UInt8) -> Bool {
        JSONGrammar.isDigit(byte) || byte == JSONGrammar.dot || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
    }

    private mutating func expectLiteral(_ literal: String) throws(JSONScanError) {
        let expected = literal.utf8
        guard index + expected.count <= bytes.count,
            bytes[index..<(index + expected.count)].elementsEqual(expected)
        else { throw .unexpectedByte(offset: index) }
        index += expected.count
    }

    private mutating func parseObject(depth: Int) throws(JSONScanError) -> JSONNode {
        let start = index
        guard depth <= JSONScanner.maximumDepth else { throw .nestingTooDeep(offset: start) }
        index += 1
        var members: [JSONNode.Member] = []
        var seenKeys = Set<[UInt16]>()
        skipWhitespace()
        if index < bytes.count, bytes[index] == JSONGrammar.closeBrace {
            index += 1
            return JSONNode(range: start..<index, kind: .object(members))
        }
        while true {
            guard index < bytes.count, bytes[index] == JSONGrammar.quote else { throw unexpected() }
            let keyStart = index
            try scanString()
            let keyRange = keyStart..<index
            let keyUnits = JSONScanner.unescape(bytes, stringAt: keyRange)
            guard seenKeys.insert(keyUnits).inserted else { throw .duplicateKey(offset: keyStart) }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == JSONGrammar.colon else { throw unexpected() }
            index += 1
            skipWhitespace()
            let value = try parseValue(depth: depth)
            skipWhitespace()
            guard index < bytes.count else { throw .unexpectedEnd }
            if bytes[index] == JSONGrammar.comma {
                let commaOffset = index
                members.append(JSONNode.Member(keyRange: keyRange, keyUnits: keyUnits, value: value, commaOffset: commaOffset))
                index += 1
                skipWhitespace()
                if index < bytes.count, bytes[index] == JSONGrammar.closeBrace { throw .trailingComma(offset: commaOffset) }
            } else if bytes[index] == JSONGrammar.closeBrace {
                members.append(JSONNode.Member(keyRange: keyRange, keyUnits: keyUnits, value: value, commaOffset: nil))
                index += 1
                return JSONNode(range: start..<index, kind: .object(members))
            } else {
                throw unexpected()
            }
        }
    }

    private mutating func parseArray(depth: Int) throws(JSONScanError) -> JSONNode {
        let start = index
        guard depth <= JSONScanner.maximumDepth else { throw .nestingTooDeep(offset: start) }
        index += 1
        var elements: [JSONNode] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == JSONGrammar.closeBracket {
            index += 1
            return JSONNode(range: start..<index, kind: .array(elements))
        }
        while true {
            elements.append(try parseValue(depth: depth))
            skipWhitespace()
            guard index < bytes.count else { throw .unexpectedEnd }
            if bytes[index] == JSONGrammar.comma {
                let commaOffset = index
                index += 1
                skipWhitespace()
                if index < bytes.count, bytes[index] == JSONGrammar.closeBracket { throw .trailingComma(offset: commaOffset) }
            } else if bytes[index] == JSONGrammar.closeBracket {
                index += 1
                return JSONNode(range: start..<index, kind: .array(elements))
            } else {
                throw unexpected()
            }
        }
    }

    private mutating func scanString() throws(JSONScanError) {
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case JSONGrammar.quote:
                index += 1
                return
            case JSONGrammar.backslash:
                try scanEscape(inStringAt: start)
            case JSONGrammar.lineFeed, JSONGrammar.carriageReturn:
                throw .unterminatedString(offset: start)
            case 0x00..<0x20:
                throw .controlCharacterInString(offset: index)
            default:
                index += 1
            }
        }
        throw .unterminatedString(offset: start)
    }

    private mutating func scanEscape(inStringAt stringStart: Int) throws(JSONScanError) {
        let start = index
        guard index + 1 < bytes.count else { throw .unterminatedString(offset: stringStart) }
        switch bytes[index + 1] {
        case JSONGrammar.quote, JSONGrammar.backslash, JSONGrammar.slash,
            UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
            index += 2
        case UInt8(ascii: "u"):
            guard index + 6 <= bytes.count,
                bytes[(index + 2)..<(index + 6)].allSatisfy({ JSONScanner.hexDigitValue($0) != nil })
            else { throw .invalidEscape(offset: start) }
            index += 6
        default:
            throw .invalidEscape(offset: start)
        }
    }
}
