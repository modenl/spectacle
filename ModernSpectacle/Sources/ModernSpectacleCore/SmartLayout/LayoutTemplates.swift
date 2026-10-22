import CoreGraphics
import Foundation

/// Classic layouts, picked per display size. The model only chooses a template and says which window goes in which
/// slot; the geometry is fixed here, so results are predictable and the model cannot invent bad proportions.
public struct TemplateSlot: Codable, Equatable, Sendable {
    public var id: String
    public var share: Double

    public init(_ id: String, share: Double = 1) {
        self.id = id
        self.share = share
    }
}

public struct TemplateColumn: Codable, Equatable, Sendable {
    public var share: Double
    /// Tile slots top to bottom. Empty when the column is the stack.
    public var slots: [TemplateSlot]
    /// A stack column holds any number of background windows, large and staggered, showing an edge.
    public var isStack: Bool

    public init(share: Double, slots: [TemplateSlot] = [], isStack: Bool = false) {
        self.share = share
        self.slots = slots
        self.isStack = isStack
    }
}

public struct LayoutTemplate: Codable, Equatable, Sendable {
    public var id: String
    public var description: String
    public var columns: [TemplateColumn]

    public init(id: String, description: String, columns: [TemplateColumn]) {
        self.id = id
        self.description = description
        self.columns = columns
    }

    public var slotIDs: [String] { columns.flatMap { $0.slots.map(\.id) } }
    public var hasStack: Bool { columns.contains(where: \.isStack) }
}

/// What the model sees per display: the templates it may pick from.
public struct TemplateOffer: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public var id: String
        public var description: String
        public var slots: [String]
        public var hasStack: Bool
    }

    public var displayID: Int
    public var options: [Option]
}

/// What the model returns per display.
public struct TemplateAssignment: Codable, Equatable, Sendable {
    public var slot: String
    public var window: Int

    public init(slot: String, window: Int) {
        self.slot = slot
        self.window = window
    }
}

public struct DisplayChoice: Codable, Equatable, Sendable {
    public var id: Int
    public var template: String
    public var slots: [TemplateAssignment]
    public var stack: [Int]
    public var cascade: [Int]

    public init(id: Int, template: String, slots: [TemplateAssignment], stack: [Int] = [], cascade: [Int] = []) {
        self.id = id
        self.template = template
        self.slots = slots
        self.stack = stack
        self.cascade = cascade
    }

    private enum CodingKeys: String, CodingKey { case id, template, slots, stack, cascade }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? ""
        slots = try c.decodeIfPresent([TemplateAssignment].self, forKey: .slots) ?? []
        stack = try c.decodeIfPresent([Int].self, forKey: .stack) ?? []
        cascade = try c.decodeIfPresent([Int].self, forKey: .cascade) ?? []
    }
}

public struct TemplatePlan: Codable, Equatable, Sendable {
    public var summary: String
    public var notes: String
    public var displays: [DisplayChoice]

    public init(summary: String, notes: String, displays: [DisplayChoice]) {
        self.summary = summary
        self.notes = notes
        self.displays = displays
    }
}

public enum LayoutTemplates {
    // MARK: Catalog

    private static func stack(_ share: Double) -> TemplateColumn { TemplateColumn(share: share, isStack: true) }
    private static func column(_ share: Double, _ slots: [TemplateSlot]) -> TemplateColumn { TemplateColumn(share: share, slots: slots) }
    private static func single(_ share: Double, _ id: String) -> TemplateColumn { TemplateColumn(share: share, slots: [TemplateSlot(id)]) }

