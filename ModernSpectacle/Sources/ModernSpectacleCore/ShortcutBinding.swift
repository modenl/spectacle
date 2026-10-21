import Foundation

public struct ShortcutBinding: Codable, Equatable, Identifiable, Sendable {
    public var id: WindowAction { action }
    public var action: WindowAction
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public init(action: WindowAction, keyCode: UInt32, carbonModifiers: UInt32) {
        self.action = action
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }
}

public enum DefaultShortcutBindings {
    public static func all(
        command: UInt32,
        option: UInt32,
        control: UInt32,
        shift: UInt32
    ) -> [ShortcutBinding] {
        [
            ShortcutBinding(action: .center, keyCode: 8, carbonModifiers: command | option),
            ShortcutBinding(action: .maximize, keyCode: 3, carbonModifiers: command | option),
            ShortcutBinding(action: .leftHalf, keyCode: 123, carbonModifiers: command | option),
            ShortcutBinding(action: .rightHalf, keyCode: 124, carbonModifiers: command | option),
            ShortcutBinding(action: .topHalf, keyCode: 126, carbonModifiers: command | option),
            ShortcutBinding(action: .bottomHalf, keyCode: 125, carbonModifiers: command | option),
            ShortcutBinding(action: .upperLeft, keyCode: 123, carbonModifiers: command | control),
            ShortcutBinding(action: .upperRight, keyCode: 124, carbonModifiers: command | control),
            ShortcutBinding(action: .lowerLeft, keyCode: 123, carbonModifiers: command | control | shift),
            ShortcutBinding(action: .lowerRight, keyCode: 124, carbonModifiers: command | control | shift),
            ShortcutBinding(action: .nextDisplay, keyCode: 124, carbonModifiers: command | option | control),
            ShortcutBinding(action: .previousDisplay, keyCode: 123, carbonModifiers: command | option | control),
            ShortcutBinding(action: .nextThird, keyCode: 124, carbonModifiers: option | control),
            ShortcutBinding(action: .previousThird, keyCode: 123, carbonModifiers: option | control),
            ShortcutBinding(action: .larger, keyCode: 124, carbonModifiers: option | control | shift),
            ShortcutBinding(action: .smaller, keyCode: 123, carbonModifiers: option | control | shift),
            ShortcutBinding(action: .undo, keyCode: 6, carbonModifiers: command | option),
            ShortcutBinding(action: .redo, keyCode: 6, carbonModifiers: command | option | shift)
        ]
    }
}
