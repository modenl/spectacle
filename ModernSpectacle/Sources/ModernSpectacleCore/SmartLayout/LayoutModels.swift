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
    /// Seconds since this particular window last had keyboard focus; nil when it has not been focused since we started watching.
    public var lastFocusedSecondsAgo: Int?
    /// False for fixed-size windows such as Calculator: they keep their size and only get moved.
    public var resizable: Bool

    public init(
        id: Int,
        app: String,
        bundleID: String,
        kind: AppKind,
        title: String,
        frame: CGRect,
        displayID: Int,
        isFocused: Bool,
        appActiveSecondsAgo: Int?,
        lastFocusedSecondsAgo: Int? = nil,
        resizable: Bool = true
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
        self.lastFocusedSecondsAgo = lastFocusedSecondsAgo
        self.resizable = resizable
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

/// One stretch of time an app was frontmost. The timeline shows what the person was switching between and for how long.
public struct FocusEvent: Codable, Equatable, Sendable {
    public var app: String
    public var window: String
    public var secondsAgo: Int
    public var dwellSeconds: Int

    public init(app: String, window: String, secondsAgo: Int, dwellSeconds: Int) {
        self.app = app
        self.window = window
        self.secondsAgo = secondsAgo
        self.dwellSeconds = dwellSeconds
    }
}

public struct LayoutRequest: Codable, Equatable, Sendable {
    public var displays: [DisplayInfo]
    public var windows: [WindowInfo]
    /// App names, most recently used first.
    public var recentApps: [String]
    /// The window with keyboard focus right now: where the person's attention is.
    public var focusedWindowID: Int?
    /// Most recent app switches first, with how long each stayed in front.
    public var focusTimeline: [FocusEvent]
    /// What was applied last time, with window ids translated to the current snapshot. Keeps layouts stable.
    public var previous: [DisplayChoice]
    public var corrections: [LayoutCorrection]
    /// Free-form notes the planner keeps about this user across runs.
    public var notes: String
    public var localTime: String
    /// Per-app arrangement style the user has shown by hand (bundle id -> style).
    public var appStyles: [String: ArrangementStyle]
    /// Narrowest width each app was seen to accept (bundle id -> points); slots narrower than that are not used for it.
    public var minimumWidths: [String: Int] = [:]
    /// The UI language ("en" or "zh-Hans"); the model writes its summary in it.
    public var language: String = "en"

    public init(
        displays: [DisplayInfo],
        windows: [WindowInfo],
        recentApps: [String],
        corrections: [LayoutCorrection],
        notes: String,
        localTime: String,
        appStyles: [String: ArrangementStyle] = [:],
        focusedWindowID: Int? = nil,
        focusTimeline: [FocusEvent] = [],
        previous: [DisplayChoice] = []
    ) {
        self.displays = displays
        self.windows = windows
        self.recentApps = recentApps
        self.focusedWindowID = focusedWindowID
        self.focusTimeline = focusTimeline
        self.previous = previous
        self.corrections = corrections
        self.notes = notes
        self.localTime = localTime
        self.appStyles = appStyles
    }

    /// Only one display and its windows: what Smart Arrange lays out. The other displays are left as they are.
    public func restricted(to displayID: Int) -> LayoutRequest {
        var request = self
        request.displays = displays.filter { $0.id == displayID }
        request.windows = windows.filter { $0.displayID == displayID }
        if let focused = focusedWindowID, !request.windows.contains(where: { $0.id == focused }) { request.focusedWindowID = nil }
        request.previous = previous.filter { $0.id == displayID }
        return request
    }

    /// The display the person is working on: the focused window's, else the one under the pointer, else the main one.
    /// `pointer` is in Accessibility coordinates.
    public func activeDisplayID(pointer: CGPoint?) -> Int? {
        if let focused = windows.first(where: { $0.id == focusedWindowID }) { return focused.displayID }
        if let pointer, let display = displays.first(where: { $0.visibleFrame.insetBy(dx: -1, dy: -40).contains(pointer) }) { return display.id }
        return displays.first { $0.isMain }?.id ?? displays.first?.id
    }

    /// Changes when apps open or close windows or the displays change; used to decide whether a cached ranking still
    /// applies. Titles are left out on purpose: a terminal's title changes with every command, and asking the model again
    /// for that would waste calls (the cached ranking follows retitled windows by app).
    public var signature: String {
        let windowKeys = windows.map(\.bundleID).sorted().joined(separator: "\n")
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
    /// The template choices behind the placements, when a template planner produced them. Kept for stability.
    public var choices: [DisplayChoice]?

    public init(summary: String, notes: String, placements: [Placement], choices: [DisplayChoice]? = nil) {
        self.summary = summary
        self.notes = notes
        self.placements = placements
        self.choices = choices
    }
}
