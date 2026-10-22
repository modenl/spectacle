import CoreGraphics
import Foundation

/// What the model returns: not pixels, but a structure. Columns left to right with relative widths, windows top to bottom
/// inside each column with relative heights, and windows to cascade in a corner. The composer turns it into exact frames.
public struct WindowSlot: Codable, Equatable, Sendable {
    public var id: Int
    public var share: Double

    public init(id: Int, share: Double) {
        self.id = id
        self.share = share
    }
}

public struct ColumnDesign: Codable, Equatable, Sendable {
    public var share: Double
    public var windows: [WindowSlot]

    public init(share: Double, windows: [WindowSlot]) {
        self.share = share
        self.windows = windows
    }
}

public struct DisplayDesign: Codable, Equatable, Sendable {
    public var id: Int
    public var columns: [ColumnDesign]
    /// Windows kept large behind the tiles with a strip showing at the right edge; most useful first (ends up on top).
    public var peek: [Int]
    public var cascade: [Int]
    /// Width of the stack column as a share of the column shares; nil means the default narrow strip.
    public var peekWidthShare: Double?

    public init(id: Int, columns: [ColumnDesign], peek: [Int] = [], cascade: [Int], peekWidthShare: Double? = nil) {
        self.id = id
        self.columns = columns
        self.peek = peek
        self.cascade = cascade
        self.peekWidthShare = peekWidthShare
    }

    private enum CodingKeys: String, CodingKey { case id, columns, peek, cascade, peekWidthShare }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        columns = try c.decodeIfPresent([ColumnDesign].self, forKey: .columns) ?? []
        peek = try c.decodeIfPresent([Int].self, forKey: .peek) ?? []
        cascade = try c.decodeIfPresent([Int].self, forKey: .cascade) ?? []
        peekWidthShare = try c.decodeIfPresent(Double.self, forKey: .peekWidthShare)
    }
}

public struct LayoutDesign: Codable, Equatable, Sendable {
    public var summary: String
    public var notes: String
    public var displays: [DisplayDesign]
    /// Free-form designs get the focused window enlarged; template designs already place it, so their proportions stand.
    public var enforceFocusedSize: Bool

    public init(summary: String, notes: String, displays: [DisplayDesign], enforceFocusedSize: Bool = true) {
        self.summary = summary
        self.notes = notes
        self.displays = displays
        self.enforceFocusedSize = enforceFocusedSize
    }
}

public enum LayoutComposer {
    /// Width of the strip at the right edge where peeking windows stay visible.
    public static func peekStripWidth(for frame: CGRect) -> CGFloat {
        min(max(frame.width * 0.08, 180), 280).rounded()
    }

    /// Frames for the peek stack: large windows flush with the right edge, staggered so each title bar shows in the strip.
    /// `windows` is most-useful-first; the most useful one sits lowest (and on top), the rest show above it.
    public static func peekFrames(count: Int, in frame: CGRect, stripWidth: CGFloat? = nil) -> [CGRect] {
        guard count > 0 else { return [] }
        // Wide enough to be useful once clicked; at least the strip, and never more than half the display.
        let width = min(max(stripWidth ?? 0, min(frame.width * 0.5, 1100)), frame.width).rounded()
        let height = min(frame.height * 0.7, 820).rounded()
        let step: CGFloat = 36
        return (0..<count).map { index in
            // index 0 is the most useful window: it sits lowest and in front; the ones behind show their title bars above it.
            let y = min(frame.minY + step * CGFloat(count - 1 - index), frame.maxY - height)
            return CGRect(x: frame.maxX - width, y: max(frame.minY, y), width: width, height: height).integral
        }
    }

