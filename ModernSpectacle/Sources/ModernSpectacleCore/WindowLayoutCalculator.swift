import CoreGraphics
import Foundation

public struct WindowLayoutCalculator: Sendable {
    public init() {}

    public func rect(
        for action: WindowAction,
        currentWindow: CGRect,
        sourceVisibleFrame: CGRect,
        destinationVisibleFrame: CGRect
    ) -> CGRect? {
        let targetFrame = action.usesDestinationDisplay ? destinationVisibleFrame : sourceVisibleFrame

        switch action {
        case .center:
            return centered(currentWindow.size, in: targetFrame)
        case .maximize:
            return targetFrame.integral
        case .leftHalf:
            return cyclingSide(.left, currentWindow: currentWindow, screen: targetFrame)
        case .rightHalf:
            return cyclingSide(.right, currentWindow: currentWindow, screen: targetFrame)
        case .topHalf:
            return CGRect(
                x: targetFrame.minX,
                y: targetFrame.minY,
                width: targetFrame.width,
                height: targetFrame.height / 2
            ).integral
        case .bottomHalf:
            return CGRect(
                x: targetFrame.minX,
                y: targetFrame.midY,
                width: targetFrame.width,
                height: targetFrame.height / 2
            ).integral
        case .upperLeft:
            return quadrant(x: .min, y: .min, in: targetFrame)
        case .lowerLeft:
            return quadrant(x: .min, y: .max, in: targetFrame)
        case .upperRight:
            return quadrant(x: .max, y: .min, in: targetFrame)
        case .lowerRight:
            return quadrant(x: .max, y: .max, in: targetFrame)
        case .nextThird:
            return adjacentThird(after: currentWindow, in: targetFrame, direction: .forward)
        case .previousThird:
            return adjacentThird(after: currentWindow, in: targetFrame, direction: .backward)
        case .nextDisplay, .previousDisplay:
            let size = CGSize(
                width: min(currentWindow.width, destinationVisibleFrame.width),
                height: min(currentWindow.height, destinationVisibleFrame.height)
            )
            return centered(size, in: destinationVisibleFrame)
        case .larger:
            return resized(currentWindow, in: targetFrame, scale: 1.10)
        case .smaller:
            return resized(currentWindow, in: targetFrame, scale: 0.90)
        case .undo, .redo, .smartArrange:
            return nil
        }
    }

    private func centered(_ size: CGSize, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: min(size.width, frame.width),
            height: min(size.height, frame.height)
        )
        .standardized
        .intersection(frame)
        .integral
    }

    private enum HorizontalSide {
        case left
        case right
    }

    private func cyclingSide(_ side: HorizontalSide, currentWindow: CGRect, screen: CGRect) -> CGRect {
        let half = sideRect(side, fraction: 1.0 / 2.0, in: screen)
        let oneThird = sideRect(side, fraction: 1.0 / 3.0, in: screen)
        let twoThirds = sideRect(side, fraction: 2.0 / 3.0, in: screen)

        if currentWindow.approximatelyEquals(half) {
            return oneThird
        }
        if currentWindow.approximatelyEquals(oneThird) {
            return twoThirds
        }
        return half
    }

    private func sideRect(_ side: HorizontalSide, fraction: CGFloat, in screen: CGRect) -> CGRect {
        let width = screen.width * fraction
        let x = side == .left ? screen.minX : screen.maxX - width
        return CGRect(x: x, y: screen.minY, width: width, height: screen.height).integral
    }

    private enum Edge {
        case min
        case max
    }

    private func quadrant(x: Edge, y: Edge, in screen: CGRect) -> CGRect {
        CGRect(
            x: x == .min ? screen.minX : screen.midX,
            y: y == .min ? screen.minY : screen.midY,
            width: screen.width / 2,
            height: screen.height / 2
        ).integral
    }

    private enum Direction {
        case forward
        case backward
    }

    private func adjacentThird(after currentWindow: CGRect, in screen: CGRect, direction: Direction) -> CGRect {
        let thirds = [
            CGRect(x: screen.minX, y: screen.minY, width: screen.width / 3, height: screen.height),
            CGRect(x: screen.minX + screen.width / 3, y: screen.minY, width: screen.width / 3, height: screen.height),
            CGRect(x: screen.minX + 2 * screen.width / 3, y: screen.minY, width: screen.width / 3, height: screen.height),
            CGRect(x: screen.minX, y: screen.minY, width: 2 * screen.width / 3, height: screen.height),
            CGRect(x: screen.minX + screen.width / 3, y: screen.minY, width: 2 * screen.width / 3, height: screen.height)
        ].map(\.integral)

        let currentIndex = thirds.firstIndex { currentWindow.approximatelyEquals($0) } ?? 0
        let delta = direction == .forward ? 1 : -1
        let nextIndex = (currentIndex + delta + thirds.count) % thirds.count
        return thirds[nextIndex]
    }

    private func resized(_ currentWindow: CGRect, in screen: CGRect, scale: CGFloat) -> CGRect {
        let newWidth = min(max(currentWindow.width * scale, screen.width / 8), screen.width)
        let newHeight = min(max(currentWindow.height * scale, screen.height / 8), screen.height)

        return centered(CGSize(width: newWidth, height: newHeight), in: screen)
    }
}

private extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 1.5) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance &&
            abs(origin.y - other.origin.y) <= tolerance &&
            abs(size.width - other.size.width) <= tolerance &&
            abs(size.height - other.size.height) <= tolerance
    }
}
