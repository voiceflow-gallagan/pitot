public struct EffectiveValue: Sendable, Equatable {
    public struct Contribution: Sendable, Equatable {
        public let layer: LayerID
        /// The value as that layer's file holds it.
        public let value: JSONValue
    }

    /// The value in effect. An `env` variable set to `null` reads as the text `null`, which is what
    /// processes see (tested, rule 7 in `Core/MERGE-RULES.md`).
    public let value: JSONValue
    /// The highest layer whose value reaches `value`.
    public let winner: LayerID
    /// Every layer that sets the path, highest first.
    public let contributions: [Contribution]
    /// Layers that set the path but whose value does not reach `value`, highest first.
    public let overriddenLayers: [LayerID]
    /// The overridden layers whose value Claude Code discards because of the layer itself, such as a
    /// project `modelPicker` or a project-local `remoteControlAtStartup: true`.
    public let ignoredLayers: [LayerID]
    /// True when `value` combines several layers: a joined list or objects merged key by key.
    public let merged: Bool
}

/// The settings a session gets from the layers, and where each value comes from.
///
/// Merging follows `SettingsMerge`, then these steps, all inferred (`Core/MERGE-RULES.md`):
/// - Keys a layer cannot set are dropped from it first (`ScopedKey`): `modelPicker` in project and
///   local, `deniedModels` outside managed, and the keys a repository cannot turn off.
/// - A managed `availableModels` replaces the merged list.
/// - The restrictive keys follow `RestrictiveKey`.
///
/// Not modeled: schema checks other than `null` (a value of the wrong type also makes Claude Code
/// skip the file), the `env` variables Claude Code ignores in project and local files, project
/// `permissions.allow` rules that wait for workspace trust, plugin-supplied settings below user,
/// and the `--settings` layer.
public struct EffectiveSettings: Sendable {
    /// One layer per id, highest precedence first. A later layer with the same id replaces an earlier one.
    public let layers: [SettingsLayer]
    /// All layers merged, as a session would get them.
    public let merged: JSONValue
    let resolver: LayerResolver

    public init(layers: [SettingsLayer]) {
        var byID: [LayerID: SettingsLayer] = [:]
        for layer in layers {
            byID[layer.id] = layer
        }
        let ordered = LayerID.byPrecedence.compactMap { byID[$0] }
        var roots: [LayerID: JSONValue] = [:]
        for layer in ordered {
            guard let document = layer.document,
                  case .success(let root) = LayerContent.normalized(document.decode(document.root), for: layer.id)
            else { continue }
            roots[layer.id] = root
        }
        self.init(layers: ordered, roots: roots)
    }

    init(layers: [SettingsLayer], roots: [LayerID: JSONValue]) {
        self.layers = layers
        resolver = LayerResolver(roots: roots)
        merged = resolver.mergedTree()
    }

    public func layer(_ id: LayerID) -> SettingsLayer? {
        layers.first { $0.id == id }
    }

    /// The value in effect at `path`, or nil when no layer sets it or a higher value cuts it off.
    public func value(at path: [String]) -> EffectiveValue? {
        let resolution = resolver.resolve(path)
        guard let winner = resolution.live.last, let value = SettingsTree.value(in: merged, at: path) else { return nil }
        let contributions = LayerID.byPrecedence.compactMap { id in
            resolver.roots[id].flatMap { SettingsTree.value(in: $0, at: path) }.map { EffectiveValue.Contribution(layer: id, value: $0) }
        }
        return EffectiveValue(
            value: value,
            winner: winner,
            contributions: contributions,
            overriddenLayers: contributions.map(\.layer).filter { !resolution.live.contains($0) },
            ignoredLayers: LayerID.byPrecedence.filter(resolution.ignored.contains),
            merged: resolution.live.count > 1
        )
    }

    public func value(for tweak: Tweak) -> EffectiveValue? {
        value(at: tweak.location.path)
    }

