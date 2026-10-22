import CoreGraphics
import Foundation

/// Classic layouts, picked per display size. The model only chooses a template and says which window goes in which
/// slot; the geometry is fixed here, so results are predictable and the model cannot invent bad proportions.
public struct TemplateSlot: Codable, Equatable, Sendable {
    public var id: String
    public var share: Double
    /// A place for windows to keep an eye on (chat, mail, monitors) rather than work in: filled with those first.
    public var awareness: Bool

    public init(_ id: String, share: Double = 1, awareness: Bool = false) {
        self.id = id
        self.share = share
        self.awareness = awareness
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

    /// Short name for the HUD while cycling templates.
    public var title: String {
        switch id {
        case "wide-1-1-n": L("Left · Main · Right column", "左1 · 中1 · 右n")
        case "wide-1-2-n": L("Left · Two main · Right column", "左1 · 中2 · 右n")
        case "wide-grid-6", "std-grid-4": L("Grid", "平铺")
        case "std-main-2", "small-main-2": L("Main · Two on the right", "左主 · 右上下")
        case "std-2col", "small-2col": L("Two columns", "左右两栏")
        case "small-monocle": L("One window", "单窗口")
        default: id
        }
    }

    /// Slots in the order they are filled: main, then by distance from main's column (left first on a tie), top to
    /// bottom. The most relevant windows end up closest to where the eyes rest.
    public var slotsByNearness: [TemplateSlot] {
        let mainColumn = columns.firstIndex { $0.slots.contains { $0.id == "main" } } ?? 0
        return columns.indices
            .filter { !columns[$0].isStack }
            .sorted { (abs($0 - mainColumn), $0) < (abs($1 - mainColumn), $1) }
            .flatMap { index in columns[index].slots.filter { $0.id == "main" } + columns[index].slots.filter { $0.id != "main" } }
    }
}

/// Which window sits in which slot of a template.
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

    // Three templates per display size, cycled by pressing M again while ⌃⌥⌘ are held. None has a stack strip:
    // windows that get no slot wait fully hidden behind the tiles. A right-hand column of awareness slots takes over
    // the strip's job of keeping chat, mail and monitors in view, readable instead of as slivers.

    /// Ultrawide and 4K displays (3000 points and wider). Main in the center, where the eyes rest
    /// (Bi & Balakrishnan 2009); the right column holds up to three awareness windows.
    public static let wide: [LayoutTemplate] = [
        LayoutTemplate(id: "wide-1-1-n", description: "Left, main in the center, a right column of up to three",
                       columns: [single(0.22, "left"), single(0.48, "main"), awarenessColumn(0.30)]),
        LayoutTemplate(id: "wide-1-2-n", description: "Left, two main windows side by side, a right column of up to three",
                       columns: [single(0.2, "left"), single(0.3, "main"), single(0.3, "second"), awarenessColumn(0.2)]),
        LayoutTemplate(id: "wide-grid-6", description: "Six windows in a 3 × 2 grid",
                       columns: [column(1, [TemplateSlot("main"), TemplateSlot("grid-4")]), column(1, [TemplateSlot("grid-2"), TemplateSlot("grid-5")]), column(1, [TemplateSlot("grid-3"), TemplateSlot("grid-6")])]),
    ]

    /// Ordinary desktop displays (1600 to 3000 points). Three columns would leave each too narrow for a browser.
    public static let standard: [LayoutTemplate] = [
        LayoutTemplate(id: "std-main-2", description: "Main on the left (60%), two windows stacked on the right",
                       columns: [single(0.6, "main"), column(0.4, [TemplateSlot("side-top"), TemplateSlot("side-bottom", awareness: true)])]),
        LayoutTemplate(id: "std-2col", description: "Two equal columns",
                       columns: [single(0.5, "main"), single(0.5, "second")]),
        LayoutTemplate(id: "std-grid-4", description: "Four windows in a 2 × 2 grid",
                       columns: [column(1, [TemplateSlot("main"), TemplateSlot("grid-3")]), column(1, [TemplateSlot("grid-2"), TemplateSlot("grid-4")])]),
    ]