    /// Ultrawide and 4K displays (3000 points and wider). The eyes rest at the center, so the focal window lives there;
    /// relevance falls off with distance, and the far right edge is a stack for everything else (Bi & Balakrishnan 2009).
    public static let wide: [LayoutTemplate] = [
        LayoutTemplate(id: "wide-center", description: "Main window in the center; two rows on each side for what the task needs (left) and for awareness apps (right); everything else stacked at the right edge",
                       columns: [column(0.24, [TemplateSlot("left-top"), TemplateSlot("left-bottom")]), single(0.44, "main"), column(0.22, [TemplateSlot("right-top"), TemplateSlot("right-bottom")]), stack(0.10)]),
        LayoutTemplate(id: "wide-two-main", description: "Two main windows side by side in the middle (main, second), a two-row column on the left, the rest stacked at the right edge",
                       columns: [column(0.2, [TemplateSlot("left-top"), TemplateSlot("left-bottom")]), single(0.34, "main"), single(0.34, "second"), stack(0.12)]),
        LayoutTemplate(id: "wide-main-left", description: "Classic master/stack: large main window on the left, a two-row column beside it, the rest stacked at the right edge",
                       columns: [single(0.5, "main"), column(0.28, [TemplateSlot("side-top"), TemplateSlot("side-bottom")]), stack(0.22)]),
        LayoutTemplate(id: "wide-3col", description: "Three equal columns with main in the middle, no stack",
                       columns: [single(1, "left"), single(1, "main"), single(1, "right")]),
        LayoutTemplate(id: "wide-monocle", description: "One big centered-feeling main window, the rest stacked at the right edge",
                       columns: [single(0.8, "main"), stack(0.2)]),
    ]

    /// Ordinary desktop displays (1600 to 3000 points): master/stack layouts.
    public static let standard: [LayoutTemplate] = [
        LayoutTemplate(id: "std-main-side", description: "Main window on the left (60%), two rows on the right for what the task needs",
                       columns: [single(0.6, "main"), column(0.4, [TemplateSlot("side-top"), TemplateSlot("side-bottom")])]),
        LayoutTemplate(id: "std-main-side-stack", description: "Main window, a side column with two rows, and a stack at the right edge",
                       columns: [single(0.5, "main"), column(0.3, [TemplateSlot("side-top"), TemplateSlot("side-bottom")]), stack(0.2)]),
        LayoutTemplate(id: "std-center", description: "Main window in the center with one window on each side",
                       columns: [single(0.22, "left"), single(0.56, "main"), single(0.22, "right")]),
        LayoutTemplate(id: "std-2col", description: "Two equal columns",
                       columns: [single(1, "main"), single(1, "second")]),
        LayoutTemplate(id: "std-monocle", description: "One window fills the display, the rest stacked at the right edge",
                       columns: [single(0.8, "main"), stack(0.2)]),
    ]

    /// Laptop displays (under 1600 points): at most two regions and no stack strip. A strip on a laptop leaves the
    /// tiles too narrow and shows only unreadable slivers; background windows wait fully hidden behind the tiles.
    public static let small: [LayoutTemplate] = [
        LayoutTemplate(id: "small-monocle", description: "The main window fills the display; everything else waits hidden behind it",
                       columns: [single(1, "main")]),
        LayoutTemplate(id: "small-2col", description: "Two columns, main on the left (55%), a second window on the right; everything else hidden behind",
                       columns: [single(0.55, "main"), single(0.45, "second")]),
        LayoutTemplate(id: "small-main-side", description: "Main window (65%) with a narrow companion on the right such as chat or a terminal; everything else hidden behind",
                       columns: [single(0.65, "main"), single(0.35, "side")]),
    ]

    public static func candidates(for display: DisplayInfo) -> [LayoutTemplate] {
        let width = display.visibleFrame.width
        if width >= 3000 { return wide }
        if width >= 1600 { return standard }
        return small
    }

    public static func template(id: String) -> LayoutTemplate? {
        (wide + standard + small).first { $0.id == id }
    }

    public static func offers(for request: LayoutRequest) -> [TemplateOffer] {
        request.displays.map { display in
            TemplateOffer(displayID: display.id, options: candidates(for: display).map {
                TemplateOffer.Option(id: $0.id, description: $0.description, slots: $0.slotIDs, hasStack: $0.hasStack)
            })
        }
    }

