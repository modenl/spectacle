import Foundation
import ModernSpectacleCore

/// Asks the store whether a newer version is out. Never downloads or installs anything: the user gets a notice and
/// a button that opens the download in the browser. Network errors are ignored quietly.
@MainActor
public final class UpdateChecker {
    private enum Keys {
        static let automatic = "updates.automatic"
        static let lastCheck = "updates.lastCheck"
        static let skipped = "updates.skippedVersion"
    }

    public enum Result: Equatable, Sendable {
        case available(StoreRelease)
        case upToDate(String)
        case failed(String)
    }

    private let defaults: UserDefaults
    private let session: URLSession

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
    }

    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// On by default; the app's only network access, and it sends nothing but the version.
    public var automaticChecks: Bool {
        get { defaults.object(forKey: Keys.automatic) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.automatic) }
    }

    public var isCheckDue: Bool {
        automaticChecks && UpdatePolicy.isCheckDue(lastCheck: defaults.object(forKey: Keys.lastCheck) as? Date, now: Date())
    }

    public func skip(_ version: String) {
        defaults.set(version, forKey: Keys.skipped)
    }

    /// `userInitiated` checks ignore a skipped version: asking explicitly means wanting to know.
    public func check(userInitiated: Bool) async -> Result {
        let current = Self.currentVersion
        let url = UpdatePolicy.latestURL(current: current, arch: nil)
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 100_000 else {
                return .failed(L("The store did not answer", "商店没有响应"))
            }
            let release = try JSONDecoder().decode(StoreRelease.self, from: data)
            defaults.set(Date(), forKey: Keys.lastCheck)
            let skipped = userInitiated ? nil : defaults.string(forKey: Keys.skipped)
            return UpdatePolicy.shouldNotify(release, current: current, skipped: skipped) ? .available(release) : .upToDate(current)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
