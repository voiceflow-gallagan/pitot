/// Path helpers over decoded settings. Keys compare as UTF-16 code units, like JavaScript and `JSONDocument`.
enum SettingsTree {
    /// What one layer does to the value at a path when it is merged over the layers below it.
    enum Projection: Equatable {
        /// The layer does not reach the path, so the lower value stays.
        case absent
        /// The layer replaces the value at the path, or a value above it, whole. The payload is what
        /// is left at the path afterwards: nil when a non-object above the path cuts it off.
        case reset(JSONValue?)
        /// The layer holds this value at the path, to merge with the lower one.
        case found(JSONValue)
    }

    static func sameKey(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    static func member(_ key: String, in value: JSONValue) -> JSONValue? {
        guard case .object(let members) = value else { return nil }
        return members.first { sameKey($0.key, key) }?.value
    }

    static func value(in root: JSONValue, at path: [String]) -> JSONValue? {
        var node = root
        for key in path {
            guard let child = member(key, in: node) else { return nil }
            node = child
        }
        return node
    }

    static func project(_ root: JSONValue, onto path: [String]) -> Projection {
        var node = root
        for (index, key) in path.enumerated() {
            guard case .object = node else { return .reset(nil) }
            guard let child = member(key, in: node) else { return .absent }
            let rest = Array(path[(index + 1)...])
            if rest.isEmpty { return .found(child) }
            if SettingsMerge.replacesWhole(key: key, parentKey: index > 0 ? path[index - 1] : nil) {
                return .reset(value(in: child, at: rest))
            }
            node = child
        }
        return .found(root)
    }

    /// `root` with `value` at `path`, creating missing objects on the way. Nil when a value on the
    /// way is not an object, which `JSONEdit` refuses as well.
    static func setting(_ value: JSONValue, at path: [String], in root: JSONValue) -> JSONValue? {
        guard let key = path.first else { return value }
        guard case .object(var members) = root else { return nil }
        let rest = Array(path.dropFirst())
        if let index = members.firstIndex(where: { sameKey($0.key, key) }) {
            guard let child = setting(value, at: rest, in: members[index].value) else { return nil }
            members[index] = JSONValue.Member(key: members[index].key, value: child)
        } else {
            guard let child = setting(value, at: rest, in: .object([])) else { return nil }
            members.append(JSONValue.Member(key: key, value: child))
        }
        return .object(members)
    }

    static func removing(_ path: [String], from root: JSONValue) -> JSONValue {
        guard let key = path.first, case .object(var members) = root,
              let index = members.firstIndex(where: { sameKey($0.key, key) })
        else { return root }
        if path.count == 1 {
            members.remove(at: index)
        } else {
            members[index] = JSONValue.Member(key: members[index].key, value: removing(Array(path.dropFirst()), from: members[index].value))
        }
        return .object(members)
    }

    /// The first `null` that is not the value of an `env` variable.
    static func firstNull(in root: JSONValue) -> [String]? {
        guard case .object(let members) = root else { return nil }
        for member in members {
            if isEnv(member), case .object(let variables) = member.value {
                for variable in variables where variable.value != .null {
                    if let path = firstNull(in: variable.value, at: ["env", variable.key]) { return path }
                }
            } else if let path = firstNull(in: member.value, at: [member.key]) {
                return path
            }
        }
        return nil
    }

    /// `root` without any `null` except the values of `env` variables.
    static func removingNulls(from root: JSONValue) -> JSONValue {
        guard case .object(let members) = root else { return root }
        return .object(members.compactMap { member in
            if isEnv(member), case .object(let variables) = member.value {
                let kept = variables.map { $0.value == .null ? $0 : JSONValue.Member(key: $0.key, value: withoutNulls($0.value)) }
                return JSONValue.Member(key: member.key, value: .object(kept))
            }
            return member.value == .null ? nil : JSONValue.Member(key: member.key, value: withoutNulls(member.value))
        })
    }

    private static func isEnv(_ member: JSONValue.Member) -> Bool {
        sameKey(member.key, "env")
    }

    private static func firstNull(in value: JSONValue, at path: [String]) -> [String]? {
        switch value {
        case .null:
            return path
        case .object(let members):
            return members.lazy.compactMap { firstNull(in: $0.value, at: path + [$0.key]) }.first
        case .array(let elements):
            return elements.indices.lazy.compactMap { firstNull(in: elements[$0], at: path + [String($0)]) }.first
        case .bool, .number, .string:
            return nil
        }
    }

    private static func withoutNulls(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let members):
            .object(members.compactMap { $0.value == .null ? nil : JSONValue.Member(key: $0.key, value: withoutNulls($0.value)) })
        case .array(let elements):
            .array(elements.filter { $0 != .null }.map(withoutNulls))
        case .null, .bool, .number, .string:
            value
        }
    }
}

