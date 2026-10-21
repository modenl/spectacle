import AppKit
import ModernSpectacleCore

/// Takes a snapshot of every standard, visible window of every regular app, paired with the element to move it.
@MainActor
public final class WindowEnumerator {
    public struct Entry {
        public let window: ManagedWindow
        public let info: WindowInfo
    }

    public struct Snapshot {
        public let displays: [DisplayInfo]
        public let entries: [Entry]

        public var windows: [WindowInfo] { entries.map(\.info) }
    }

    private let accessibilityClient: AccessibilityClient
    private var categoryCache: [String: String?] = [:]

    public init(accessibilityClient: AccessibilityClient = AccessibilityClient()) {
        self.accessibilityClient = accessibilityClient
    }

    public static func currentDisplays() -> [DisplayInfo] {
        let frames = ScreenGeometry.displays
        let mainFrame = frames.first { $0.visibleFrame.minX == 0 && $0.visibleFrame.minY >= 0 } ?? frames.first
        return frames.enumerated().map { index, display in
            DisplayInfo(id: index, visibleFrame: display.visibleFrame, isMain: display == mainFrame)
        }
    }

    /// `lastActive` maps bundle id to the last time that app was frontmost. `pids` limits the snapshot to those apps.
    public func snapshot(lastActive: [String: Date], now: Date = Date(), pids: Set<pid_t>? = nil) -> Snapshot {
        let displays = Self.currentDisplays()
        guard !displays.isEmpty else {
            return Snapshot(displays: [], entries: [])
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var entries: [Entry] = []
        var nextID = 1

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated
                && (pids?.contains($0.processIdentifier) ?? true)
        }

        for app in apps {
            let bundleID = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
            let name = app.localizedName ?? bundleID
            let kind = AppClassifier.kind(bundleID: bundleID, category: category(of: app), name: name)
            let secondsAgo = lastActive[bundleID].map { Int(now.timeIntervalSince($0)) }
            let appIsFrontmost = app.processIdentifier == frontmostPID

            for (index, window) in accessibilityClient.windows(of: app.processIdentifier).enumerated() {
                guard
                    window.isStandardWindow,
                    !window.isMinimized,
                    let frame = window.frame,
                    frame.width >= 100, frame.height >= 100
                else {
                    continue
                }

                let center = CGPoint(x: frame.midX, y: frame.midY)
                let display = displays.first { $0.visibleFrame.contains(center) }
                    ?? displays.min { distance($0.visibleFrame, to: center) < distance($1.visibleFrame, to: center) }
                    ?? displays[0]

                let info = WindowInfo(
                    id: nextID,
                    app: name,
                    bundleID: bundleID,
                    kind: kind,
                    title: String(window.title.prefix(80)),
                    frame: frame,
                    displayID: display.id,
                    isFocused: appIsFrontmost && index == 0,
                    appActiveSecondsAgo: secondsAgo
                )
                entries.append(Entry(window: window, info: info))
                nextID += 1
            }
        }

        return Snapshot(displays: displays, entries: entries)
    }

    private func category(of app: NSRunningApplication) -> String? {
        let bundleID = app.bundleIdentifier ?? ""
        if let cached = categoryCache[bundleID] {
            return cached
        }
        let category = app.bundleURL
            .flatMap { Bundle(url: $0) }?
            .infoDictionary?["LSApplicationCategoryType"] as? String
        categoryCache[bundleID] = category
        return category
    }

    private func distance(_ rect: CGRect, to point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
