import PitotCore

/// A hook in one settings file that writes the `PITOT_CONF_` variables it sees to its own file.
/// The file existing after a run means the hook ran, so its settings file was loaded.
public struct HookProbe: Sendable, Hashable, CustomStringConvertible {
    public let layer: LayerID
    public let event: String

    public init(_ layer: LayerID, _ event: String) {
        self.layer = layer
        self.event = event
    }

    public var marker: String { "\(layer.rawValue)-\(event)" }
    public var description: String { marker }
}

/// A field of the stream-json `init` message that reports a setting in effect.
public enum InitField: String, Sendable, Hashable, CaseIterable {
    case outputStyle = "output_style"
    case permissionMode

    /// The field's value when no layer sets the key, as seen in the test runs behind `Core/MERGE-RULES.md`.
    public static let unsetText = "default"

    public var settingsPath: [String] {
        switch self {
        case .outputStyle: ["outputStyle"]
        case .permissionMode: ["permissions", "defaultMode"]
        }
    }
}

/// One value that can be seen from outside a running Claude Code.
public enum Check: Sendable, Hashable, CustomStringConvertible {
    /// The variable as every hook process sees it.
    case env(String)
    /// Whether the hook ran.
    case hook(HookProbe)
    case initField(InitField)

    public var description: String {
        switch self {
        case .env(let name): "env \(name)"
        case .hook(let probe): "hook \(probe.marker)"
        case .initField(let field): "init \(field.rawValue)"
        }
    }
}

public struct ConformanceCase: Sendable {
    public let id: String
    /// Rule numbers in `Core/MERGE-RULES.md`.
    public let rules: [Int]
    public let summary: String
    public let checks: [Check]
}

/// One project folder and one Claude Code run. Its cases share the two settings files, so every
/// case in a batch must read variables and hooks that the other cases do not change.
public struct Batch: Sendable {
    public let name: String
    /// Each layer's file without its hooks. The probes are added when the file is written.
    public let settings: [LayerID: JSONValue]
    public let probes: [HookProbe]
    public let cases: [ConformanceCase]
}

public enum Catalog {
    public static let maximumRuns = 6
    public static let layers: [LayerID] = [.project, .local]

    /// The check whose expected value `CONFORMANCE_MUTATE=1` flips, to prove a mismatch fails.
    public static let mutationTarget = (caseID: "env-local-wins", check: Check.env(variable(1)))

    public static func variable(_ number: Int) -> String {
        "PITOT_CONF_\(number)"
    }

    public static let batches: [Batch] = [merge, emptyEnv, typedNull, objectNull]

    public static var cases: [ConformanceCase] {
        batches.flatMap(\.cases)
    }

    private static let projectStart = HookProbe(.project, "SessionStart")
    private static let projectPrompt = HookProbe(.project, "UserPromptSubmit")
    private static let localStart = HookProbe(.local, "SessionStart")

    private static let merge = Batch(
        name: "merge",
        settings: [
            .project: [
                "outputStyle": "Explanatory",
                "permissions": ["defaultMode": "acceptEdits"],
                "env": [variable(1): "project", variable(2): "project", variable(4): "project"],
            ],
            .local: [
                "outputStyle": "Learning",
                "permissions": ["ask": ["Bash(pitot-conformance-probe)"]],
                "env": [variable(1): "local", variable(3): "local", variable(4): nil],
            ],
        ],
        probes: [projectStart, projectPrompt, localStart],
        cases: [
            ConformanceCase(
                id: "env-local-wins",
                rules: [2],
                summary: "Same env variable in project and local: local wins",
                checks: [.env(variable(1))]
            ),
            ConformanceCase(
                id: "env-per-variable",
                rules: [3, 6],
                summary: "Different env variables in project and local: both apply",
                checks: [.env(variable(2)), .env(variable(3))]
            ),
            ConformanceCase(
                id: "env-null-text",
                rules: [7],
                summary: "Env variable set to null in local: the file loads and processes see the text null",
                checks: [.env(variable(4)), .hook(localStart)]
            ),
            ConformanceCase(
                id: "scalar-local-wins",
                rules: [1],
                summary: "Same top-level value in project and local: local wins",
                checks: [.initField(.outputStyle)]
            ),
            ConformanceCase(
                id: "nested-object-merge",
                rules: [11],
                summary: "permissions in both files: local without defaultMode keeps the project defaultMode",
                checks: [.initField(.permissionMode)]
            ),
            ConformanceCase(
                id: "hooks-join",
                rules: [12],
                summary: "SessionStart hooks in project and local: both run",
                checks: [.hook(projectStart), .hook(localStart)]
            ),
            ConformanceCase(
                id: "hooks-per-event",
                rules: [13],
                summary: "UserPromptSubmit only in project: it runs although local sets other hook events",
                checks: [.hook(projectPrompt)]
            ),
        ]
    )

    private static let emptyEnv = Batch(
        name: "empty-env",
        settings: [
            .project: ["env": [variable(5): "project"]],
            .local: ["env": [:]],
        ],
        probes: [projectStart, localStart],
        cases: [
            ConformanceCase(
                id: "env-empty-object",
                rules: [5],
                summary: "env: {} in local erases nothing, and the local file loads",
                checks: [.env(variable(5)), .hook(localStart)]
            ),
        ]
    )

    private static let typedNull = Batch(
        name: "typed-null",
        settings: [
            .project: ["outputStyle": "Explanatory", "env": [variable(6): "project"]],
            .local: ["outputStyle": nil, "env": [variable(6): "local", variable(7): "local"]],
        ],
        probes: [projectStart, localStart],
        cases: [
            ConformanceCase(
                id: "typed-null-drops-file",
                rules: [8, 10],
                summary: "outputStyle: null in local: the whole local file is ignored",
                checks: [.env(variable(6)), .env(variable(7)), .hook(localStart), .initField(.outputStyle)]
            ),
        ]
    )

    private static let objectNull = Batch(
        name: "object-null",
        settings: [
            .project: ["permissions": nil, "outputStyle": "Explanatory", "env": [variable(8): "project"]],
            .local: ["env": [variable(9): "local"]],
        ],
        probes: [projectStart, localStart],
        cases: [
            ConformanceCase(
                id: "object-null-drops-file",
                rules: [9, 10],
                summary: "permissions: null in project: the whole project file is ignored, local still applies",
                checks: [.env(variable(8)), .env(variable(9)), .hook(projectStart), .initField(.outputStyle)]
            ),
        ]
    )
}
