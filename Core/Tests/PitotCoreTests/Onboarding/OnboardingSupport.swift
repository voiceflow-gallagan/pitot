import Foundation
import Testing

@testable import PitotCore

enum OnboardingSamples {
    static let catalogURL = Fixtures.repoRoot.appendingPathComponent("Catalog/tweaks.json")
    static let onboardingURL = Fixtures.repoRoot.appendingPathComponent("Catalog/onboarding.json")

    static func realCatalog() throws -> Catalog {
        try CatalogLoader.load(data: Data(contentsOf: catalogURL))
    }

    static func realFile(catalog: Catalog) throws -> OnboardingFile {
        try OnboardingLoader.load(data: Data(contentsOf: onboardingURL), catalog: catalog)
    }

    static func document(_ text: String) throws -> JSONDocument {
        try JSONScanner.scan([UInt8](text.utf8))
    }

    static func version(_ text: String) throws -> ClaudeVersion {
        try #require(ClaudeVersion(parsing: text))
    }

    static func tweak(
        _ id: String,
        location: Tweak.Location? = nil,
        valueType: Tweak.ValueType = .bool,
        defaultValue: TweakValue? = nil,
        minVersion: String? = nil,
        requires: [Tweak.Requirement] = [],
        confirm: Tweak.Confirmation? = nil
    ) -> Tweak {
        Tweak(
            id: id,
            location: location ?? .setting(path: [id]),
            valueType: valueType,
            defaultDescription: "Unset",
            defaultValue: defaultValue,
            title: "Title of \(id)",
            description: "Description of \(id)",
            category: "Test",
            minVersion: minVersion,
            requires: requires,
            confirm: confirm,
            docURL: "https://code.claude.com/docs/en/settings-reference#\(id.lowercased())"
        )
    }

    static func catalog(_ tweaks: [Tweak]) -> Catalog {
        Catalog(researchDate: "2026-10-06", claudeCodeVersionChecked: "2.1.291", tweaks: tweaks)
    }

    static func option(
        _ id: String,
        _ profile: OnboardingFile.Profile = .balanced,
        _ sets: [(String, TweakValue?)] = []
    ) -> OnboardingFile.Option {
        OnboardingFile.Option(
            id: id, label: "Label of \(id).", profile: profile,
            sets: sets.map { OnboardingFile.Assignment(tweakId: $0.0, value: $0.1) })
    }

    static func question(_ id: String, _ options: OnboardingFile.Option...) -> OnboardingFile.Question {
        OnboardingFile.Question(id: id, title: "Title of \(id)?", options: options)
    }

    /// `id=value`, with `unset` for a removal, so expected lists read like the file.
    static func describe(_ tweakId: String, _ value: TweakValue?) -> String {
        guard let value else { return "\(tweakId)=unset" }
        switch value {
        case .bool(let flag): return "\(tweakId)=\(flag)"
        case .integer(let number): return "\(tweakId)=\(number)"
        case .string(let text): return "\(tweakId)=\(text)"
        }
    }

    static func lines(_ changes: [Proposal.Change]) -> [String] {
        changes.map { describe($0.tweakId, $0.value) }
    }

    static func lines(_ excluded: [Proposal.Excluded]) -> [String] {
        excluded.map { describe($0.tweakId, $0.value) }
    }
}

/// Every leaf of a JSON value by path. Empty objects and arrays count as leaves.
func jsonLeaves(_ value: JSONValue, at path: [String] = []) -> [[String]: JSONValue] {
    guard case .object(let members) = value, !members.isEmpty else { return [path: value] }
    var leaves: [[String]: JSONValue] = [:]
    for member in members {
        leaves.merge(jsonLeaves(member.value, at: path + [member.key])) { first, _ in first }
    }
    return leaves
}

/// Checks a proposal against the safety rules with its own list of forbidden writes,
/// so a mistake in `OnboardingSafety` cannot hide a mistake in the data.
struct SafetyAudit {
    let catalog: Catalog
    let file: OnboardingFile

    func violations(_ proposal: Proposal, answers: [String: String], document: JSONDocument, checkIdempotent: Bool = true) -> [String] {
        var found: [String] = []
        for change in proposal.all {
            found += lineViolations(change, answers: answers, document: document, proposal: proposal).map { "\(change.tweakId): \($0)" }
        }
        found += documentViolations(proposal, answers: answers, document: document, checkIdempotent: checkIdempotent)
        return found
    }

