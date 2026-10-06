import Foundation
import Observation

/// What the app needs from an updater. Sparkle provides it in `UpdaterController.swift`; tests use a fake.
@MainActor
protocol UpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    /// Called on the main actor when `canCheckForUpdates` may have changed or a check failed.
    var onEvent: ((UpdateEvent) -> Void)? { get set }
    func checkForUpdates()
}

enum UpdateEvent: Equatable, Sendable {
    case stateChanged
    case checkFailed
}

enum UpdaterPolicy {
    /// The updater runs only with a public key to verify updates, and never during tests or a run on a
    /// custom settings path, so tests and manual runs never reach the network.
    static func mayStart(publicKey: String?, environment: [String: String]) -> Bool {
        guard let key = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return false }
        return environment["XCTestConfigurationFilePath"] == nil && environment["PITOT_SETTINGS_PATH"] == nil
    }
}

/// The update menu item and the About switch.
///
/// No check happens until the user asks: the Info.plist turns automatic checks off, and only the
/// "Automatically check for updates" switch turns them on. Sparkle checks in the background, so the
/// app never waits for the network, and a failed check only shows a quiet message.
@MainActor
@Observable
final class UpdatesModel {
    static let checkTitle = "Check for Updates…"
    static let notSetUpTitle = "Updates are not set up yet"
    static let failedMessage = "Could not check for updates"

    /// False when there is no public key, or the app runs tests or on a custom settings path.
    let isConfigured: Bool
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecks = false
    private(set) var statusMessage: String?

    private let makeUpdater: @MainActor () -> UpdateChecking
    private var updater: UpdateChecking?

    init(publicKey: String?, environment: [String: String], makeUpdater: @escaping @MainActor () -> UpdateChecking) {
        isConfigured = UpdaterPolicy.mayStart(publicKey: publicKey, environment: environment)
        self.makeUpdater = makeUpdater
        statusMessage = isConfigured ? nil : Self.notSetUpTitle
    }

    var menuTitle: String { isConfigured ? Self.checkTitle : Self.notSetUpTitle }
    var isMenuEnabled: Bool { isConfigured && canCheckForUpdates }
    var hasUpdater: Bool { updater != nil }

    /// Creates and starts the updater once, and only when it is configured.
    func start() {
        guard isConfigured, updater == nil else { return }
        let made = makeUpdater()
        made.onEvent = { [weak self] event in self?.handle(event) }
        updater = made
        sync()
    }

    func checkForUpdates() {
        guard isMenuEnabled, let updater else { return }
        statusMessage = nil
        updater.checkForUpdates()
    }

    func setAutomaticChecks(_ isOn: Bool) {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = isOn
        sync()
    }

    private func handle(_ event: UpdateEvent) {
        switch event {
        case .stateChanged: sync()
        case .checkFailed: statusMessage = Self.failedMessage
        }
    }

    private func sync() {
        canCheckForUpdates = updater?.canCheckForUpdates ?? false
        automaticallyChecks = updater?.automaticallyChecksForUpdates ?? false
    }
}
