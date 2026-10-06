import Foundation

public enum CatalogError: Error, Equatable, Sendable {
    /// The data is not a valid catalog. `path` names the failing field, such as `tweaks[3].valueType`.
    case malformed(path: String, reason: String)
    case lintFailed([LintIssue])
}

public enum CatalogLoader {
    /// Decodes and lints. A catalog with any lint issue is rejected.
    public static func load(data: Data) throws(CatalogError) -> Catalog {
        let catalog = try decode(data: data)
        let issues = CatalogLinter.lint(catalog)
        guard issues.isEmpty else { throw .lintFailed(issues) }
        return catalog
    }

    public static func decode(data: Data) throws(CatalogError) -> Catalog {
        do {
            return try JSONDecoder().decode(Catalog.self, from: data)
        } catch let error as DecodingError {
            throw CatalogError(error)
        } catch {
            throw .malformed(path: "", reason: String(describing: error))
        }
    }
}

extension CatalogError {
    init(_ error: DecodingError) {
        switch error {
        case .typeMismatch(let type, let context):
            self = .malformed(path: Self.render(context.codingPath), reason: "Expected \(type). \(context.debugDescription)")
        case .valueNotFound(let type, let context):
            self = .malformed(path: Self.render(context.codingPath), reason: "Expected \(type), found null. \(context.debugDescription)")
        case .keyNotFound(let key, let context):
            self = .malformed(path: Self.render(context.codingPath + [key]), reason: "Missing key \"\(key.stringValue)\"")
        case .dataCorrupted(let context):
            self = .malformed(path: Self.render(context.codingPath), reason: context.debugDescription)
        @unknown default:
            self = .malformed(path: "", reason: String(describing: error))
        }
    }

    private static func render(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce(into: "") { text, key in
            if let index = key.intValue {
                text += "[\(index)]"
            } else {
                text += text.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
    }
}

public struct LintIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Rule: String, Sendable {
        case invalidVersion
        case duplicateId
        case duplicateLocation
        case emptyLocation
        case invalidDocURL
        case notDocumented
        case enumTooFewOptions
        case enumDuplicateValue
        case integerRangeInverted
        case userOnlyNotMarked
        case flagNotEnv
        case flagDefaultsToZero
        case emptyFixedString
        case invalidDefaultValue
        case userOnlyValuesNotEnum
        case unknownUserOnlyValue
        case suggestionsNotString
        case emptySuggestion
        case duplicateSuggestion
        case emptyConfirmMessage
        case invalidConfirmValue
        case unknownRequirement
        case autoSetWithoutValue
        case disableWithCondition
        case invalidRequirementValue
        case requirementCycle
    }

    public let rule: Rule
    /// Nil for an issue with the catalog header.
    public let tweakId: String?
    public let detail: String

    public init(rule: Rule, tweakId: String?, detail: String) {
        self.rule = rule
        self.tweakId = tweakId
        self.detail = detail
    }

    public var description: String {
        "\(tweakId ?? "catalog"): \(detail)"
    }
}

/// Rules every catalog row must follow before the app may show it.
public enum CatalogLinter {
    public static let docURLPrefix = "https://code.claude.com/docs/"

    /// Keys the settings reference scopes "User or managed" or "User, local, or managed".
    /// A row whose path is one of these, or nested under one, must be `userOnly`.
    public static let userOnlySettingKeys: Set<String> = [
        "askUserQuestionTimeout", "autoContinueAtUsageLimit", "autoMode", "bashEditDiffEnabled", "desktopSessionCleanupPeriodDays",
        "dialogExpiry", "feedbackDrafts", "footerLinksRegexes", "modelPicker", "pluginConfigs", "processWrapper",
        "sandbox.allowAppleEvents", "sandbox.filesystem.disabled", "sandbox.network.strictAllowlist", "skipAutoPermissionPrompt",
        "skipDangerousModePermissionPrompt", "spellcheck", "sshConfigs", "syncClaudeAiPlugins", "syncClaudeAiSkills",
        "useAutoModeDuringPlan", "vimInsertModeRemaps",
    ]

    /// Env vars Claude Code ignores in a project or local `env` block.
    public static let userOnlyEnvNames: Set<String> = [
        "BETA_TRACING_ENDPOINT", "CLAUDE_CODE_ENABLE_TELEMETRY", "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA", "CLAUDE_CODE_PLUGIN_CACHE_DIR",
        "CLAUDE_CODE_PLUGIN_SEED_DIR", "CLAUDE_CODE_PROCESS_WRAPPER", "CLAUDE_CODE_SYNC_PLUGINS", "CLAUDE_CODE_SYNC_SKILLS",
        "CLAUDE_CODE_TMPDIR", "CLAUDE_CONFIG_DIR", "ENABLE_BETA_TRACING_DETAILED", "ENABLE_ENHANCED_TELEMETRY_BETA", "HOME",
        "OTEL_LOG_ASSISTANT_RESPONSES", "OTEL_LOG_RAW_API_BODIES", "OTEL_LOG_TOOL_CONTENT", "OTEL_LOG_TOOL_DETAILS",
        "OTEL_LOG_USER_PROMPTS", "TMPDIR",
    ]

