import Foundation

/// Remembers whether the setup questions were shown, so they open by themselves only once.
@MainActor
protocol OnboardingFlagStore: AnyObject {
    var onboardingSeen: Bool { get set }
}

@MainActor
final class UserDefaultsOnboardingFlags: OnboardingFlagStore {
    static let key = "onboardingSeen"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var onboardingSeen: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

enum OnboardingFlags {
    /// The store for the first-launch check, or nil when it must not run: a custom settings path
    /// (`PITOT_SETTINGS_PATH`) or a test run hosted in the app.
    @MainActor
    static func store(mode: FileMode, environment: [String: String], defaults: UserDefaults = .standard) -> OnboardingFlagStore? {
        guard mode != .custom, environment["XCTestConfigurationFilePath"] == nil else { return nil }
        return UserDefaultsOnboardingFlags(defaults: defaults)
    }
}
