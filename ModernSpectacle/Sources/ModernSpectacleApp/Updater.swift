import AppKit
import ModernSpectacleServices
import Sparkle

/// Self-updates through Sparkle from the store's appcast (SUFeedURL in Info.plist). Each update's EdDSA signature must
/// match SUPublicEDKey, and the new app must carry the same Developer ID, so only builds published from the developer's
/// Mac install. Sparkle checks once a day on its own; installing asks first. Failures go to status.log.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    static let storePageURL = URL(string: "https://store.alvumo.xyz/app/modern-spectacle")!

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkNow() {
        SmartArranger.log("update check (can check: \(controller.updater.canCheckForUpdates))")
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// The scheduled check, run now: with automatic updates on, Sparkle downloads without asking and installs on quit.
    func checkInBackground() {
        controller.updater.checkForUpdatesInBackground()
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard let error = error as NSError? else { return }
        let message = error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue)
            ? "update check: up to date"
            : "update failed: \(error.domain) \(error.code) \(error.localizedDescription)"
        MainActor.assumeIsolated { SmartArranger.log(message) } // Sparkle calls its delegate on the main thread
    }
}