    /// Whether the managed layer sets `path` so that no other layer can change the value in effect.
    /// A managed list still takes entries from other layers, and a managed object still takes new
    /// keys, so neither locks. A restrictive key locks only when the managed value is the most
    /// restrictive one a lower layer could give.
    public func lockedByManaged(_ path: [String]) -> Bool {
        guard let managed = resolver.readable[.managed], let key = path.first, let last = path.last else { return false }
        let projection = SettingsTree.project(managed, onto: path)
        if projection == .absent { return false }
        if let rule = RestrictiveKey.rule(for: path) {
            guard case .found(let value) = projection else { return true }
            return rule.locks(managedValue: value)
        }
        if SettingsMerge.managedWholeKeys.contains(key) { return true }
        if let scoped = ScopedKey.rule(for: key), scoped.readFrom.subtracting([.managed]).isEmpty { return true }
        guard case .found(let value) = projection else { return true }
        if SettingsMerge.replacesWhole(key: last, parentKey: path.count > 1 ? path[path.count - 2] : nil) { return true }
        switch value {
        case .object: return false
        case .array: return last == "fallbackModel"
        case .null, .bool, .number, .string: return true
        }
    }

    public func lockedByManaged(_ tweak: Tweak) -> Bool {
        lockedByManaged(tweak.location.path)
    }

    /// The layers whose values keep the value `layer` holds at `path` out of effect, highest first.
    /// Usually these are higher layers that set the key, but for a restrictive key a lower layer
    /// can win. Empty when `layer` does not set the path, or when Claude Code ignores its value there.
    public func shadowing(of layer: LayerID, at path: [String]) -> [LayerID] {
        guard resolver.resolve(path, among: [layer]).live.contains(layer) else { return [] }
        return LayerID.byPrecedence.filter { other in
            other != layer && resolver.readable[other] != nil && !resolver.resolve(path, among: [layer, other]).live.contains(layer)
        }
    }

    /// What would be in effect at `path` after writing `value` to `kind`, the other layers unchanged.
    /// A nil `value` removes the key. A missing, invalid or unreadable file counts as empty, as if
    /// Pitot created it. A write through a value that is not an object fails in `JSONEdit`, so the
    /// current value is returned. Writing `null` outside `env` would make Claude Code skip the file.
    public func effective(at path: [String], writing value: JSONValue?, to kind: SettingsLayerKind) -> EffectiveValue? {
        let id = LayerID(kind)
        guard !path.isEmpty else { return self.value(at: path) }
        let current = resolver.roots[id] ?? .object([])
        let updated: JSONValue
        if let value {
            guard let written = SettingsTree.setting(value, at: path, in: current) else { return self.value(at: path) }
            updated = written
        } else {
            updated = SettingsTree.removing(path, from: current)
        }
        var roots = resolver.roots
        switch LayerContent.normalized(updated, for: id) {
        case .success(let root): roots[id] = root
        case .failure: roots.removeValue(forKey: id)
        }
        return EffectiveSettings(layers: layers, roots: roots).value(at: path)
    }

    /// What would be in effect for `tweak` after Pitot writes `value` to `kind`, using the same
    /// JSON the write would use. A nil `value`, or an off flag, removes the key.
    public func effective(for tweak: Tweak, writing value: TweakValue?, to kind: SettingsLayerKind) -> EffectiveValue? {
        let json: JSONValue?
        switch value.flatMap(tweak.editValue(for:)) {
        case nil:
            json = nil
        case .json(let decoded)?:
            json = decoded
        case .raw(let bytes)?:
            do throws(JSONScanError) {
                let document = try JSONScanner.scan(bytes)
                json = document.decode(document.root)
            } catch {
                return self.value(for: tweak)
            }
        }
        return effective(at: tweak.location.path, writing: json, to: kind)
    }
}

/// Resolves one path through the layers, recording which layers reach the result.
struct LayerResolver: Sendable {
    struct Resolution {
        var value: JSONValue?
        /// Layers whose value reaches `value`, lowest first.
        var live: [LayerID]
        var ignored: [LayerID]
    }

    /// The content of each usable layer.
    let roots: [LayerID: JSONValue]
    /// `roots` without the keys Claude Code ignores in each layer.
    let readable: [LayerID: JSONValue]

    init(roots: [LayerID: JSONValue]) {
        self.roots = roots
        var readable: [LayerID: JSONValue] = [:]
        for (id, root) in roots {
            readable[id] = ScopedKey.readable(root, in: id)
        }
        self.readable = readable
    }

