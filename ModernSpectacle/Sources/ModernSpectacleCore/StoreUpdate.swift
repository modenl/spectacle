import Foundation

/// The store's answer to "is there something newer than this version?" (GET /api/app/<id>/latest).
public struct StoreRelease: Codable, Equatable, Sendable {
    public struct Download: Codable, Equatable, Sendable {
        public var url: URL
        public var name: String
    }

    public var version: String
    public var notes: String
    /// The app's page in the store.
    public var url: URL
    /// The best file for this platform and CPU; nil when the newest version has no build for it.
    public var download: Download?
    public var updateAvailable: Bool?

    public init(version: String, notes: String, url: URL, download: Download? = nil, updateAvailable: Bool? = nil) {
        self.version = version
        self.notes = notes
        self.url = url
        self.download = download
        self.updateAvailable = updateAvailable
    }
}

public enum UpdatePolicy {
    public static let storeAppID = "modern-spectacle"
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    /// The app's page in the store: what to send people, and where updates come from.
    public static let storePageURL = URL(string: "https://store.alvumo.xyz/app/\(storeAppID)")!

    /// A link from the store's answer, if it is an https page on the store itself; otherwise the app's store page. The
    /// answer comes from the network, so it never gets to open a local file, another app's URL scheme or another site.
    public static func openable(_ url: URL) -> URL {
        let host = storePageURL.host
        guard url.scheme == "https", url.host == host, url.port == nil, url.user == nil, url.password == nil else { return storePageURL }
        return url
    }

    /// Numeric parts compared one by one, so 1.10 is newer than 1.9 and 1.2 equals 1.2.0.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate)
        let b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// At most once a day.
    public static func isCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval
    }

    /// Worth telling the user: newer than what runs, and not a version they chose to skip.
    public static func shouldNotify(_ release: StoreRelease, current: String, skipped: String?) -> Bool {
        isNewer(release.version, than: current) && release.version != skipped
    }

    public static func latestURL(current: String, arch: String?) -> URL {
        var components = URLComponents(string: "https://store.alvumo.xyz/api/app/\(storeAppID)/latest")!
        components.queryItems = [URLQueryItem(name: "platform", value: "macos"), URLQueryItem(name: "current", value: current)]
        if let arch { components.queryItems?.append(URLQueryItem(name: "arch", value: arch)) }
        return components.url!
    }
}
