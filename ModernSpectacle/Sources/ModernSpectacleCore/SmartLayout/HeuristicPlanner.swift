import CoreGraphics
import Foundation

/// Offline fallback: coding tools on the left, browsers and chat on the right, file windows cascaded in a corner.
/// Deterministic so it can be tested; the model planner is expected to do better.
public struct HeuristicPlanner: LayoutPlanner {
    public let name = "heuristic"
    public var codingShare: CGFloat

    public init(codingShare: CGFloat = 0.6) {
        self.codingShare = codingShare
    }

    public func plan(_ request: LayoutRequest) async throws -> LayoutPlan {
        planNow(request)
    }

    public func planNow(_ request: LayoutRequest) -> LayoutPlan {
        var placements: [Placement] = []

        for display in request.displays {
            let windows = request.windows.filter { $0.displayID == display.id }
            placements += layout(windows, in: display.visibleFrame, styles: request.appStyles)
        }

        let groups = Set(placements.map(\.group)).sorted().joined(separator: ", ")
        return LayoutPlan(
            summary: placements.isEmpty ? L("Nothing to arrange", "没有可排列的窗口") : L("Arranged \(placements.count) windows: \(groups)", "已排列 \(placements.count) 个窗口：\(groups)"),
            notes: request.notes,
            placements: placements
        )
    }

    private func layout(_ windows: [WindowInfo], in frame: CGRect, styles: [String: ArrangementStyle]) -> [Placement] {
        let coding = windows.filter { $0.kind == .coding }
        let side = windows.filter { $0.kind == .browser || $0.kind == .chat }
        // File windows cascade unless the user has shown they tile them; tiled file windows join the main grid.
        let files = windows.filter { $0.kind == .files }
        let cascadingFiles = files.filter { styles[$0.bundleID] != .tiled }
        let tiledFiles = files.filter { styles[$0.bundleID] == .tiled }

        var placements: [Placement] = []
        let gap: CGFloat = 8
        let main = coding + tiledFiles

        switch (main.isEmpty, side.isEmpty) {
        case (false, false):
            let codingWidth = (frame.width * codingShare).rounded()
            let left = CGRect(x: frame.minX, y: frame.minY, width: codingWidth - gap / 2, height: frame.height)
            let right = CGRect(x: frame.minX + codingWidth + gap / 2, y: frame.minY, width: frame.width - codingWidth - gap / 2, height: frame.height)
            placements += grid(main, in: left, group: "coding", gap: gap)
            placements += grid(side, in: right, group: "reference", gap: gap)
        case (false, true):
            placements += grid(main, in: frame, group: "coding", gap: gap)
        case (true, false):
            placements += grid(side, in: frame, group: "reference", gap: gap)
        case (true, true):
            break
        }

        placements += cascade(cascadingFiles, in: frame, group: "files")
        return placements
    }

    /// Focused window first, then most recently used apps.
    private func grid(_ windows: [WindowInfo], in frame: CGRect, group: String, gap: CGFloat) -> [Placement] {
        let ordered = windows.sorted { lhs, rhs in
            if lhs.isFocused != rhs.isFocused { return lhs.isFocused }
            return (lhs.appActiveSecondsAgo ?? .max) < (rhs.appActiveSecondsAgo ?? .max)
        }
        let frames = ArrangementAnalyzer.tileFrames(count: ordered.count, in: frame, gap: gap)
        return zip(ordered, frames).map { Placement(id: $0.id, group: group, rect: $1) }
    }

    private func cascade(_ windows: [WindowInfo], in frame: CGRect, group: String) -> [Placement] {
        let frames = ArrangementAnalyzer.cascadeFrames(count: windows.count, in: frame)
        return zip(windows, frames).map { Placement(id: $0.id, group: group, rect: $1) }
    }
}
