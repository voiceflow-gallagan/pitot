import Foundation

public struct CheckResult: Sendable {
    public let check: Check
    public let expected: String
    public let actual: String

    public var passed: Bool { expected == actual }
}

public struct CaseResult: Sendable {
    public let conformanceCase: ConformanceCase
    public let checks: [CheckResult]

    public var passed: Bool { checks.allSatisfy(\.passed) }

    public init(_ conformanceCase: ConformanceCase, expectation: Expectation, observation: Observation, mutate: Bool) {
        self.conformanceCase = conformanceCase
        checks = expectation.expected(for: conformanceCase, mutate: mutate).map {
            CheckResult(check: $0.check, expected: $0.text, actual: observation.text(for: $0.check))
        }
    }
}

public enum Report {
    /// One row per check, so a failing case shows which value differs.
    public static func table(_ results: [CaseResult]) -> String {
        let header = ["RESULT", "CASE", "RULES", "CHECK", "EXPECTED (PITOT)", "ACTUAL (CLAUDE CODE)"]
        let rows = results.flatMap { result in
            result.checks.map { check in
                [
                    check.passed ? "PASS" : "FAIL",
                    result.conformanceCase.id,
                    rules(result.conformanceCase),
                    check.check.description,
                    check.expected,
                    check.actual,
                ]
            }
        }
        let failed = results.filter { !$0.passed }.map(\.conformanceCase.id)
        let summary = "\(results.count - failed.count) of \(results.count) cases pass"
            + (failed.isEmpty ? "" : ". Failing: \(failed.joined(separator: ", "))")
        return columns([header] + rows) + "\n" + summary + "\n"
    }

    /// Every case with the values Pitot expects, without running Claude Code.
    public static func caseList(_ plans: [BatchPlan], mutate: Bool) -> String {
        var text = ""
        for plan in plans {
            let expectation = Expectation(plan: plan)
            text += "Batch \(plan.batch.name) (\(plan.projectDirectory.path))\n"
            for conformanceCase in plan.batch.cases {
                text += "  \(conformanceCase.id), rules \(rules(conformanceCase)): \(conformanceCase.summary)\n"
                for (check, expected) in expectation.expected(for: conformanceCase, mutate: mutate) {
                    text += "    \(check) = \(expected)\n"
                }
            }
        }
        return text
    }

    private static func rules(_ conformanceCase: ConformanceCase) -> String {
        conformanceCase.rules.map(String.init).joined(separator: ",")
    }

    private static func columns(_ rows: [[String]]) -> String {
        let widths = rows.reduce(into: [Int](repeating: 0, count: rows.first?.count ?? 0)) { widths, row in
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }
        return rows.map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
