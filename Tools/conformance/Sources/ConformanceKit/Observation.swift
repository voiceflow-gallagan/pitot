import PitotCore
import Foundation

/// What one Claude Code run showed: the variables each probe hook saw, the `init` message and the cost.
public struct Observation: Sendable {
    /// The `PITOT_CONF_` variables each probe that ran saw. A probe missing here did not run.
    public var environments: [HookProbe: [String: String]] = [:]
    public var initFields: [InitField: String] = [:]
    public var costUSD: Double?

    public init() {}

    public func text(for check: Check) -> String {
        switch check {
        case .env(let name):
            guard !environments.isEmpty else { return "(no hook ran)" }
            let seen = Set(environments.values.map { $0[name] ?? Outcome.unset })
            guard seen.count == 1, let only = seen.first else { return "(hooks disagree: \(seen.sorted().joined(separator: " | ")))" }
            return only
        case .hook(let probe):
            return environments[probe] == nil ? Outcome.didNotRun : Outcome.ran
        case .initField(let field):
            return initFields[field] ?? "(no init message)"
        }
    }

    /// Reads the probe files and the stream-json output a run left in the batch folder.
    public static func read(_ plan: BatchPlan) -> Observation {
        var observation = Observation()
        for probe in plan.batch.probes {
            guard let data = FileManager.default.contents(atPath: plan.outputURL(for: probe).path) else { continue }
            observation.environments[probe] = environment(fromDump: String(decoding: data, as: UTF8.self))
        }
        if let stream = FileManager.default.contents(atPath: plan.streamURL.path) {
            observation.readStream(Array(stream))
        }
        return observation
    }

    /// Parses `env` output, one `NAME=value` per line.
    public static func environment(fromDump dump: String) -> [String: String] {
        var variables: [String: String] = [:]
        for line in dump.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            variables[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return variables
    }

    /// Takes the setting fields of the `init` message and the cost of the `result` message.
    public mutating func readStream(_ bytes: [UInt8]) {
        for line in bytes.split(separator: UInt8(ascii: "\n")) {
            guard let document = try? JSONScanner.scan(Array(line)) else { continue }
            let message = document.decode(document.root)
            switch (message["type"], message["subtype"]) {
            case (.string("system")?, .string("init")?):
                for field in InitField.allCases {
                    if case .string(let value)? = message[field.rawValue] {
                        initFields[field] = value
                    }
                }
            case (.string("result")?, _):
                if case .number(let cost)? = message["total_cost_usd"] {
                    costUSD = Double(cost.text)
                }
            default:
                continue
            }
        }
    }
}
