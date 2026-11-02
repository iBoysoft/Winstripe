import Foundation
import Sparkle

/// Owns the Sparkle updater.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()
    static let repositoryURL = URL(string: "https://github.com/iBoysoft/Winstripe")!
    static let feedURL = repositoryURL

    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func start() {
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
