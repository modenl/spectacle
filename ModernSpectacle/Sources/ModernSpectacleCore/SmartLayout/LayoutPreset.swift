import CoreGraphics
import Foundation

/// A window as a preset remembers it: by app and title, since window ids change between snapshots and runs.
public struct PresetWindow: Codable, Equatable, Sendable {
    public var bundleID: String
    public var app: String
    public var title: String

    public init(bundleID: String, app: String, title: String) {
        self.bundleID = bundleID
        self.app = app
        self.title = title
    }

    init(_ window: WindowInfo) {
        self.init(bundleID: window.bundleID, app: window.app, title: window.title)
    }
}

public struct PresetSlot: Codable, Equatable, Sendable {
    public var slot: String
    public var window: PresetWindow

    public init(slot: String, window: PresetWindow) {
        self.slot = slot
        self.window = window
    }
}

/// One display's part of a preset: the template, who sits in which slot, and the stack.
public struct PresetDisplay: Codable, Equatable, Sendable {
    public var displayID: Int
    public var frame: RectInfo
    public var isMain: Bool
    public var template: String
    public var slots: [PresetSlot]
    public var stack: [PresetWindow]
    public var cascade: [PresetWindow]

    public init(displayID: Int, frame: RectInfo, isMain: Bool, template: String, slots: [PresetSlot], stack: [PresetWindow] = [], cascade: [PresetWindow] = []) {
        self.displayID = displayID
        self.frame = frame
        self.isMain = isMain
        self.template = template
        self.slots = slots
        self.stack = stack
        self.cascade = cascade
    }
}

/// A named layout the user saved for a recurring task and restores with one key. Users of layout assistants ask for
/// exactly this (DuoZone 2025; MR placement study 2026): the arrangement is worked out once, then reused.
public struct LayoutPreset: Codable, Equatable, Sendable {
    public var name: String
    public var date: Date
    public var displays: [PresetDisplay]

    public init(name: String, date: Date, displays: [PresetDisplay]) {
        self.name = name
        self.date = date
        self.displays = displays
    }

    public var windowCount: Int {
        displays.map { $0.slots.count + $0.stack.count + $0.cascade.count }.reduce(0, +)
    }
}

public enum LayoutPresets {
    public static let maxPresets = 9

    /// Captures the template choices currently applied (window ids from `request`) as a preset.
    public static func make(name: String, from choices: [DisplayChoice], request: LayoutRequest, date: Date = Date()) -> LayoutPreset? {
        let windowOf = Dictionary(request.windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let displays = choices.compactMap { choice -> PresetDisplay? in
            guard let display = request.displays.first(where: { $0.id == choice.id }) else { return nil }
            let slots = choice.slots.compactMap { a in windowOf[a.window].map { PresetSlot(slot: a.slot, window: PresetWindow($0)) } }
            guard !slots.isEmpty else { return nil }
            return PresetDisplay(
                displayID: display.id, frame: display.frame, isMain: display.isMain, template: choice.template, slots: slots,
                stack: choice.stack.compactMap { windowOf[$0].map(PresetWindow.init) },
                cascade: choice.cascade.compactMap { windowOf[$0].map(PresetWindow.init) }
            )
        }
        guard !displays.isEmpty else { return nil }
        return LayoutPreset(name: name, date: date, displays: displays)
    }

    /// Saving under an existing name replaces it; the newest preset goes last so numbering stays stable.
    public static func saving(_ preset: LayoutPreset, into presets: [LayoutPreset]) -> [LayoutPreset] {
        var result = presets
        if let index = result.firstIndex(where: { $0.name == preset.name }) {
            result[index] = preset
        } else {
            result.append(preset)
            if result.count > maxPresets { result.removeFirst(result.count - maxPresets) }
        }
        return result
    }

    /// Which current display each preset display goes to: the same display if it is still there at the same size,
    /// otherwise an unused display of the same size class (the template must fit it), the main display first.
    public static func displayMapping(for preset: LayoutPreset, displays: [DisplayInfo]) -> [Int: DisplayInfo] {
        var mapping: [Int: DisplayInfo] = [:]
        var used = Set<Int>()
        for saved in preset.displays {
            if let same = displays.first(where: { $0.id == saved.displayID && $0.frame.w == saved.frame.w && $0.frame.h == saved.frame.h }) {
                mapping[saved.displayID] = same
                used.insert(same.id)
            }
        }
        for saved in preset.displays where mapping[saved.displayID] == nil {
            let fits = displays
                .filter { !used.contains($0.id) && LayoutTemplates.candidates(for: $0).contains { $0.id == saved.template } }
                .sorted { ($0.isMain == saved.isMain ? 0 : 1, $0.id) < ($1.isMain == saved.isMain ? 0 : 1, $1.id) }
            if let display = fits.first {
                mapping[saved.displayID] = display
                used.insert(display.id)
            }
        }
        return mapping
    }

    /// The preset as template choices for the windows open now, plus the request with every matched window moved to the
    /// display the preset puts it on. Matching: exact app and title first, then any window of the same app, preferring
    /// one already on that display and then the most recently focused. Slots are filled before the stack, main first,
    /// so the important places get the best match. Windows the preset does not mention end up stacked by the composer.
    public static func restore(_ preset: LayoutPreset, for request: LayoutRequest) -> (choices: [DisplayChoice], request: LayoutRequest) {
        let mapping = displayMapping(for: preset, displays: request.displays)
        var windows = request.windows
        var used = Set<Int>()

        func match(_ wanted: PresetWindow, on displayID: Int) -> Int? {
            if let exact = windows.first(where: { !used.contains($0.id) && $0.bundleID == wanted.bundleID && $0.title == wanted.title }) {
                return exact.id
            }
            return windows
                .filter { !used.contains($0.id) && $0.bundleID == wanted.bundleID }
                .min { a, b in
                    let rank = { (w: WindowInfo) in (w.displayID == displayID ? 0 : 1, w.lastFocusedSecondsAgo ?? .max, w.appActiveSecondsAgo ?? .max) }
                    return rank(a) < rank(b)
                }?.id
        }
        func claim(_ wanted: PresetWindow, on displayID: Int) -> Int? {
            guard let id = match(wanted, on: displayID) else { return nil }
            used.insert(id)
            if let index = windows.firstIndex(where: { $0.id == id }) { windows[index].displayID = displayID }
            return id
        }

        var choices: [DisplayChoice] = []
        let ordered = preset.displays.filter { mapping[$0.displayID] != nil }
        var assignments: [Int: [TemplateAssignment]] = [:]
        // All slots on all displays first, so a slot never loses its window to another display's stack.
        for saved in ordered {
            let target = mapping[saved.displayID]!.id
            let slots = saved.slots.sorted { ($0.slot == "main" ? 0 : 1) < ($1.slot == "main" ? 0 : 1) }
            assignments[saved.displayID] = slots.compactMap { s in claim(s.window, on: target).map { TemplateAssignment(slot: s.slot, window: $0) } }
        }
        for saved in ordered {
            let target = mapping[saved.displayID]!.id
            choices.append(DisplayChoice(
                id: target, template: saved.template, slots: assignments[saved.displayID] ?? [],
                stack: saved.stack.compactMap { claim($0, on: target) },
                cascade: saved.cascade.compactMap { claim($0, on: target) }
            ))
        }

        var moved = request
        moved.windows = windows
        // The preset decides what is main; the focused window must not override it.
        moved.focusedWindowID = nil
        return (choices.sorted { $0.id < $1.id }, moved)
    }
}
