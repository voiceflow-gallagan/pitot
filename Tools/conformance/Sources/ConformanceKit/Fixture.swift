import PitotCore
import Foundation

/// Pretty JSON text for fixture files, indented by two spaces, members in their given order.
public enum JSONText {
    public static func render(_ value: JSONValue) -> String {
        var text = ""
        write(value, indent: "", into: &text)
        return text + "\n"
    }

    /// The text a process sees for an env value. Claude Code passes a `null` variable as `null`.
    public static func processText(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .number(let number): number.text
        case .bool(let flag): flag ? "true" : "false"
        case .null: "null"
        case .array, .object: render(value).trimmingCharacters(in: .newlines)
        }
    }

    private static func write(_ value: JSONValue, indent: String, into text: inout String) {
        let inner = indent + "  "
        switch value {
        case .null: text += "null"
        case .bool(let flag): text += flag ? "true" : "false"
        case .number(let number): text += number.text
        case .string(let string): text += quoted(string)
        case .array(let elements) where elements.isEmpty: text += "[]"
        case .object(let members) where members.isEmpty: text += "{}"
        case .array(let elements):
            text += "[\n"
            for (index, element) in elements.enumerated() {
                text += inner
                write(element, indent: inner, into: &text)
                text += index == elements.count - 1 ? "\n" : ",\n"
            }
            text += indent + "]"
        case .object(let members):
            text += "{\n"
            for (index, member) in members.enumerated() {
                text += inner + quoted(member.key) + ": "
                write(member.value, indent: inner, into: &text)
                text += index == members.count - 1 ? "\n" : ",\n"
            }
            text += indent + "}"
        }
    }

    static func quoted(_ string: String) -> String {
        var text = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            case _ where scalar.value < 0x20: text += String(format: "\\u%04x", scalar.value)
            default: text.unicodeScalars.append(scalar)
            }
        }
        return text + "\""
    }
}

public enum Shell {
    /// `text` as one single-quoted `sh` word.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Where one batch lives on disk, the files it writes and the run that reads them.
public struct BatchPlan: Sendable {
    public static let prompt = "Reply with the single word ok"
    public static let timeout: Duration = .seconds(60)
    public static let budgetUSD = "0.25"
    public static let probeScript = """
        #!/bin/sh
        cat > /dev/null
        env | grep '^PITOT_CONF_' | sort > "$1"
        exit 0

        """

    public let batch: Batch
    public let projectDirectory: URL
    public let probeScriptURL: URL

    public init(batch: Batch, workDirectory: URL) {
        self.batch = batch
        projectDirectory = workDirectory.appendingPathComponent(batch.name, isDirectory: true)
        probeScriptURL = workDirectory.appendingPathComponent("probe.sh")
    }

    public var outputDirectory: URL {
        projectDirectory.appendingPathComponent("out", isDirectory: true)
    }

    public var streamURL: URL {
        projectDirectory.appendingPathComponent("stream.jsonl")
    }

    public var stderrURL: URL {
        projectDirectory.appendingPathComponent("stderr.txt")
    }

    public func settingsURL(for layer: LayerID) -> URL {
        let name = layer == .local ? "settings.local.json" : "settings.json"
        return projectDirectory.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent(name)
    }

    public func outputURL(for probe: HookProbe) -> URL {
        outputDirectory.appendingPathComponent("\(probe.marker).env")
    }

    public func command(for probe: HookProbe) -> String {
        "/bin/sh \(Shell.quote(probeScriptURL.path)) \(Shell.quote(outputURL(for: probe).path))"
    }

    public func probe(forCommand command: String) -> HookProbe? {
        batch.probes.first { self.command(for: $0) == command }
    }

    /// The file for `layer`: its settings with a `hooks` key that holds the layer's probes.
    public func content(for layer: LayerID) -> JSONValue {
        let events = batch.probes.filter { $0.layer == layer }.map { probe in
            let handler: JSONValue = ["type": "command", "command": .string(command(for: probe))]
            return JSONValue.Member(key: probe.event, value: [["hooks": [handler]]])
        }
        var members: [JSONValue.Member] = []
        if case .object(let settings)? = batch.settings[layer] {
            members = settings
        }
        if !events.isEmpty {
            members.append(JSONValue.Member(key: "hooks", value: .object(events)))
        }
        return .object(members)
    }

    public func bytes(for layer: LayerID) -> [UInt8] {
        Array(JSONText.render(content(for: layer)).utf8)
    }

    /// The layers as Pitot loads them from these bytes.
    public func layers() -> [SettingsLayer] {
        Catalog.layers.map { LayerLoader.layer(id: $0, url: settingsURL(for: $0), bytes: bytes(for: $0)) }
    }

    public func arguments() -> [String] {
        [
            "-p", Self.prompt,
            "--model", "haiku",
            "--setting-sources", "project,local",
            "--output-format", "stream-json",
            "--verbose",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--max-budget-usd", Self.budgetUSD,
            "--tools", "",
        ]
    }
}