    // MARK: Readability

    /// Narrowest slot in which a window of this kind is still usable (DuoZone's finding: the model happily squeezes
    /// browsers and editors into slots that are too narrow; sizing needs a hard constraint, not a prompt).
    public static func minimumWidth(for kind: AppKind) -> CGFloat {
        switch kind {
        case .browser: 640
        // Terminals and assistants are fine in a 1920-wide display's side column (576 points); editors still get main.
        case .coding: 520
        case .chat, .files, .other, .media: 300
        }
    }

    // MARK: Reusing a plan

    /// Stored window keys ("bundleID|title") to the ids of the windows open now. Exact key first; then any window of the
    /// same app that is still unmatched, because titles change all the time (a terminal's follows the directory and the
    /// running command, a browser's follows the tab). Keys are matched in the order given, so put the important ones
    /// (main, then the other slots) first.
    public static func match(keys: [String], in windows: [WindowInfo]) -> [String: Int] {
        var result: [String: Int] = [:]
        var used = Set<Int>()
        for key in keys where result[key] == nil {
            if let window = windows.first(where: { $0.key == key && !used.contains($0.id) }) {
                result[key] = window.id
                used.insert(window.id)
            }
        }
        for key in keys where result[key] == nil {
            let bundleID = String(key.split(separator: "|", maxSplits: 1).first ?? "")
            let unmatchedKeysOfApp = keys.filter { $0.hasPrefix(bundleID + "|") && result[$0] == nil }
            // Only when it is unambiguous which stored window became which open one.
            let candidates = windows.filter { $0.bundleID == bundleID && !used.contains($0.id) }
                .sorted { ($0.lastFocusedSecondsAgo ?? .max, $0.id) < ($1.lastFocusedSecondsAgo ?? .max, $1.id) }
            if candidates.count == 1 || unmatchedKeysOfApp.count == 1, let window = candidates.first {
                result[key] = window.id
                used.insert(window.id)
            }
        }
        return result
    }

    /// Stored choices (windows as keys) expressed with the ids of the windows open now; windows that are gone drop out.
    public static func choices(fromKeys stored: [(display: Int, template: String, slots: [(slot: String, key: String)], stack: [String], cascade: [String])], in windows: [WindowInfo]) -> [DisplayChoice] {
        let ordered = stored.flatMap { d in d.slots.sorted { ($0.slot == "main" ? 0 : 1) < ($1.slot == "main" ? 0 : 1) }.map(\.key) }
            + stored.flatMap { $0.stack + $0.cascade }
        let idOf = match(keys: ordered, in: windows)
        return stored.map { d in
            DisplayChoice(
                id: d.display, template: d.template,
                slots: d.slots.compactMap { s in idOf[s.key].map { TemplateAssignment(slot: s.slot, window: $0) } },
                stack: d.stack.compactMap { idOf[$0] },
                cascade: d.cascade.compactMap { idOf[$0] }
            )
        }
    }

