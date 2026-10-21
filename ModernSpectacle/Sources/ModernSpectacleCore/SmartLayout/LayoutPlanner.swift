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
            let rect = clamp(placement.rect, into: display.visibleFrame)
            placements.append(Placement(id: placement.id, group: placement.group, rect: rect))
        }

        return LayoutPlan(summary: plan.summary, notes: plan.notes, placements: placements)
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
