/// A value the user wants for one tweak. A nil value removes the key.
public struct ProposedChange: Sendable, Equatable {
    public let tweakId: String
    public let value: TweakValue?

    public init(tweakId: String, value: TweakValue?) {
        self.tweakId = tweakId
        self.value = value
    }
}

public struct Resolution: Sendable, Equatable {
    public struct AutoSet: Sendable, Equatable {
        public let tweakId: String
        public let value: TweakValue
        public let reason: String

        public init(tweakId: String, value: TweakValue, reason: String) {
            self.tweakId = tweakId
            self.value = value
            self.reason = reason
        }
    }

    /// A tweak already in the file that the change leaves without what it needs.
    public struct UnsetSuggestion: Sendable, Equatable {
        public let tweakId: String
        public let reason: String

        public init(tweakId: String, reason: String) {
            self.tweakId = tweakId
            self.reason = reason
        }
    }

    /// A changed tweak whose new value will not be the one in effect after the write.
    public struct Shadowed: Sendable, Equatable {
        public let tweakId: String
        /// The layer whose value stays in effect. Nil when no layer supplies one, because Claude Code ignores the written value.
        public let by: LayerID?
        public let effective: TweakReading

        public init(tweakId: String, by: LayerID?, effective: TweakReading) {
            self.tweakId = tweakId
            self.by = by
            self.effective = effective
        }
    }

    public struct Refusal: Sendable, Equatable {
        public let tweakId: String
        public let reason: String

        public init(tweakId: String, reason: String) {
            self.tweakId = tweakId
            self.reason = reason
        }
    }

    /// Other tweaks to write with the change, in the order they were found. A layered resolution
    /// writes them to the same target layer.
    public var autoSet: [AutoSet] = []
    /// Every tweak whose control is disabled once the change applies, with the reason.
    public var disabled: [String: String] = [:]
    /// Changed tweaks that must not be written, with the reason: a disabled row given an active value,
    /// a row the organization sets, or a row or value the target layer cannot hold.
    public var blocked: [String: String] = [:]
    public var unsetSuggestions: [UnsetSuggestion] = []
    public var warnings: [String] = []
    /// Layered only: written tweaks that another layer keeps from taking effect. A removal is listed
    /// only when a higher layer still sets the tweak; falling back to a lower layer is expected.
    public var shadowed: [Shadowed] = []
    /// Layered only: changed tweaks the managed settings lock. Each is also in `blocked`.
    public var lockedByManaged: [String] = []
    /// Layered only: changes the target layer cannot hold. Each is also in `blocked`.
    public var refusedInLayer: [Refusal] = []
}

/// Applies the catalog's `requires` rules and env overrides to a proposed change.
///
/// Each tweak is auto-set at most once per resolution, and chains stop after
/// `maximumChainDepth` steps, so a loop in bad data cannot hang the app.
///
/// The document form treats one file as all the settings. The layered form writes every change and
/// auto-set to `target` and evaluates requirements, disabled rows and env overrides on the values in
/// effect across all layers after that write.
public enum Dependencies {
    public static let maximumChainDepth = 8

    public static func resolve(_ catalog: Catalog, document: JSONDocument, change: ProposedChange) -> Resolution {
        resolve(catalog, document: document, changes: [change])
    }

    /// Resolves several changes made together, such as onboarding answers. A later change to the same tweak wins.
    public static func resolve(_ catalog: Catalog, document: JSONDocument, changes: [ProposedChange]) -> Resolution {
        var resolver = Resolver(catalog: catalog, context: .document(document))
        return resolver.run(changes)
    }

    /// The disabled controls for the file as it is, with the reason for each.
    public static func disabledReasons(_ catalog: Catalog, document: JSONDocument) -> [String: String] {
        Resolver(catalog: catalog, context: .document(document)).disabledReasons()
    }

    public static func resolve(_ catalog: Catalog, effective: EffectiveSettings, change: ProposedChange, target: LayerID) -> Resolution {
        resolve(catalog, effective: effective, changes: [change], target: target)
    }

    public static func resolve(_ catalog: Catalog, effective: EffectiveSettings, changes: [ProposedChange], target: LayerID) -> Resolution {
        var resolver = Resolver(catalog: catalog, context: .layered(effective, target: target))
        return resolver.run(changes)
    }

    /// The disabled controls for the values in effect across all layers.
    public static func disabledReasons(_ catalog: Catalog, effective: EffectiveSettings) -> [String: String] {
        Resolver(catalog: catalog, context: .layered(effective, target: .user)).disabledReasons()
    }
}

extension Tweak.Requirement {
    /// Whether the owning tweak's value switches this requirement on.
    func applies(toOwner reading: TweakReading) -> Bool {
        guard let when else { return reading.isActive }
        return reading == .value(when)
    }

    func isSatisfied(by reading: TweakReading) -> Bool {
        guard let equals else { return reading.isActive }
        return reading == .value(equals)
    }