    /// Choices made for one snapshot, re-expressed for another. Window ids are only stable within one snapshot.
    public static func translate(_ choices: [DisplayChoice], from old: [WindowInfo], to new: [WindowInfo]) -> [DisplayChoice] {
        let keyOf = Dictionary(old.map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        let stored = choices.map { c in
            (display: c.id, template: c.template,
             slots: c.slots.compactMap { a in keyOf[a.window].map { (slot: a.slot, key: $0) } },
             stack: c.stack.compactMap { keyOf[$0] },
             cascade: c.cascade.compactMap { keyOf[$0] })
        }
        return LayoutTemplates.choices(fromKeys: stored, in: new)
    }

    /// When a window does not fit the slot it is in (a browser swapped next to main on a laptop), switch to a sibling
    /// template of the same shape whose slots are wide enough, instead of letting it fall into the background.
    /// Slots map by position. Keeps the choice as it is when it fits, or when no sibling does better.
    public static func fitted(_ choice: DisplayChoice, for request: LayoutRequest) -> DisplayChoice {
        guard let display = request.displays.first(where: { $0.id == choice.id }),
              let current = template(id: choice.template) else { return choice }
        let kindOf = Dictionary(request.windows.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        func shape(_ t: LayoutTemplate) -> [Int] { t.columns.filter { !$0.isStack }.map(\.slots.count) }
        func misfits(_ t: LayoutTemplate, _ slots: [TemplateAssignment]) -> Int {
            let total = t.columns.map(\.share).reduce(0, +)
            var count = 0
            for column in t.columns where !column.isStack {
                let width = display.visibleFrame.width * CGFloat(column.share / total)
                for slot in column.slots {
                    guard let id = slots.first(where: { $0.slot == slot.id })?.window, let kind = kindOf[id] else { continue }
                    if width < minimumWidth(for: kind) { count += 1 }
                }
            }
            return count
        }
        let original = misfits(current, choice.slots)
        guard original > 0 else { return choice }
        var best = (choice, original)
        for sibling in candidates(for: display) where sibling.id != current.id && shape(sibling) == shape(current) && sibling.hasStack == current.hasStack {
            let rename = Dictionary(uniqueKeysWithValues: zip(current.slotIDs, sibling.slotIDs))
            var candidate = choice
            candidate.template = sibling.id
            candidate.slots = choice.slots.compactMap { a in rename[a.slot].map { TemplateAssignment(slot: $0, window: a.window) } }
            let score = misfits(sibling, candidate.slots)
            if score < best.1 { best = (candidate, score) }
        }
        return best.0
    }

    /// The whole local pipeline from the model's choice to frames, using the request's current focus. Run at apply time,
    /// so a plan computed earlier (pre-warmed while another window had focus) still puts the focused window in main.
    public static func plan(from choice: TemplatePlan, for request: LayoutRequest) -> LayoutPlan {
        var plan = LayoutComposer.plan(from: design(from: choice, for: request), for: request)
        plan.choices = choice.displays
        return plan
    }

    // MARK: Stability and promotion

    /// Swap the focused window into "main" of the display's last choice. This is the "bring a peripheral app into the
    /// focal region" operation; people use the app there briefly and then go back (Bi & Balakrishnan 2009), so the
    /// window that was main stays in view:
    /// - focused window was in a slot: it and the old main trade places;
    /// - focused window was in the background: the old main takes the slot nearest to main, and whatever sat there
    ///   goes to the front of the background.
    public static func promoted(_ choice: DisplayChoice, focusedID: Int) -> DisplayChoice {
        var result = choice
        guard let mainIndex = result.slots.firstIndex(where: { $0.slot == "main" }) else { return result }
        if result.slots[mainIndex].window == focusedID { return result }
        let previousMain = result.slots[mainIndex].window
        result.slots[mainIndex].window = focusedID
        if let oldIndex = result.slots.firstIndex(where: { $0.window == focusedID && $0.slot != "main" }) {
            result.slots[oldIndex].window = previousMain
            return result
        }
        result.stack.removeAll { $0 == focusedID }
        result.cascade.removeAll { $0 == focusedID }
        guard let nearest = template(id: choice.template).flatMap(nearestSlotToMain) else {
            result.stack.insert(previousMain, at: 0)
            return result
        }
        if let occupied = result.slots.firstIndex(where: { $0.slot == nearest }) {
            result.stack.insert(result.slots[occupied].window, at: 0)
            result.slots[occupied].window = previousMain
        } else {
            result.slots.append(TemplateAssignment(slot: nearest, window: previousMain))
        }
        return result
    }

    /// The slot next to main: "second" when the template has one, otherwise the top slot of the closest column,
    /// the left one on a tie (the side for what the task needs).
    static func nearestSlotToMain(in template: LayoutTemplate) -> String? {
        if template.slotIDs.contains("second") { return "second" }
        guard let mainColumn = template.columns.firstIndex(where: { $0.slots.contains { $0.id == "main" } }) else { return nil }
        return template.columns.indices
            .filter { $0 != mainColumn && !template.columns[$0].isStack && !template.columns[$0].slots.isEmpty }
            .min { (abs($0 - mainColumn), $0) < (abs($1 - mainColumn), $1) }
            .map { template.columns[$0].slots[0].id }
    }

    // MARK: Filling a template

    /// Turns the model's choice into a design. Rules enforced here: the focused window takes "main"; empty slots collapse
    /// (a column with no windows gives its width to the others); fixed-size windows cascade; the composer then covers
    /// anything still unassigned.
    public static func design(from plan: TemplatePlan, for request: LayoutRequest) -> LayoutDesign {
        var displays: [DisplayDesign] = []
        for choice in plan.displays {
            guard let display = request.displays.first(where: { $0.id == choice.id }) else { continue }
            let template = template(id: choice.template) ?? candidates(for: display).first!
            let onDisplay = Set(request.windows.filter { $0.displayID == display.id }.map(\.id))

            var assigned: [String: Int] = [:]
            var used = Set<Int>()
            for assignment in choice.slots where onDisplay.contains(assignment.window) && !used.contains(assignment.window) && template.slotIDs.contains(assignment.slot) {
                if assigned[assignment.slot] == nil {
                    assigned[assignment.slot] = assignment.window
                    used.insert(assignment.window)
                }
            }
            // The focused window owns "main" (or the first slot) whatever the model said.
            if let focused = request.focusedWindowID, onDisplay.contains(focused), let mainSlot = template.slotIDs.first(where: { $0 == "main" }) ?? template.slotIDs.first {
                if assigned[mainSlot] != focused {
                    if let previousSlot = assigned.first(where: { $0.value == focused })?.key { assigned[previousSlot] = assigned[mainSlot] }
                    assigned[mainSlot] = focused
                    used.insert(focused)
                }
            }

            // Readability: a slot narrower than the window kind can use sends that window to the stack instead,
            // except the focused window, which keeps its slot. Widths are estimated from the full template.
            let kindOf = Dictionary(request.windows.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
            let totalShare = template.columns.map(\.share).reduce(0, +)
            var demoted: [Int] = []
            for column in template.columns where !column.isStack {
                let width = display.visibleFrame.width * CGFloat(column.share / totalShare)
                for slot in column.slots {
                    guard let id = assigned[slot.id], id != request.focusedWindowID, let kind = kindOf[id] else { continue }
                    if width < minimumWidth(for: kind) {
                        assigned[slot.id] = nil
                        demoted.append(id)
                    }
                }
            }

            var columns: [ColumnDesign] = []
            var stackShare: Double?
            for column in template.columns {
                if column.isStack {
                    stackShare = column.share
                    continue
                }
                let slots = column.slots.compactMap { slot -> WindowSlot? in
                    guard let id = assigned[slot.id] else { return nil }
                    return WindowSlot(id: id, share: slot.share)
                }
                if !slots.isEmpty { columns.append(ColumnDesign(share: column.share, windows: slots)) }
            }

            // The plan's own stack order stands (after Bring to Main the old main window must stay first, one click
            // away); windows that did not fit their slot follow it.
            used.subtract(demoted)
            let stack = (choice.stack + demoted).filter { onDisplay.contains($0) && !used.contains($0) }
            used.formUnion(stack)
            let cascade = choice.cascade.filter { onDisplay.contains($0) && !used.contains($0) }
            displays.append(DisplayDesign(
                id: display.id, columns: columns, peek: stack, cascade: cascade,
                peekWidthShare: template.hasStack ? stackShare : nil,
                // A template without a stack column gets no strip: its widths, readability included, stay as designed.
                hideBackground: !template.hasStack
            ))
        }
        return LayoutDesign(summary: plan.summary, notes: plan.notes, displays: displays, enforceFocusedSize: false)
    }
}
