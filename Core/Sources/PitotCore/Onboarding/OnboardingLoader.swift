import Foundation

public enum OnboardingError: Error, Equatable, Sendable {
    /// The data is not a valid onboarding file. `path` names the failing field, such as `questions[2].options[0].sets`.
    case malformed(path: String, reason: String)
    case lintFailed([OnboardingLintIssue])
}

public enum OnboardingLoader {
    /// Decodes and lints against `catalog`. A file with any lint issue is rejected.
    public static func load(data: Data, catalog: Catalog) throws(OnboardingError) -> OnboardingFile {
        let file = try decode(data: data)
        let issues = OnboardingLinter.lint(file, catalog: catalog)
        guard issues.isEmpty else { throw .lintFailed(issues) }
        return file
    }

    public static func decode(data: Data) throws(OnboardingError) -> OnboardingFile {
        do {
            return try JSONDecoder().decode(OnboardingFile.self, from: data)
        } catch let error as DecodingError {
            throw OnboardingError(error)
        } catch {
            throw .malformed(path: "", reason: String(describing: error))
        }
    }
}

extension OnboardingError {
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

public struct OnboardingLintIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Rule: String, Sendable {
        case noQuestions
        case duplicateQuestionId
        case duplicateOptionId
        case optionCount
        case emptyText
        case unknownTweak
        case duplicateTweak
        case invalidValue
        case forbiddenValue
    }

    public let rule: Rule
    public let questionId: String?
    public let optionId: String?
    public let detail: String

    public init(rule: Rule, questionId: String?, optionId: String?, detail: String) {
        self.rule = rule
        self.questionId = questionId
        self.optionId = optionId
        self.detail = detail
    }

    public var description: String {
        let place = [questionId, optionId].compactMap { $0 }.joined(separator: ".")
        return "\(place.isEmpty ? "onboarding" : place): \(detail)"
    }
}

/// Rules the onboarding file must follow before the app may ask its questions.
public enum OnboardingLinter {
    public static let optionRange = 2...4

    public static func lint(_ file: OnboardingFile, catalog: Catalog) -> [OnboardingLintIssue] {
        guard !file.questions.isEmpty else {
            return [OnboardingLintIssue(rule: .noQuestions, questionId: nil, optionId: nil, detail: "the file has no questions")]
        }
        var issues: [OnboardingLintIssue] = []
        var questionIds: Set<String> = []
        for question in file.questions {
            func add(_ rule: OnboardingLintIssue.Rule, _ detail: String) {
                issues.append(OnboardingLintIssue(rule: rule, questionId: question.id, optionId: nil, detail: detail))
            }
            if !questionIds.insert(question.id).inserted { add(.duplicateQuestionId, "question id \"\(question.id)\" is used twice") }
            if isBlank(question.id) || isBlank(question.title) { add(.emptyText, "the question needs an id and a title") }
            if !optionRange.contains(question.options.count) {
                add(.optionCount, "has \(question.options.count) options; a question needs \(optionRange.lowerBound) to \(optionRange.upperBound)")
            }
            var optionIds: Set<String> = []
            for option in question.options {
                if !optionIds.insert(option.id).inserted {
                    issues.append(
                        OnboardingLintIssue(rule: .duplicateOptionId, questionId: question.id, optionId: option.id, detail: "option id is used twice"))
                }
                issues += optionIssues(option, in: question, catalog: catalog)
            }
        }
        return issues
    }

    private static func optionIssues(_ option: OnboardingFile.Option, in question: OnboardingFile.Question, catalog: Catalog) -> [OnboardingLintIssue] {
        var issues: [OnboardingLintIssue] = []
        func add(_ rule: OnboardingLintIssue.Rule, _ detail: String) {
            issues.append(OnboardingLintIssue(rule: rule, questionId: question.id, optionId: option.id, detail: detail))
        }
        if isBlank(option.id) || isBlank(option.label) { add(.emptyText, "the option needs an id and a label") }
        var seen: Set<String> = []
        for assignment in option.sets {
            if !seen.insert(assignment.tweakId).inserted { add(.duplicateTweak, "sets \"\(assignment.tweakId)\" more than once") }
            guard let tweak = catalog.tweak(id: assignment.tweakId) else {
                add(.unknownTweak, "sets \"\(assignment.tweakId)\", which is not in the catalog")
                continue
            }
            if let value = assignment.value, let issue = Validator.check(tweak, value: value).first {
                add(.invalidValue, "\(tweak.id) = \(value.displayText): \(issue.message)")
            }
            if let reason = OnboardingSafety.violation(tweak, value: assignment.value) {
                add(.forbiddenValue, "\(tweak.id): \(reason)")
            }
        }
        return issues
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
