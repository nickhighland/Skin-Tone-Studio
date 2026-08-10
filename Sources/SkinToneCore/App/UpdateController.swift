import Sparkle

/// Owns Sparkle's standard approval-based update UI and scheduled checks.
public final class UpdateController {
    public static let shared = UpdateController()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    public var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