    /// Laptop displays (under 1600 points): at most a main window and a right column of two.
    public static let small: [LayoutTemplate] = [
        LayoutTemplate(id: "small-main-2", description: "Main on the left (60%), two windows stacked on the right",
                       columns: [single(0.6, "main"), column(0.4, [TemplateSlot("side-top"), TemplateSlot("side-bottom", awareness: true)])]),
        LayoutTemplate(id: "small-2col", description: "Two columns, main on the left (55%)",
                       columns: [single(0.55, "main"), single(0.45, "second")]),
        LayoutTemplate(id: "small-monocle", description: "The main window fills the display",
                       columns: [single(1, "main")]),
    ]

    private static func awarenessColumn(_ share: Double) -> TemplateColumn {
        TemplateColumn(share: share, slots: (1...3).map { TemplateSlot("right-\($0)", awareness: true) })
    }

    /// Every slot of a template laid out on a display, as if all were filled: the template's shape on its own,
    /// without any windows (shown while the model is still ranking).
    public static func slotFrames(of template: LayoutTemplate, in frame: CGRect) -> [(slot: TemplateSlot, rect: CGRect)] {
        let columns = template.columns.filter { !$0.isStack }
        let total = columns.map(\.share).reduce(0, +)
        var result: [(TemplateSlot, CGRect)] = []
        var x = frame.minX
        for (index, column) in columns.enumerated() {
            let width = index == columns.count - 1 ? frame.maxX - x : (frame.width * CGFloat(column.share / total)).rounded()
            let rowTotal = column.slots.map(\.share).reduce(0, +)
            var y = frame.minY
            for (row, slot) in column.slots.enumerated() {
                let height = row == column.slots.count - 1 ? frame.maxY - y : (frame.height * CGFloat(slot.share / rowTotal)).rounded()
                result.append((slot, CGRect(x: x, y: y, width: width, height: height)))
                y += height
            }
            x += width
        }
        return result
    }

    /// The template a press starts with: the one the person chose last for this size of display, unless it has too few
    /// slots for the windows that want one (`needed`, from the local ranking, known before the model answers), in which
    /// case the smallest template that has enough, or the largest one. Returns an index into `candidates`.
    public static func startingTemplate(in candidates: [LayoutTemplate], remembered: String?, needed: Int) -> Int {
        let slots = candidates.map(\.slotIDs.count)
        let want = min(max(needed, 1), slots.max() ?? 1)
        if let index = candidates.firstIndex(where: { $0.id == remembered }), slots[index] >= want { return index }
        let fitting = slots.indices.filter { slots[$0] >= want }
        if let smallest = fitting.min(by: { (slots[$0], $0) < (slots[$1], $1) }) { return smallest }
        return slots.indices.max { slots[$0] < slots[$1] } ?? 0
    }

    /// "wide", "standard" or "small": the key under which the last template used on such a display is remembered.
    public static func sizeClass(of display: DisplayInfo) -> String {
        let width = display.visibleFrame.width
        if width >= 3000 { return "wide" }
        if width >= 1600 { return "standard" }
        return "small"
    }

    public static func candidates(for display: DisplayInfo) -> [LayoutTemplate] {
        let width = display.visibleFrame.width
        if width >= 3000 { return wide }
        if width >= 1600 { return standard }
        return small
    }

