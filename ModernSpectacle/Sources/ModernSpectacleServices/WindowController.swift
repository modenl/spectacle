import Foundation
import ModernSpectacleCore

@MainActor
public final class WindowController {
    private let accessibilityClient: AccessibilityClient
    private let calculator: WindowLayoutCalculator
    private var undoStack: [(window: ManagedWindow, frame: CGRect)] = []
    private var redoStack: [(window: ManagedWindow, frame: CGRect)] = []

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

        undoStack.append((window, currentFrame))
        redoStack.removeAll()
        window.setFrame(targetFrame)
    }

    private func restore(
        from source: inout [(window: ManagedWindow, frame: CGRect)],
        into destination: inout [(window: ManagedWindow, frame: CGRect)]
    ) {
        guard let item = source.popLast(), let currentFrame = item.window.frame else {
            return
        }

        destination.append((item.window, currentFrame))
        item.window.setFrame(item.frame)
    }
}