    var expectation: String {
        equals.map { "set to \($0.displayText)" } ?? "set"
    }
}

private enum Context {
    case document(JSONDocument)
    case layered(EffectiveSettings, target: LayerID)
}

private struct Resolver {
    let context: Context
    let tweaks: [Tweak]
    let byId: [String: Tweak]
    let envOwners: [String: String]
    var state: [String: TweakReading]
    var changed: [String] = []
    /// The value each changed tweak was given, nil for a removal.
    var intended: [String: TweakValue?] = [:]
    /// Layered only: what is in effect for each changed tweak after the write.
    var afterWrite: [String: EffectiveValue?] = [:]
    var result = Resolution()

    init(catalog: Catalog, context: Context) {
        self.context = context
        var seen: Set<String> = []
        tweaks = catalog.tweaks.filter { seen.insert($0.id).inserted }
        byId = Dictionary(tweaks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        envOwners = Dictionary(tweaks.compactMap { tweak in tweak.location.envName.map { ($0, tweak.id) } }, uniquingKeysWith: { first, _ in first })
        state = byId.mapValues { tweak in
            switch context {
            case .document(let document): tweak.reading(in: document)
            case .layered(let effective, _): tweak.reading(in: effective).reading
            }
        }
    }

    mutating func run(_ changes: [ProposedChange]) -> Resolution {
        var latest: [ProposedChange] = []
        for change in changes {
            guard byId[change.tweakId] != nil else {
                result.blocked[change.tweakId] = "This setting is not in the catalog."
                continue
            }
            if let index = latest.firstIndex(where: { $0.tweakId == change.tweakId }) {
                latest[index] = change
            } else {
                latest.append(change)
            }
        }
        var explicit: [String] = []
        for change in latest {
            guard let tweak = byId[change.tweakId], write(tweak, change.value) else { continue }
            explicit.append(change.tweakId)
        }
        changed = explicit
        propagate(from: explicit)

        result.disabled = disabledReasons()
        for id in explicit where reading(id).isActive {
            if let reason = result.disabled[id] { result.blocked[id] = reason }
        }
        for autoSet in result.autoSet {
            if let reason = result.disabled[autoSet.tweakId] {
                result.warnings.append("\(title(autoSet.tweakId)) would be set automatically, but it is disabled: \(reason)")
            }
        }
        checkShadowing()
        checkDependents()
        checkEnvOverrides()
        return result
    }

    func disabledReasons() -> [String: String] {
        var reasons: [String: String] = [:]
        for tweak in tweaks {
            if let unmet = tweak.requires.first(where: { $0.behavior == .disable && !$0.isSatisfied(by: reading($0.tweakId)) }) {
                reasons[tweak.id] = unmet.reason
            }
        }
        return reasons
    }

    private func reading(_ id: String) -> TweakReading {
        state[id] ?? .unset
    }

    private func title(_ id: String) -> String {
        byId[id]?.title ?? id
    }

    /// Applies one change to `state`, or records why the target layer cannot take it and returns false.
    private mutating func write(_ tweak: Tweak, _ value: TweakValue?) -> Bool {
        switch context {
        case .document:
            state[tweak.id] = value.map(TweakReading.value) ?? .unset
        case .layered(let effective, let target):
            guard let kind = target.writableKind else {
                refuse(tweak.id, "Pitot cannot write managed settings.")
                return false
            }
            if effective.lockedByManaged(tweak) {
                if !result.lockedByManaged.contains(tweak.id) { result.lockedByManaged.append(tweak.id) }
                result.blocked[tweak.id] = "Set by your organization."
                return false
            }
            if case .refused(let reason) = tweak.canWrite(in: kind, value: value) {
                refuse(tweak.id, reason)
                return false
            }
            let after = effective.effective(for: tweak, writing: value, to: kind)
            afterWrite[tweak.id] = .some(after)
            state[tweak.id] = tweak.reading(from: after?.value)
        }
        intended[tweak.id] = .some(value)
        return true
    }

    private mutating func refuse(_ id: String, _ reason: String) {
        if !result.refusedInLayer.contains(where: { $0.tweakId == id }) {
            result.refusedInLayer.append(Resolution.Refusal(tweakId: id, reason: reason))
        }
        result.blocked[id] = reason
    }

    /// Follows autoSet requirements breadth first. A tweak that is already part of the change is
    /// never overwritten; `checkDependents` reports the conflict instead.
    private mutating func propagate(from explicit: [String]) {
        var queue = explicit.map { (id: $0, depth: 0) }
        var assigned = Set(explicit)
        var next = 0
        while next < queue.count {
            let (id, depth) = queue[next]
            next += 1
            guard let tweak = byId[id] else { continue }
            for requirement in tweak.requires where requirement.behavior == .autoSet && requirement.applies(toOwner: reading(id)) {
                guard let target = requirement.equals, let targetTweak = byId[requirement.tweakId] else { continue }
                guard reading(requirement.tweakId) != .value(target), !assigned.contains(requirement.tweakId) else { continue }
                guard depth < Dependencies.maximumChainDepth else {
                    result.warnings.append(
                        "Stopped following requirements after \(Dependencies.maximumChainDepth) steps at \(title(id)). The catalog may contain a loop.")
                    continue
                }
                assigned.insert(requirement.tweakId)
                guard write(targetTweak, target) else { continue }
                changed.append(requirement.tweakId)
                result.autoSet.append(Resolution.AutoSet(tweakId: requirement.tweakId, value: target, reason: requirement.reason))
                queue.append((requirement.tweakId, depth + 1))
            }
        }
    }

    /// Layered only: lists written tweaks whose value will not be the one in effect.
    private mutating func checkShadowing() {
        guard case .layered(_, let target) = context else { return }
        for id in changed {
            guard let tweak = byId[id], let value = intended[id], let after = afterWrite[id] else { continue }
            let writesKey = value.flatMap(tweak.editValue(for:)) != nil
            let isShadowed: Bool
            if writesKey, let value {
                isShadowed = reading(id) != .value(value)
            } else {
                isShadowed = after.map { $0.winner > target } ?? false
            }
            if isShadowed {
                result.shadowed.append(Resolution.Shadowed(tweakId: id, by: after?.winner, effective: reading(id)))
            }
        }
    }

    /// Finds tweaks whose requirement on a changed tweak is no longer met.
    private mutating func checkDependents() {
        let changedSet = Set(changed)
        for owner in tweaks {
            for requirement in owner.requires where changedSet.contains(requirement.tweakId) {
                guard !requirement.isSatisfied(by: reading(requirement.tweakId)) else { continue }
                let needs = "\(owner.title) needs \(title(requirement.tweakId)) \(requirement.expectation): \(requirement.reason)"
                if !changedSet.contains(owner.id) {
                    guard requirement.behavior == .disable || requirement.applies(toOwner: reading(owner.id)), reading(owner.id).isActive else { continue }
                    result.warnings.append("\(needs) Clear \(owner.title) or keep \(title(requirement.tweakId)).")
                    result.unsetSuggestions.append(Resolution.UnsetSuggestion(tweakId: owner.id, reason: requirement.reason))
                } else if requirement.behavior == .autoSet, requirement.applies(toOwner: reading(owner.id)) {
                    result.warnings.append("These changes conflict. \(needs)")
                }
            }
        }
    }

    /// Warns when an env var beats a tweak, and either one is part of the change.
    private mutating func checkEnvOverrides() {
        let changedSet = Set(changed)
        for tweak in tweaks where !tweak.overriddenBy.isEmpty && reading(tweak.id) != .unset {
            for envOverride in tweak.overriddenBy {
                let envChanged = envOwners[envOverride.envName].map(changedSet.contains) ?? false
                guard changedSet.contains(tweak.id) || envChanged, let env = activeEnvValue(envOverride) else { continue }
                let place = env.layer.map { "the \(Self.settingsName($0))" } ?? "this file"
                result.warnings.append("\(tweak.title) has no effect while \(envOverride.envName)=\(env.value) is set in the env block of \(place).")
            }
        }
    }

    private func activeEnvValue(_ envOverride: Tweak.EnvOverride) -> (value: String, layer: LayerID?)? {
        guard let env = envValue(envOverride.envName), !env.value.isEmpty else { return nil }
        guard let expected = envOverride.whenValue else { return env }
        if let actual = EnvBoolean.parse(env.value), let wanted = EnvBoolean.parse(expected) {
            return actual == wanted ? env : nil
        }
        return env.value == expected ? env : nil
    }

    /// The env value after the change, and the layer that supplies it in a layered resolution.
    /// A changed catalog env tweak gives its new value; any other variable reads the settings as they are.
    private func envValue(_ name: String) -> (value: String, layer: LayerID?)? {
        let changedOwner = envOwners[name].flatMap { changed.contains($0) ? byId[$0] : nil }
        switch context {
        case .document(let document):
            if let tweak = changedOwner {
                guard let value = reading(tweak.id).value, case .json(.string(let text))? = tweak.editValue(for: value) else { return nil }
                return (text, nil)
            }
            guard case .string(let text)? = document.value(at: ["env", name]) else { return nil }
            return (text, nil)
        case .layered(let effective, _):
            let current = changedOwner.map { afterWrite[$0.id] ?? nil } ?? effective.value(at: ["env", name])
            guard let current, case .string(let text) = current.value else { return nil }
            return (text, current.winner)
        }
    }

    private static func settingsName(_ layer: LayerID) -> String {
        switch layer {
        case .user: "user settings"
        case .project: "shared project settings"
        case .local: "local project settings"
        case .managed: "managed settings"
        }
    }
}