    private static let userOnlyEnvPrefixes = ["OTEL_EXPORTER_OTLP_", "OTEL_EXPORTER_PROMETHEUS_", "XDG_"]

    public static func lint(_ catalog: Catalog) -> [LintIssue] {
        var issues: [LintIssue] = []
        if ClaudeVersion(exactly: catalog.claudeCodeVersionChecked) == nil {
            issues.append(
                LintIssue(rule: .invalidVersion, tweakId: nil, detail: "claudeCodeVersionChecked \"\(catalog.claudeCodeVersionChecked)\" is not a version"))
        }
        issues += duplicateIssues(catalog.tweaks)
        let byId = Dictionary(catalog.tweaks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for tweak in catalog.tweaks {
            issues += rowIssues(tweak)
            issues += requirementIssues(tweak, byId: byId)
        }
        issues += cycleIssues(catalog.tweaks, byId: byId)
        return issues
    }

    public static func isUserOnly(_ location: Tweak.Location) -> Bool {
        switch location {
        case .setting(let path):
            return path.indices.contains { userOnlySettingKeys.contains(path[...$0].joined(separator: ".")) }
        case .env(let name):
            return userOnlyEnvNames.contains(name) || userOnlyEnvPrefixes.contains { name.hasPrefix($0) }
                || (name.hasPrefix("OTEL_") && name.hasSuffix("_EXPORTER"))
        }
    }

    private static func duplicateIssues(_ tweaks: [Tweak]) -> [LintIssue] {
        var issues: [LintIssue] = []
        var ids: Set<String> = []
        var owners: [[String]: String] = [:]
        for tweak in tweaks {
            if !ids.insert(tweak.id).inserted {
                issues.append(LintIssue(rule: .duplicateId, tweakId: tweak.id, detail: "id \"\(tweak.id)\" is used by more than one row"))
            }
            let path = tweak.location.path
            if let owner = owners[path] {
                issues.append(
                    LintIssue(rule: .duplicateLocation, tweakId: tweak.id, detail: "writes \(path.joined(separator: ".")), like row \"\(owner)\""))
            } else {
                owners[path] = tweak.id
            }
        }
        return issues
    }

    private static func rowIssues(_ tweak: Tweak) -> [LintIssue] {
        var issues: [LintIssue] = []
        func add(_ rule: LintIssue.Rule, _ detail: String) {
            issues.append(LintIssue(rule: rule, tweakId: tweak.id, detail: detail))
        }

        let isEmptyLocation =
            switch tweak.location {
            case .setting(let path): path.isEmpty || path.contains(where: \.isEmpty)
            case .env(let name): name.isEmpty
            }
        if isEmptyLocation { add(.emptyLocation, "location has an empty key") }
        if !tweak.docURL.hasPrefix(docURLPrefix) || URL(string: tweak.docURL) == nil {
            add(.invalidDocURL, tweak.docURL.isEmpty ? "docURL is missing" : "docURL \"\(tweak.docURL)\" does not start with \(docURLPrefix)")
        }
        if tweak.status != .documented {
            add(.notDocumented, "status is \(tweak.status.rawValue); only documented rows belong in tweaks.json")
        }
        if isUserOnly(tweak.location), tweak.scope != .userOnly {
            add(.userOnlyNotMarked, "Claude Code honors \(tweak.location.path.joined(separator: ".")) only in user settings; set scope to userOnly")
        }
        if let minVersion = tweak.minVersion, ClaudeVersion(exactly: minVersion) == nil {
            add(.invalidVersion, "minVersion \"\(minVersion)\" is not a version such as 2.1.257")
        }

        switch tweak.valueType {
        case .enumeration(let options):
            if options.count < 2 { add(.enumTooFewOptions, "an enum needs at least 2 options") }
            if Set(options.map(\.value)).count != options.count { add(.enumDuplicateValue, "enum option values repeat") }
        case .integer(let minimum?, let maximum?) where minimum > maximum:
            add(.integerRangeInverted, "min \(minimum) is above max \(maximum)")
        case .flag:
            if tweak.location.envName == nil { add(.flagNotEnv, "a flag must be an env var") }
            if tweak.defaultDescription.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first == "0" {
                add(.flagDefaultsToZero, "a flag is on for any non-empty value, so \"0\" is not an off default")
            }
        case .fixedString(let value):
            if value.allSatisfy(\.isWhitespace) { add(.emptyFixedString, "a fixedString needs a non-empty value") }
        case .bool, .string, .integer, .path:
            break
        }

        issues += valueListIssues(tweak)
        if let defaultValue = tweak.defaultValue, let issue = Validator.check(tweak, value: defaultValue).first {
            add(.invalidDefaultValue, "defaultValue \"\(defaultValue.displayText)\": \(issue.message)")
        }
        if let confirm = tweak.confirm {
            if confirm.message.allSatisfy(\.isWhitespace) { add(.emptyConfirmMessage, "confirm message is empty") }
            if case .whenValue(let value) = confirm.appliesWhen, let issue = Validator.check(tweak, value: value).first {
                add(.invalidConfirmValue, "confirm value \"\(value.displayText)\": \(issue.message)")
            }
        }
        return issues
    }

    private static func valueListIssues(_ tweak: Tweak) -> [LintIssue] {
        var issues: [LintIssue] = []
        func add(_ rule: LintIssue.Rule, _ detail: String) {
            issues.append(LintIssue(rule: rule, tweakId: tweak.id, detail: detail))
        }

        if !tweak.userOnlyValues.isEmpty {
            if case .enumeration(let options) = tweak.valueType {
                let unknown = tweak.userOnlyValues.filter { value in !options.contains { $0.value == value } }
                if !unknown.isEmpty { add(.unknownUserOnlyValue, "userOnlyValues \(unknown) are not enum options") }
            } else {
                add(.userOnlyValuesNotEnum, "userOnlyValues needs an enum row")
            }
        }
        if !tweak.suggestions.isEmpty {
            if tweak.valueType != .string { add(.suggestionsNotString, "suggestions need a string row") }
            if tweak.suggestions.contains(where: { $0.value.allSatisfy(\.isWhitespace) || $0.label.allSatisfy(\.isWhitespace) }) {
                add(.emptySuggestion, "every suggestion needs a value and a label")
            }
            if Set(tweak.suggestions.map(\.value)).count != tweak.suggestions.count {
                add(.duplicateSuggestion, "suggestion values repeat")
            }
        }
        return issues
    }

    private static func requirementIssues(_ tweak: Tweak, byId: [String: Tweak]) -> [LintIssue] {
        var issues: [LintIssue] = []
        func add(_ rule: LintIssue.Rule, _ detail: String) {
            issues.append(LintIssue(rule: rule, tweakId: tweak.id, detail: detail))
        }

        for requirement in tweak.requires {
            if requirement.behavior == .autoSet, requirement.equals == nil {
                add(.autoSetWithoutValue, "autoSet of \"\(requirement.tweakId)\" needs an equals value")
            }
            if requirement.behavior == .disable, requirement.when != nil {
                add(.disableWithCondition, "a disable requirement applies to the whole row, so it cannot have when")
            }
            if let when = requirement.when, let issue = Validator.check(tweak, value: when).first {
                add(.invalidRequirementValue, "when \"\(when.displayText)\": \(issue.message)")
            }
            guard let target = byId[requirement.tweakId] else {
                add(.unknownRequirement, "requires \"\(requirement.tweakId)\", which is not in the catalog")
                continue
            }
            if let equals = requirement.equals, let issue = Validator.check(target, value: equals).first {
                add(.invalidRequirementValue, "equals \"\(equals.displayText)\" for \"\(target.id)\": \(issue.message)")
            }
        }
        return issues
    }

    /// Reports each loop in the requirement graph once, starting from its smallest id.
    private static func cycleIssues(_ tweaks: [Tweak], byId: [String: Tweak]) -> [LintIssue] {
        enum Mark { case visiting, done }
        var marks: [String: Mark] = [:]
        var stack: [String] = []
        var reported: Set<[String]> = []
        var issues: [LintIssue] = []

        func visit(_ id: String) {
            marks[id] = .visiting
            stack.append(id)
            for requirement in byId[id]?.requires ?? [] where byId[requirement.tweakId] != nil {
                switch marks[requirement.tweakId] {
                case .visiting:
                    guard let start = stack.lastIndex(of: requirement.tweakId) else { continue }
                    let loop = Array(stack[start...])
                    guard let smallest = loop.indices.min(by: { loop[$0] < loop[$1] }) else { continue }
                    let normalized = Array(loop[smallest...] + loop[..<smallest])
                    if reported.insert(normalized).inserted {
                        let text = (normalized + [normalized[0]]).joined(separator: " -> ")
                        issues.append(LintIssue(rule: .requirementCycle, tweakId: normalized[0], detail: "requirements form a loop: \(text)"))
                    }
                case .done:
                    continue
                case nil:
                    visit(requirement.tweakId)
                }
            }
            stack.removeLast()
            marks[id] = .done
        }

        for tweak in tweaks where marks[tweak.id] == nil {
            visit(tweak.id)
        }
        return issues
    }
}