    /// Exact frames from a design. Windows named for a display they are not on, unknown ids and duplicates are dropped;
    /// `PlanValidator.completed` later covers anything left out.
    public static func plan(from design: LayoutDesign, for request: LayoutRequest, gap: CGFloat = 0) -> LayoutPlan {
        let displayOf = Dictionary(request.windows.map { ($0.id, $0.displayID) }, uniquingKeysWith: { a, _ in a })
        let windowOf = Dictionary(request.windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<Int>()
        var placements: [Placement] = []

        for displayDesign in design.displays {
            guard let display = request.displays.first(where: { $0.id == displayDesign.id }) else { continue }
            let frame = display.visibleFrame

            func claim(_ id: Int) -> Bool {
                guard displayOf[id] == display.id, !used.contains(id) else { return false }
                used.insert(id)
                return true
            }

            // Fixed-size windows cannot tile; they always go to the corner stack at their own size.
            var cascadeIDs: [Int] = []
            var columns = displayDesign.columns
                .map { column in
                    ColumnDesign(share: max(column.share, 0.01), windows: column.windows.filter { slot in
                        guard claim(slot.id) else { return false }
                        if windowOf[slot.id]?.resizable == false { cascadeIDs.append(slot.id); return false }
                        return true
                    })
                }
                .filter { !$0.windows.isEmpty }

            // Only fixed-size windows, file browsers and apps the person stacks by habit may sit in the corner stack.
            // Everything else the design put there, and every window it forgot, joins the emptiest column.
            func addToEmptiestColumn(_ id: Int) {
                if columns.isEmpty { columns.append(ColumnDesign(share: 1, windows: [])) }
                let target = columns.indices.min { columns[$0].windows.count < columns[$1].windows.count }!
                columns[target].windows.append(WindowSlot(id: id, share: 1))
            }
            func mayCascade(_ id: Int) -> Bool {
                guard let window = windowOf[id] else { return false }
                if !window.resizable { return true }
                let style = request.appStyles[window.bundleID]
                if style == .cascaded { return true }
                if style == .tiled { return false }
                return window.kind == .files
            }
            for id in displayDesign.cascade where claim(id) {
                if mayCascade(id) { cascadeIDs.append(id) } else { addToEmptiestColumn(id) }
            }
            // Peek: open but unimportant windows stay big behind the tiles with an edge showing. Never the focused one.
            var peekIDs: [Int] = []
            for id in displayDesign.peek where claim(id) {
                if windowOf[id]?.resizable == false { cascadeIDs.append(id) }
                else if id == request.focusedWindowID { addToEmptiestColumn(id) }
                else { peekIDs.append(id) }
            }
            // Anything the design forgot: fixed-size to the corner, otherwise it peeks (it is background by definition),
            // unless nothing is tiled yet, in which case it becomes the tile.
            for window in request.windows where window.displayID == display.id && claim(window.id) {
                if !window.resizable { cascadeIDs.append(window.id) }
                else if columns.isEmpty { addToEmptiestColumn(window.id) }
                else { peekIDs.append(window.id) }
            }
            var stripWidth = peekStripWidth(for: frame)
            if let share = displayDesign.peekWidthShare {
                let total = columns.map(\.share).reduce(0, +) + share
                stripWidth = (frame.width * CGFloat(share / total)).rounded()
            }
            let tileFrame = peekIDs.isEmpty ? frame
                : CGRect(x: frame.minX, y: frame.minY, width: frame.width - stripWidth, height: frame.height)
            // The focused window is the center of attention: its column is the widest and it is the tallest in that column.
            if design.enforceFocusedSize, let focusedID = request.focusedWindowID,
               let c = columns.firstIndex(where: { $0.windows.contains { $0.id == focusedID } }) {
                let widest = columns.enumerated().filter { $0.offset != c }.map(\.element.share).max() ?? 0
                columns[c].share = max(columns[c].share, widest * 1.15)
                if let r = columns[c].windows.firstIndex(where: { $0.id == focusedID }) {
                    let tallest = columns[c].windows.enumerated().filter { $0.offset != r }.map(\.element.share).max() ?? 0
                    columns[c].windows[r].share = max(columns[c].windows[r].share, tallest * 1.3)
                }
            }

            let totalShare = columns.map(\.share).reduce(0, +)
            let usableWidth = tileFrame.width - gap * CGFloat(max(columns.count - 1, 0))
            var x = tileFrame.minX

            for (c, column) in columns.enumerated() {
                let isLast = c == columns.count - 1
                let width = isLast ? tileFrame.maxX - x : (CGFloat(column.share / totalShare) * usableWidth).rounded()
                let shares = column.windows.map { max($0.share, 0.01) }
                let totalHeight = shares.reduce(0, +)
                let usableHeight = tileFrame.height - gap * CGFloat(column.windows.count - 1)
                var y = tileFrame.minY
                for (r, slot) in column.windows.enumerated() {
                    let isLastRow = r == column.windows.count - 1
                    let height = isLastRow ? tileFrame.maxY - y : (CGFloat(shares[r] / totalHeight) * usableHeight).rounded()
                    placements.append(Placement(id: slot.id, group: "column\(c + 1)", rect: CGRect(x: x, y: y, width: width, height: height)))
                    y += height + gap
                }
                x += width + gap
            }

            placements += zip(peekIDs, peekFrames(count: peekIDs.count, in: frame, stripWidth: stripWidth)).map { Placement(id: $0, group: "peek", rect: $1) }

            let sizes = cascadeIDs.map { id -> CGSize in
                let window = windowOf[id]
                return window?.resizable == false ? window!.frame.cgRect.size : ArrangementAnalyzer.cascadeSize(in: frame)
            }
            let frames = ArrangementAnalyzer.cascadeFrames(sizes: sizes, in: frame)
            placements += zip(cascadeIDs, frames).map { Placement(id: $0, group: "cascade", rect: $1) }
        }

        return LayoutPlan(summary: design.summary, notes: design.notes, placements: placements)
    }
}