    func resolve(_ path: [String], among subset: Set<LayerID>? = nil) -> Resolution {
        let layers = LayerID.allCases.filter { readable[$0] != nil && subset?.contains($0) != false }
        let scopeIgnored = layers.filter { id in
            roots[id].flatMap { SettingsTree.value(in: $0, at: path) } != nil
                && readable[id].flatMap { SettingsTree.value(in: $0, at: path) } == nil
        }
        var resolution: Resolution
        if let rule = RestrictiveKey.all.first(where: { path.starts(with: $0.path) }) {
            resolution = restrictive(rule, among: layers)
            if path.count > rule.path.count {
                resolution.value = resolution.value.flatMap { SettingsTree.value(in: $0, at: Array(path.dropFirst(rule.path.count))) }
                resolution.live = resolution.value == nil ? [] : resolution.live
                resolution.ignored = []
            }
        } else {
            resolution = fold(path, among: layers)
        }
        resolution.ignored = scopeIgnored + resolution.ignored
        return resolution
    }

    func mergedTree() -> JSONValue {
        var tree = SettingsMerge.fold(LayerID.allCases.compactMap { readable[$0] })
        if let managed = readable[.managed] {
            for key in SettingsMerge.managedWholeKeys {
                guard let value = SettingsTree.member(key, in: managed) else { continue }
                tree = SettingsTree.setting(value, at: [key], in: tree) ?? tree
            }
        }
        let layers = LayerID.allCases.filter { readable[$0] != nil }
        for rule in RestrictiveKey.all {
            if let value = restrictive(rule, among: layers).value {
                tree = SettingsTree.setting(value, at: rule.path, in: tree) ?? tree
            } else {
                tree = SettingsTree.removing(rule.path, from: tree)
            }
        }
        guard case .object(let variables)? = SettingsTree.member("env", in: tree) else { return tree }
        let text = variables.map { $0.value == .null ? JSONValue.Member(key: $0.key, value: "null") : $0 }
        return SettingsTree.setting(.object(text), at: ["env"], in: tree) ?? tree
    }

    private func fold(_ path: [String], among layers: [LayerID]) -> Resolution {
        var value: JSONValue?
        var live: [LayerID] = []
        for id in layers {
            guard let root = readable[id] else { continue }
            switch SettingsTree.project(root, onto: path) {
            case .absent:
                continue
            case .reset(let replacement):
                value = replacement
                live = replacement == nil ? [] : [id]
            case .found(let upper):
                if let lower = value, Self.combines(lower, upper, at: path) {
                    value = SettingsMerge.merge(lower, upper, key: path.last)
                    live.append(id)
                } else {
                    value = upper
                    live = [id]
                }
            }
        }
        if let key = path.first, SettingsMerge.managedWholeKeys.contains(key), layers.contains(.managed),
           let managed = readable[.managed], SettingsTree.member(key, in: managed) != nil {
            value = SettingsTree.value(in: managed, at: path)
            live = value == nil ? [] : [.managed]
        }
        return Resolution(value: value, live: live, ignored: [])
    }

    private func restrictive(_ rule: RestrictiveKey, among layers: [LayerID]) -> Resolution {
        let values = layers.compactMap { id in
            readable[id].flatMap { SettingsTree.value(in: $0, at: rule.path) }.map { (layer: id, value: $0) }
        }
        let base = values.last { !rule.onlyRestrictiveFrom.contains($0.layer) }
        let honored = values.filter { rule.honoredFrom.contains($0.layer) && rule.isRestrictive($0.value) }
        let winner = ((base.map { [$0] } ?? []) + honored).max {
            (rule.rank(of: $0.value), $0.layer.rank) < (rule.rank(of: $1.value), $1.layer.rank)
        }
        let ignored = values.filter { rule.onlyRestrictiveFrom.contains($0.layer) && !rule.isRestrictive($0.value) }
        return Resolution(value: winner?.value, live: winner.map { [$0.layer] } ?? [], ignored: ignored.map(\.layer))
    }

    private static func combines(_ lower: JSONValue, _ upper: JSONValue, at path: [String]) -> Bool {
        guard let key = path.last else { return SettingsMerge.combines(lower, upper, key: nil) }
        let parentKey = path.count > 1 ? path[path.count - 2] : nil
        return !SettingsMerge.replacesWhole(key: key, parentKey: parentKey) && SettingsMerge.combines(lower, upper, key: key)
    }
}