    public static func template(id: String) -> LayoutTemplate? {
        (wide + standard + small).first { $0.id == id }
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

    /// The narrowest slot this window is usable in: its kind's readability minimum, or the app's own minimum width
    /// when it refuses to get narrower than that.
    public static func readableWidth(of window: WindowInfo, in request: LayoutRequest) -> CGFloat {
        max(minimumWidth(for: window.kind), CGFloat(request.minimumWidths[window.bundleID] ?? 0))
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

    /// When a window does not fit the slot it is in (a browser swapped next to main on a laptop), switch to another
    /// template for this display where more of the important windows stay visible, instead of letting it fall into the
    /// background. Windows keep their order of importance: main, then by nearness. Keeps the choice when nothing does better.
    public static func fitted(_ choice: DisplayChoice, for request: LayoutRequest) -> DisplayChoice {
        guard let display = request.displays.first(where: { $0.id == choice.id }),
              let current = template(id: choice.template) else { return choice }
        let windowOf = Dictionary(request.windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let order = current.slotsByNearness.compactMap { slot in choice.slots.first { $0.slot == slot.id }?.window }

        /// Lower is better: each window that ends up hidden costs more the more important it is.
        func placed(in template: LayoutTemplate) -> (DisplayChoice, Int) {
            let total = template.columns.map(\.share).reduce(0, +)
            var free = template.slotsByNearness
            var slots: [TemplateAssignment] = []
            var hidden: [Int] = []
            var cost = 0
            for (position, id) in order.enumerated() {
                let fits = { (slot: TemplateSlot) -> Bool in
                    guard slot.id != "main", let window = windowOf[id] else { return true }
                    let column = template.columns.first { $0.slots.contains { $0.id == slot.id } }!
                    return display.visibleFrame.width * CGFloat(column.share / total) >= readableWidth(of: window, in: request)
                }
                if let index = free.firstIndex(where: fits) {
                    slots.append(TemplateAssignment(slot: free.remove(at: index).id, window: id))
                } else {
                    hidden.append(id)
                    cost += order.count - position
                }
            }
            var result = choice
            result.template = template.id
            result.slots = slots
            result.stack = hidden + choice.stack
            return (result, cost)
        }

        let (kept, keptCost) = placed(in: current)
        guard keptCost > 0 else { return choice }
        var best = (kept, keptCost)
        for other in candidates(for: display) where other.id != current.id {
            let (candidate, cost) = placed(in: other)
            if cost < best.1 { best = (candidate, cost) }
        }
        return best.1 < keptCost ? best.0 : choice
    }

    /// The whole local pipeline from a choice to frames, using the request's current focus.
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

    /// The slot next to main: "second" when the template has one, otherwise the first slot by nearness.
    static func nearestSlotToMain(in template: LayoutTemplate) -> String? {
        if template.slotIDs.contains("second") { return "second" }
        return template.slotsByNearness.first { $0.id != "main" }?.id
    }

    // MARK: Filling a template from a ranking

    /// The template's slots filled from the ranking: the focused window in main, then the most relevant windows in the
    /// slots nearest to it. Awareness slots take awareness windows first, other slots take task windows first; a
    /// window goes only where it is readable. Background windows and everything left over wait hidden behind.
    public static func fill(_ template: LayoutTemplate, on display: DisplayInfo, ranking: WindowRanking, request: LayoutRequest) -> DisplayChoice {
        let onDisplay = request.windows.filter { $0.displayID == display.id }
        let roleOf = Dictionary(ranking.windows.map { ($0.id, $0.role) }, uniquingKeysWith: { a, _ in a })
        let rankOf = Dictionary(ranking.windows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered = onDisplay.sorted { (rankOf[$0.id] ?? .max, $0.id) < (rankOf[$1.id] ?? .max, $1.id) }
        if let focused = request.focusedWindowID, let index = ordered.firstIndex(where: { $0.id == focused }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        let cascade = ordered.filter { !$0.resizable }.map(\.id)
        var remaining = ordered.filter { $0.resizable }
        let total = template.columns.map(\.share).reduce(0, +)
        func width(of slot: TemplateSlot) -> CGFloat {
            let column = template.columns.first { $0.slots.contains { $0.id == slot.id } }!
            return display.visibleFrame.width * CGFloat(column.share / total)
        }

        var slots: [TemplateAssignment] = []
        for slot in template.slotsByNearness {
            let fits = { (w: WindowInfo) in slot.id == "main" || width(of: slot) >= readableWidth(of: w, in: request) }
            let role = { (w: WindowInfo) in w.id == request.focusedWindowID ? .task : (roleOf[w.id] ?? .task) }
            let preferred: WindowRole = slot.awareness ? .awareness : .task
            // Main is never left empty while the display has a window: with nothing else, the most relevant one takes it.
            let pick = remaining.firstIndex { role($0) == preferred && fits($0) }
                ?? remaining.firstIndex { role($0) != .background && fits($0) }
                ?? (slot.id == "main" ? remaining.indices.first : nil)
            guard let index = pick else { continue }
            slots.append(TemplateAssignment(slot: slot.id, window: remaining.remove(at: index).id))
        }
        return DisplayChoice(id: display.id, template: template.id, slots: slots, stack: remaining.map(\.id), cascade: cascade)
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
            let windowOf = Dictionary(request.windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let totalShare = template.columns.map(\.share).reduce(0, +)
            var demoted: [Int] = []
            for column in template.columns where !column.isStack {
                let width = display.visibleFrame.width * CGFloat(column.share / totalShare)
                for slot in column.slots {
                    guard let id = assigned[slot.id], id != request.focusedWindowID, let window = windowOf[id] else { continue }
                    if width < readableWidth(of: window, in: request) {
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