/// Writes a value as compact JSON and records the node ranges, so the result is the
/// `JSONDocument` that `JSONScanner` would give for the same bytes.
enum JSONWriter {
    static func document(_ value: JSONValue) -> JSONDocument {
        var writer = Writer()
        let root = writer.write(value)
        return JSONDocument(bytes: writer.bytes, root: root)
    }

    private struct Writer {
        private static let hexDigits = Array("0123456789abcdef".utf8)

        var bytes: [UInt8] = []

        mutating func write(_ value: JSONValue) -> JSONNode {
            let start = bytes.count
            let kind: JSONNode.Kind
            switch value {
            case .null:
                bytes += Array("null".utf8)
                kind = .null
            case .bool(let flag):
                bytes += Array((flag ? "true" : "false").utf8)
                kind = .bool(flag)
            case .number(let number):
                bytes += Array(number.text.utf8)
                kind = .number
            case .string(let text):
                writeString(text)
                kind = .string
            case .array(let elements):
                bytes.append(JSONGrammar.openBracket)
                var nodes: [JSONNode] = []
                for (index, element) in elements.enumerated() {
                    if index > 0 { bytes.append(JSONGrammar.comma) }
                    nodes.append(write(element))
                }
                bytes.append(JSONGrammar.closeBracket)
                kind = .array(nodes)
            case .object(let members):
                bytes.append(JSONGrammar.openBrace)
                var nodes: [JSONNode.Member] = []
                for (index, member) in members.enumerated() {
                    let keyStart = bytes.count
                    writeString(member.key)
                    let keyRange = keyStart..<bytes.count
                    bytes.append(JSONGrammar.colon)
                    let node = write(member.value)
                    var commaOffset: Int?
                    if index < members.count - 1 {
                        commaOffset = bytes.count
                        bytes.append(JSONGrammar.comma)
                    }
                    nodes.append(JSONNode.Member(keyRange: keyRange, keyUnits: Array(member.key.utf16), value: node, commaOffset: commaOffset))
                }
                bytes.append(JSONGrammar.closeBrace)
                kind = .object(nodes)
            }
            return JSONNode(range: start..<bytes.count, kind: kind)
        }

        private mutating func writeString(_ text: String) {
            bytes.append(JSONGrammar.quote)
            for byte in text.utf8 {
                switch byte {
                case JSONGrammar.quote, JSONGrammar.backslash:
                    bytes += [JSONGrammar.backslash, byte]
                case JSONGrammar.lineFeed:
                    bytes += [JSONGrammar.backslash, UInt8(ascii: "n")]
                case JSONGrammar.carriageReturn:
                    bytes += [JSONGrammar.backslash, UInt8(ascii: "r")]
                case JSONGrammar.tab:
                    bytes += [JSONGrammar.backslash, UInt8(ascii: "t")]
                case 0..<0x20:
                    bytes += [JSONGrammar.backslash, UInt8(ascii: "u"), JSONGrammar.zero, JSONGrammar.zero]
                    bytes += [Self.hexDigits[Int(byte >> 4)], Self.hexDigits[Int(byte & 0xF)]]
                default:
                    bytes.append(byte)
                }
            }
            bytes.append(JSONGrammar.quote)
        }
    }
}
