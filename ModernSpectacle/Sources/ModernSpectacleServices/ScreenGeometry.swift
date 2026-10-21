import AppKit
import CoreGraphics
import ModernSpectacleCore

public struct DisplayFrame: Equatable, Sendable {
    public var visibleFrame: CGRect

    public init(visibleFrame: CGRect) {
        self.visibleFrame = visibleFrame
    }
}

public enum ScreenGeometry {
    public static var displays: [DisplayFrame] {
        NSScreen.screens.map { DisplayFrame(visibleFrame: $0.accessibilityVisibleFrame) }
            .sorted { lhs, rhs in
                if lhs.visibleFrame.minX == rhs.visibleFrame.minX {
                    lhs.visibleFrame.minY < rhs.visibleFrame.minY
                } else {
                    lhs.visibleFrame.minX < rhs.visibleFrame.minX
                }
            }
    }

    public static func sourceAndDestination(
        for windowFrame: CGRect,
        moving action: WindowAction
    ) -> (source: DisplayFrame, destination: DisplayFrame)? {
        let availableDisplays = displays
        guard !availableDisplays.isEmpty else {
            return nil
        }

        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        let sourceIndex = availableDisplays.firstIndex {
            $0.visibleFrame.contains(windowCenter)
        } ?? 0

        let destinationIndex: Int
        switch action {
        case .nextDisplay:
            destinationIndex = (sourceIndex + 1) % availableDisplays.count
        case .previousDisplay:
            destinationIndex = (sourceIndex - 1 + availableDisplays.count) % availableDisplays.count
        default:
            destinationIndex = sourceIndex
        }

        return (availableDisplays[sourceIndex], availableDisplays[destinationIndex])
    }
}

private extension NSScreen {
    var accessibilityVisibleFrame: CGRect {
        guard let mainDisplayFrame = NSScreen.screens.first?.frame else {
            return visibleFrame
        }

        var converted = visibleFrame
        converted.origin.y = frame.height - visibleFrame.maxY + (mainDisplayFrame.height - frame.height)
        return converted
    }
}
