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

    /// Laptop displays (under 1600 points).
    public static let small: [LayoutTemplate] = [
        LayoutTemplate(id: "small-monocle", description: "One window fills the display, the rest stacked at the right edge",
                       columns: [single(0.82, "main"), stack(0.18)]),
        LayoutTemplate(id: "small-2col", description: "Two columns, main on the left",
                       columns: [single(0.55, "main"), single(0.45, "second")]),
        LayoutTemplate(id: "small-main-stack", description: "Main window with the rest stacked on the right",
                       columns: [single(0.7, "main"), stack(0.3)]),
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
        case .coding, .browser: 640
        case .chat, .files, .other, .media: 300
        }
    }

    // MARK: Stability and promotion

    /// Swap the focused window into "main" of the display's last choice, sending the previous main window to the
    /// focused window's old slot (or the stack). This is the "bring a peripheral app into the focal region" operation.
    public static func promoted(_ choice: DisplayChoice, focusedID: Int) -> DisplayChoice {
        var result = choice
        guard let mainIndex = result.slots.firstIndex(where: { $0.slot == "main" }) else { return result }
        if result.slots[mainIndex].window == focusedID { return result }
        let previousMain = result.slots[mainIndex].window
        if let oldIndex = result.slots.firstIndex(where: { $0.window == focusedID }) {
            result.slots[oldIndex].window = previousMain
        } else {
            result.stack.removeAll { $0 == focusedID }
            result.cascade.removeAll { $0 == focusedID }
            result.stack.insert(previousMain, at: 0)
        }
        result.slots[mainIndex].window = focusedID
        return result
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

            used.subtract(demoted)
            let stack = (demoted + choice.stack).filter { onDisplay.contains($0) && !used.contains($0) }
            used.formUnion(stack)
            let cascade = choice.cascade.filter { onDisplay.contains($0) && !used.contains($0) }
            displays.append(DisplayDesign(id: display.id, columns: columns, peek: stack, cascade: cascade, peekWidthShare: template.hasStack ? stackShare : nil))
        }
        return LayoutDesign(summary: plan.summary, notes: plan.notes, displays: displays, enforceFocusedSize: false)
    }
}
