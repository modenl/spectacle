import Foundation
import ModernSpectacleCore

@MainActor
public final class WindowController {
    private let accessibilityClient: AccessibilityClient
    private let calculator: WindowLayoutCalculator
    public typealias FrameSnapshot = [(window: ManagedWindow, frame: CGRect)]

    // Each entry is one undoable step; a smart arrangement restores several windows at once.
    private var undoStack: [FrameSnapshot] = []
    private var redoStack: [FrameSnapshot] = []

    public init(
        accessibilityClient: AccessibilityClient = AccessibilityClient(),
        calculator: WindowLayoutCalculator = WindowLayoutCalculator()
    ) {
        self.accessibilityClient = accessibilityClient
        self.calculator = calculator
    }

    public func perform(_ action: WindowAction) {
        switch action {
        case .undo:
            restore(from: &undoStack, into: &redoStack)
        case .redo:
            restore(from: &redoStack, into: &undoStack)
        default:
            moveFocusedWindow(action)
        }
    }

    private func moveFocusedWindow(_ action: WindowAction) {
        guard
            AccessibilityPermission.isTrusted,
            let window = accessibilityClient.focusedWindow(),
            window.isStandardMovableWindow,
            let currentFrame = window.frame,
            let displayContext = ScreenGeometry.sourceAndDestination(for: currentFrame, moving: action),
            let targetFrame = calculator.rect(
                for: action,
                currentWindow: currentFrame,
                sourceVisibleFrame: displayContext.source.visibleFrame,
                destinationVisibleFrame: displayContext.destination.visibleFrame
            )
        else {
            return
        }

        pushUndo([(window, currentFrame)])
        window.setFrame(targetFrame)
    }

    /// Records the frames to restore on the next undo. Call before changing them.
    public func pushUndo(_ snapshot: FrameSnapshot) {
        undoStack.append(snapshot)
        redoStack.removeAll()
    }

    private func restore(from source: inout [FrameSnapshot], into destination: inout [FrameSnapshot]) {
        guard let snapshot = source.popLast() else {
            return
        }

        let current = snapshot.compactMap { item -> (window: ManagedWindow, frame: CGRect)? in
            guard let frame = item.window.frame else { return nil }
            return (item.window, frame)
        }
        destination.append(current)
        for item in snapshot {
            item.window.setFrame(item.frame)
        }
    }
}
