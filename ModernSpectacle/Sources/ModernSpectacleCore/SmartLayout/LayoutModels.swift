import CoreGraphics
import Foundation

/// Integer rectangle in Accessibility coordinates (origin at the top-left of the main display, y grows downward).
public struct RectInfo: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(x: Int, y: Int, w: Int, h: Int) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public init(_ rect: CGRect) {
        let integral = rect.integral
        x = Int(integral.minX)
        y = Int(integral.minY)
        w = Int(integral.width)
        h = Int(integral.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }
}

public struct DisplayInfo: Codable, Equatable, Sendable {
    public var id: Int
    public var frame: RectInfo
    public var isMain: Bool

    public init(id: Int, visibleFrame: CGRect, isMain: Bool) {
        self.id = id
        frame = RectInfo(visibleFrame)
        self.isMain = isMain
    }

    public var visibleFrame: CGRect { frame.cgRect }
}

public enum AppKind: String, Codable, Sendable {
    case coding
    case browser
    case chat
    case files
    case media
    case other
}

public struct WindowInfo: Codable, Equatable, Sendable {
    public var id: Int
    public var app: String
    public var bundleID: String
    public var kind: AppKind
    public var title: String
    public var frame: RectInfo
    public var displayID: Int
    public var isFocused: Bool
    /// Seconds since the owning app was last frontmost; nil when unknown.
    public var appActiveSecondsAgo: Int?

    public init(
        id: Int,
        app: String,
        bundleID: String,
        kind: AppKind,
        title: String,
        frame: CGRect,
        displayID: Int,
        isFocused: Bool,
        appActiveSecondsAgo: Int?
    ) {
        self.id = id
        self.app = app
        self.bundleID = bundleID
        self.kind = kind
        self.title = title
        self.frame = RectInfo(frame)
        self.displayID = displayID
        self.isFocused = isFocused
        self.appActiveSecondsAgo = appActiveSecondsAgo
    }

    /// Stable identity across snapshots; window element identity is not stable across AX queries.
    public var key: String { "\(bundleID)|\(title)" }
}

/// A window the user moved or resized shortly after we arranged it. The strongest preference signal we have.
public struct LayoutCorrection: Codable, Equatable, Sendable {
    public var app: String
    public var title: String
    public var planned: RectInfo
    public var actual: RectInfo
    public var date: Date

    public init(app: String, title: String, planned: RectInfo, actual: RectInfo, date: Date) {
        self.app = app
        self.title = title
        self.planned = planned
        self.actual = actual
        self.date = date
    }
}

public struct LayoutRequest: Codable, Equatable, Sendable {
    public var displays: [DisplayInfo]
    public var windows: [WindowInfo]
    /// App names, most recently used first.
    public var recentApps: [String]
    public var corrections: [LayoutCorrection]
    /// Free-form notes the planner keeps about this user across runs.
    public var notes: String
    public var localTime: String
    /// Per-app arrangement style the user has shown by hand (bundle id -> style).
    public var appStyles: [String: ArrangementStyle]

    public init(
        displays: [DisplayInfo],
        windows: [WindowInfo],
        recentApps: [String],
        corrections: [LayoutCorrection],
        notes: String,
        localTime: String,
        appStyles: [String: ArrangementStyle] = [:]
    ) {
        self.displays = displays
        self.windows = windows
        self.recentApps = recentApps
        self.corrections = corrections
        self.notes = notes
        self.localTime = localTime
        self.appStyles = appStyles
    }

    /// Changes when the set of windows or displays changes; used to decide whether a cached plan still applies.
    public var signature: String {
        let windowKeys = windows.map(\.key).sorted().joined(separator: "\n")
        let displayKeys = displays.map { "\($0.frame.x),\($0.frame.y),\($0.frame.w),\($0.frame.h)" }.joined(separator: ";")
        return displayKeys + "\n" + windowKeys
    }
}

public struct Placement: Codable, Equatable, Sendable {
    public var id: Int
    public var group: String
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(id: Int, group: String, rect: CGRect) {
        self.id = id
        self.group = group
        let info = RectInfo(rect)
        x = info.x
        y = info.y
        w = info.w
        h = info.h
    }

    public var rect: CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }
}

public struct LayoutPlan: Codable, Equatable, Sendable {
    public var summary: String
    public var notes: String
    public var placements: [Placement]

    public init(summary: String, notes: String, placements: [Placement]) {
        self.summary = summary
        self.notes = notes
        self.placements = placements
    }
}
