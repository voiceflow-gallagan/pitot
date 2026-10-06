import Foundation
import Sparkle

/// The only place that uses Sparkle. Sparkle's controller and delegate are main-actor types.
@MainActor
final class SparkleUpdater: NSObject, UpdateChecking, SPUUpdaterDelegate {
    var onEvent: ((UpdateEvent) -> Void)?

    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    override init() {
        super.init()
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.onEvent?(.stateChanged) }
        }
        self.controller = controller
        controller.startUpdater()
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// "No update found" and a cancel by the user are not failures.
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        let normal = [SUError.noUpdateError, .installationCanceledError, .installationAuthorizeLaterError].map { Int($0.rawValue) }
        guard error.domain != SUSparkleErrorDomain || !normal.contains(error.code) else { return }
        onEvent?(.checkFailed)
    }
}