    private func lineViolations(_ change: Proposal.Change, answers: [String: String], document: JSONDocument, proposal: Proposal) -> [String] {
        var found: [String] = []
        guard let tweak = catalog.tweak(id: change.tweakId) else { return ["not in the catalog"] }
        if ["skipDangerousModePermissionPrompt", "ANTHROPIC_BASE_URL"].contains(change.tweakId) {
            found.append("forbidden tweak")
        }
        if change.operation.path != tweak.location.path {
            found.append("operation path \(change.operation.path) is not the tweak path")
        }
        found += Self.forbiddenWrite(change.operation)
        if case .set(let path, .json(let json), _) = change.operation, path.first == "env" {
            if case .string(let text) = json {
                if tweak.valueType == .flag, text == "0" || text.isEmpty { found.append("env flag written as \"\(text)\"") }
            } else {
                found.append("env value is not a string")
            }
        }
        if let value = change.value, !Validator.check(tweak, value: value).isEmpty {
            found.append("value \(value) fails the validator")
        }
        switch change.source {
        case .answer(let questionId):
            let option = answers[questionId].flatMap { file.question(id: questionId)?.option(id: $0) }
            if option?.sets.contains(OnboardingFile.Assignment(tweakId: change.tweakId, value: change.value)) != true {
                found.append("no answer to \(questionId) sets this value")
            }
        case .dependency(let requiredBy):
            let ids = Set(proposal.all.map(\.tweakId))
            if requiredBy.isEmpty || !requiredBy.allSatisfy(ids.contains) {
                found.append("dependency owners \(requiredBy) are not in the proposal")
            }
        }
        do {
            let after = try JSONScanner.scan(JSONEdit.apply(change.operation, to: document).bytes)
            if tweak.reading(in: after) != expectedReading(tweak, change.value) {
                found.append("operation does not leave the file holding the value")
            }
        } catch {
            found.append("operation fails on the document: \(error)")
        }
        return found
    }

    static func forbiddenWrite(_ operation: JSONEdit.Operation) -> [String] {
        let written: JSONValue? = if case .set(_, .json(let json), _) = operation { json } else { nil }
        switch operation.path {
        case ["permissions", "defaultMode"]:
            return written == .string("bypassPermissions") || written == .string("auto") ? ["sets a permission mode that skips prompts"] : []
        case ["sandbox", "enabled"]:
            return written == .bool(true) ? [] : ["turns the sandbox off or removes it"]
        case ["permissions", "blockReadsOutsideWorkingDirectories"]:
            return written == .bool(true) ? [] : ["lifts the block on reads outside the project"]
        case ["permissions", "disableBypassPermissionsMode"]:
            return written == .string("disable") ? [] : ["allows bypass mode again"]
        case ["skipDangerousModePermissionPrompt"], ["env", "ANTHROPIC_BASE_URL"], ["env", "ANTHROPIC_API_KEY"], ["env", "ANTHROPIC_AUTH_TOKEN"]:
            return ["writes a forbidden key"]
        default:
            return []
        }
    }

    private func expectedReading(_ tweak: Tweak, _ value: TweakValue?) -> TweakReading {
        guard let value, tweak.editValue(for: value) != nil else { return .unset }
        return .value(value)
    }

    private func documentViolations(_ proposal: Proposal, answers: [String: String], document: JSONDocument, checkIdempotent: Bool) -> [String] {
        var bytes = document.bytes
        for operation in proposal.operations {
            do {
                bytes = try JSONEdit.apply(operation, to: bytes).bytes
            } catch {
                return ["applying all operations fails at \(operation.path): \(error)"]
            }
        }
        let after: JSONDocument
        do {
            after = try JSONScanner.scan(bytes)
        } catch {
            return ["result does not scan: \(error)"]
        }

        var found: [String] = []
        let touched = proposal.operations.map(\.path)
        func isTouched(_ path: [String]) -> Bool {
            touched.contains { $0.starts(with: path) || path.starts(with: $0) }
        }
        let before = jsonLeaves(document.value(at: []) ?? .null)
        let afterLeaves = jsonLeaves(after.value(at: []) ?? .null)
        for (path, value) in before where !isTouched(path) && afterLeaves[path] != value {
            found.append("untouched key \(path) changed")
        }
        for path in afterLeaves.keys where !isTouched(path) && before[path] == nil {
            found.append("new key \(path) that no change names")
        }
        for change in proposal.all {
            if let tweak = catalog.tweak(id: change.tweakId), tweak.reading(in: after) != expectedReading(tweak, change.value) {
                found.append("\(change.tweakId) does not hold its value after the whole write")
            }
        }
        if checkIdempotent {
            let again = Onboarding.propose(file, answers: answers, catalog: catalog, document: after, installed: proposal.installed)
            if !again.all.isEmpty {
                found.append("a second run on the written file still proposes \(again.all.map(\.tweakId))")
            }
        }
        return found
    }
}
