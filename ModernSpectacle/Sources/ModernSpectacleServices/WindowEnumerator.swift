import AppKit
import ModernSpectacleCore

/// Takes a snapshot of every standard, visible window of every regular app, paired with the element to move it.
@MainActor
public final class WindowEnumerator {
    public struct Entry {
        public let window: ManagedWindow
        public let info: WindowInfo
        public let pid: pid_t
    }

    public struct Snapshot {
        public let displays: [DisplayInfo]
        public let entries: [Entry]
        /// Windows seen but not used, with the reason, for debugging: "App: title (reason)".
        public let rejected: [String]
        /// One line per regular app: how many AX windows it reported and whether it is hidden.
        public let apps: [String]

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
    public func snapshot(lastActive: [String: Date], windowFocus: [String: Date] = [:], now: Date = Date(), pids: Set<pid_t>? = nil) -> Snapshot {
        let displays = Self.currentDisplays()
        guard !displays.isEmpty else {
            return Snapshot(displays: [], entries: [], rejected: [], apps: [])
        }
        var rejected: [String] = []
        var appLines: [String] = []

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusedWindow = accessibilityClient.focusedWindow()
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

            let axWindows = accessibilityClient.windows(of: app.processIdentifier)
            appLines.append("\(name): \(axWindows.count) windows\(app.isHidden ? ", hidden" : "")")
            for window in axWindows {
                guard window.isStandardWindow else {
                    rejected.append("\(name): \(window.title.prefix(40)) (\(window.debugDescription))")
                    continue
                }
                guard !window.isMinimized else {
                    rejected.append("\(name): \(window.title.prefix(40)) (minimized)")
                    continue
                }
                guard let frame = window.frame, frame.width >= 100, frame.height >= 100 else {
                    rejected.append("\(name): \(window.title.prefix(40)) (no frame or tiny)")
                    continue
                }

                let center = CGPoint(x: frame.midX, y: frame.midY)
                let display = displays.first { $0.visibleFrame.contains(center) }
                    ?? displays.min { distance($0.visibleFrame, to: center) < distance($1.visibleFrame, to: center) }
                    ?? displays[0]

                let title = String(window.title.prefix(80))
                let info = WindowInfo(
                    id: nextID,
                    app: name,
                    bundleID: bundleID,
                    kind: kind,
                    title: title,
                    frame: frame,
                    displayID: display.id,
                    isFocused: appIsFrontmost && focusedWindow.map { $0 == window } == true,
                    appActiveSecondsAgo: secondsAgo,
                    lastFocusedSecondsAgo: windowFocus["\(bundleID)|\(title)"].map { Int(now.timeIntervalSince($0)) },
                    resizable: window.isResizable
                )
                entries.append(Entry(window: window, info: info, pid: app.processIdentifier))
                nextID += 1
            }
        }

        return Snapshot(displays: displays, entries: entries, rejected: rejected, apps: appLines)
    }

    public func focusedWindowTitle() -> String {
        accessibilityClient.focusedWindow()?.title ?? ""
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
