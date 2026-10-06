/// A decoded JSON value. Object members keep their file order, and numbers keep
/// their exact source text so that `1e3` or `0.10` are never rewritten.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object([Member])

    public struct Member: Sendable, Hashable {
        public let key: String
        public let value: JSONValue

        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }
}

public struct JSONNumber: Sendable, Hashable, CustomStringConvertible {
    public let text: String

    public init?(text: String) {
        let bytes = Array(text.utf8)
        guard JSONGrammar.numberEnd(in: bytes, from: 0) == bytes.count else { return nil }
        self.text = text
    }

    public init(_ value: Int) {
        text = String(value)
    }

    init(validatedText: String) {
        text = validatedText
    }

    public var description: String { text }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(JSONNumber(value))
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(elements.map { Member(key: $0.0, value: $0.1) })
    }
}

enum JSONGrammar {
    static let quote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let comma = UInt8(ascii: ",")
    static let colon = UInt8(ascii: ":")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let slash = UInt8(ascii: "/")
    static let star = UInt8(ascii: "*")
    static let minus = UInt8(ascii: "-")
    static let plus = UInt8(ascii: "+")
    static let dot = UInt8(ascii: ".")
    static let zero = UInt8(ascii: "0")
    static let nine = UInt8(ascii: "9")
    static let lineFeed = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == tab || byte == lineFeed || byte == carriageReturn
    }

    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= zero && byte <= nine
    }

    /// Returns the end offset of a strict JSON number starting at `start`, or nil.
    static func numberEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        if index < bytes.count, bytes[index] == minus { index += 1 }
        guard index < bytes.count, isDigit(bytes[index]) else { return nil }
        if bytes[index] == zero {
            index += 1
            if index < bytes.count, isDigit(bytes[index]) { return nil }
        } else {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == dot {
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { return nil }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == plus || bytes[index] == minus { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { return nil }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        return index
    }
}
