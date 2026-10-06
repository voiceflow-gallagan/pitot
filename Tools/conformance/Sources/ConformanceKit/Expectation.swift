import PitotCore

public enum Outcome {
    public static let unset = "(unset)"
    public static let ran = "ran"
    public static let didNotRun = "did not run"
}

/// What Pitot's `EffectiveSettings` says a session started on the batch's files will show.
public struct Expectation: Sendable {
    public let settings: EffectiveSettings
    /// The probes whose command appears under their own event in the merged `hooks`.
    public let hooks: Set<HookProbe>

    public init(plan: BatchPlan) {
        settings = EffectiveSettings(layers: plan.layers())
        hooks = Self.probes(in: settings.value(at: ["hooks"])?.value, plan: plan)
    }

    public func text(for check: Check) -> String {
        switch check {
        case .env(let name):
            settings.value(at: ["env", name]).map { JSONText.processText($0.value) } ?? Outcome.unset
        case .hook(let probe):
            hooks.contains(probe) ? Outcome.ran : Outcome.didNotRun
        case .initField(let field):
            settings.value(at: field.settingsPath).map { JSONText.processText($0.value) } ?? InitField.unsetText
        }
    }

    /// The expected text of each check. With `mutate`, the mutation target takes the value of the
    /// lowest layer that sets it, as if Pitot had the precedence backwards.
    public func expected(for conformanceCase: ConformanceCase, mutate: Bool) -> [(check: Check, text: String)] {
        conformanceCase.checks.map { check in
            let target = Catalog.mutationTarget
            guard mutate, conformanceCase.id == target.caseID, check == target.check else { return (check, text(for: check)) }
            return (check, flippedText(for: check))
        }
    }

    private func flippedText(for check: Check) -> String {
        guard case .env(let name) = check, let lowest = settings.value(at: ["env", name])?.contributions.last else {
            return "\(text(for: check)) (mutated)"
        }
        return JSONText.processText(lowest.value)
    }

    private static func probes(in hooks: JSONValue?, plan: BatchPlan) -> Set<HookProbe> {
        guard case .object(let events)? = hooks else { return [] }
        var found: Set<HookProbe> = []
        for event in events {
            for group in event.value.elements {
                for handler in group["hooks"]?.elements ?? [] {
                    guard case .string(let command)? = handler["command"],
                          let probe = plan.probe(forCommand: command), probe.event == event.key
                    else { continue }
                    found.insert(probe)
                }
            }
        }
        return found
    }
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    var elements: [JSONValue] {
        guard case .array(let elements) = self else { return [] }
        return elements
    }
}
