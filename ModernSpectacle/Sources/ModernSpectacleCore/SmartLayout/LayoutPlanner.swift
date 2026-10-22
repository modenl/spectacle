import CoreGraphics
import Foundation

public protocol LayoutPlanner: Sendable {
    var name: String { get }
    func plan(_ request: LayoutRequest) async throws -> LayoutPlan
}

/// Makes any plan safe to apply: known windows only, kept on the display they are already on, not smaller than a usable window.
public enum PlanValidator {
    public static let minimumSize = CGSize(width: 240, height: 160)

    public static func sanitized(_ plan: LayoutPlan, for request: LayoutRequest) -> LayoutPlan {
        let windowsByID = Dictionary(request.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int>()
        var placements: [Placement] = []

        for placement in plan.placements {
            guard let window = windowsByID[placement.id], !seen.contains(placement.id) else {
                continue
            }
            seen.insert(placement.id)

            // Each display is laid out on its own; a window never gets pulled to another display.
            guard let display = request.displays.first(where: { $0.id == window.displayID }) ?? request.displays.first else {
                continue
            }
            var rect = clamp(placement.rect, into: display.visibleFrame)
            if !window.resizable {
                // Keep the window's own size; only its position is ours to change.
                rect.size = window.frame.cgRect.size
                rect = clamp(rect, into: display.visibleFrame)
                rect.size = window.frame.cgRect.size
            }
            placements.append(Placement(id: placement.id, group: placement.group, rect: rect))
        }

        return LayoutPlan(summary: plan.summary, notes: plan.notes, placements: placements, choices: plan.choices)
    }

    /// Windows the planner left out (typically a whole display it ignored) are tiled in a grid; fixed-size ones are
    /// stacked in the corner. Every window ends up handled.
    public static func completed(_ plan: LayoutPlan, for request: LayoutRequest) -> LayoutPlan {
        let placed = Set(plan.placements.map(\.id))
        var placements = plan.placements
        for display in request.displays {
            let leftovers = request.windows.filter { $0.displayID == display.id && !placed.contains($0.id) }
            let tiled = leftovers.filter(\.resizable)
            let fixed = leftovers.filter { !$0.resizable }
            let frames = ArrangementAnalyzer.tileFrames(count: tiled.count, in: display.visibleFrame, gap: 0)
            placements += zip(tiled, frames).map { Placement(id: $0.id, group: "background", rect: $1) }
            let cascade = ArrangementAnalyzer.cascadeFrames(sizes: fixed.map { $0.frame.cgRect.size }, in: display.visibleFrame)
            placements += zip(fixed, cascade).map { Placement(id: $0.id, group: "background", rect: $1) }
        }
        return LayoutPlan(summary: plan.summary, notes: plan.notes, placements: placements, choices: plan.choices)
    }

    static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var width = min(max(rect.width, minimumSize.width), bounds.width)
        var height = min(max(rect.height, minimumSize.height), bounds.height)
        width = width.rounded()
        height = height.rounded()

        var x = rect.minX.rounded()
        var y = rect.minY.rounded()
        x = min(max(x, bounds.minX), bounds.maxX - width)
        y = min(max(y, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
