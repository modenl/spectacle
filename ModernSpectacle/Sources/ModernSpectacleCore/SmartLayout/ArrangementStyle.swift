import CoreGraphics
import Foundation

/// How a set of windows of one app sits on a display. Learned per app from what the user does by hand.
public enum ArrangementStyle: String, Codable, Sendable {
    case tiled
    case cascaded
    case stacked
    case scattered
}

public enum ArrangementAnalyzer {
    /// Two windows count as neighbours when their edges meet within this distance.
    public static let adjacency: CGFloat = 24

    public static func style(of frames: [CGRect]) -> ArrangementStyle {
        guard frames.count >= 2 else { return .scattered }

        if frames.allSatisfy({ nearlyEqual($0, frames[0]) }) {
            return .stacked
        }

        if isTiled(frames) {
            return .tiled
        }

        // Cascade: ordered by origin, each window overlaps the previous one heavily and is offset in the same direction.
        let ordered = frames.sorted { ($0.minX + $0.minY) < ($1.minX + $1.minY) }
        var cascaded = true
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            let overlap = previous.intersection(next)
            let overlapShare = overlap.isNull ? 0 : overlap.area / min(previous.area, next.area)
            let offsetX = next.minX - previous.minX
            let offsetY = next.minY - previous.minY
            if overlapShare < 0.5 || offsetX < 0 || offsetY < 0 || (offsetX == 0 && offsetY == 0) {
                cascaded = false
                break
            }
        }
        return cascaded ? .cascaded : .scattered
    }

    /// Non-overlapping, and every window touches at least one other window's edge (or the group is a single row/column).
    public static func isTiled(_ frames: [CGRect]) -> Bool {
        guard frames.count >= 2 else { return false }
        for (index, a) in frames.enumerated() {
            for b in frames[(index + 1)...] {
                let overlap = a.insetBy(dx: 4, dy: 4).intersection(b.insetBy(dx: 4, dy: 4))
                if !overlap.isNull, overlap.area > 0.05 * min(a.area, b.area) {
                    return false
                }
            }
        }
        return frames.enumerated().allSatisfy { index, a in
            frames.enumerated().contains { other, b in other != index && adjacent(a, b) }
        }
    }

    static func adjacent(_ a: CGRect, _ b: CGRect) -> Bool {
        let horizontalGap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        let verticalGap = max(a.minY, b.minY) - min(a.maxY, b.maxY)
        let sharesRows = verticalGap < 0 // vertical ranges overlap
        let sharesColumns = horizontalGap < 0
        return (sharesRows && abs(horizontalGap) <= adjacency) || (sharesColumns && abs(verticalGap) <= adjacency)
    }

    /// The user tiled some windows of one app by hand while others of the same app on the same display are still elsewhere.
    /// `recentlyMoved` holds the ids of windows the user moved or resized in the last moments.
    public static func partialTiling(windows: [WindowInfo], recentlyMoved: Set<Int>) -> (tiled: [WindowInfo], remaining: [WindowInfo])? {
        let moved = windows.filter { recentlyMoved.contains($0.id) }
        guard moved.count >= 2, isTiled(moved.map(\.frame.cgRect)) else { return nil }

        // Windows already part of the tiled block count as tiled even if they were not moved this time.
        var tiled = moved
        var remaining: [WindowInfo] = []
        for window in windows where !recentlyMoved.contains(window.id) {
            if isTiled((tiled + [window]).map(\.frame.cgRect)) {
                tiled.append(window)
            } else {
                remaining.append(window)
            }
        }
        guard !remaining.isEmpty else { return nil }
        return (tiled, remaining)
    }

    /// Grid frames for `count` windows. Columns grow before rows so editors stay wide; the last window spans a short row.
    public static func tileFrames(count: Int, in frame: CGRect, gap: CGFloat = 8) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = count <= 1 ? 1 : (count <= 4 ? 2 : Int(Double(count).squareRoot().rounded(.up)))
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let cellWidth = (frame.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (frame.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

        return (0..<count).map { index in
            let column = index % columns
            let row = index / columns
            let isLastAlone = index == count - 1 && column == 0 && count % columns != 0
            return CGRect(
                x: frame.minX + CGFloat(column) * (cellWidth + gap),
                y: frame.minY + CGFloat(row) * (cellHeight + gap),
                width: isLastAlone ? frame.width : cellWidth,
                height: cellHeight
            ).integral
        }
    }

    public static func cascadeFrames(count: Int, in frame: CGRect, step: CGFloat = 28) -> [CGRect] {
        guard count > 0 else { return [] }
        let size = CGSize(width: (frame.width * 0.42).rounded(), height: (frame.height * 0.5).rounded())
        return (0..<count).map { index in
            let offset = CGFloat(index) * step
            return CGRect(x: frame.maxX - size.width - offset, y: frame.maxY - size.height - offset, width: size.width, height: size.height).integral
        }
    }

    static func nearlyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 12) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

extension CGRect {
    var area: CGFloat { max(width, 0) * max(height, 0) }
}
