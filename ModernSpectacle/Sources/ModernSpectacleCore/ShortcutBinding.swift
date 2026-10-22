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
    /// Key codes of 1…9 on the number row; ⌃⌥⌘ plus a digit restores the saved layout with that number.
    public static let presetKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

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
            ShortcutBinding(action: .redo, keyCode: 6, carbonModifiers: command | option | shift),
            // M, not A: the left hand holds ⌃⌥⌘ and the right hand presses M (and presses it again to switch template).
            ShortcutBinding(action: .smartArrange, keyCode: 46, carbonModifiers: command | option | control),
            ShortcutBinding(action: .promoteFocused, keyCode: 36, carbonModifiers: command | option | control)
        ]
    }
}

/// Carbon's modifier masks, so the core can describe and store shortcuts without importing Carbon.
public enum CarbonModifiers {
    public static let command: UInt32 = 256
    public static let shift: UInt32 = 512
    public static let option: UInt32 = 2048
    public static let control: UInt32 = 4096
    public static let all = command | shift | option | control
}

/// Names for key codes on the US layout, as menus show them.
public enum KeyNames {
    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-",
        28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 115: "↖", 116: "⇞",
        117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    public static func name(of keyCode: UInt32) -> String? { names[keyCode] }

    public static func isFunctionKey(_ keyCode: UInt32) -> Bool { names[keyCode]?.hasPrefix("F") == true && keyCode >= 96 }

    /// "⌃⌥⌘M", in the order macOS menus use.
    public static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var text = ""
        if modifiers & CarbonModifiers.control != 0 { text += "⌃" }
        if modifiers & CarbonModifiers.option != 0 { text += "⌥" }
        if modifiers & CarbonModifiers.shift != 0 { text += "⇧" }
        if modifiers & CarbonModifiers.command != 0 { text += "⌘" }
        return text + (names[keyCode] ?? "#\(keyCode)")
    }
}

/// The shortcuts in effect: the defaults with the user's changes on top. Changes are kept in user defaults as
/// action -> [keyCode, modifiers]; an empty array means the user removed the shortcut.
public enum ShortcutStore {
    public static let defaultsKey = "shortcuts"
    /// ⌃⌥⌘ plus 1…9 restores saved layouts; those combinations are not available for actions.
    public static let presetModifiers = CarbonModifiers.control | CarbonModifiers.option | CarbonModifiers.command

    public static var defaults: [ShortcutBinding] {
        DefaultShortcutBindings.all(command: CarbonModifiers.command, option: CarbonModifiers.option, control: CarbonModifiers.control, shift: CarbonModifiers.shift)
    }

    private static var overrides: [String: [UInt32]] {
        get { (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [UInt32]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    public static func bindings() -> [ShortcutBinding] {
        let changes = overrides
        return defaults.compactMap { binding in
            guard let change = changes[binding.action.rawValue] else { return binding }
            guard change.count == 2 else { return nil }
            return ShortcutBinding(action: binding.action, keyCode: change[0], carbonModifiers: change[1])
        }
    }

    public static func binding(for action: WindowAction) -> ShortcutBinding? {
        bindings().first { $0.action == action }
    }

    /// "⌃⌥⌘M", or "–" when the user removed it.
    public static func description(for action: WindowAction) -> String {
        binding(for: action).map { KeyNames.describe(keyCode: $0.keyCode, modifiers: $0.carbonModifiers) } ?? "–"
    }

    public enum Problem: Equatable, Sendable {
        case needsModifier
        case usedBy(WindowAction)
        case reservedForLayouts
    }

    /// Why a combination cannot be used for `action`, or nil when it can.
    public static func problem(keyCode: UInt32, modifiers: UInt32, for action: WindowAction, in current: [ShortcutBinding]) -> Problem? {
        let mods = modifiers & CarbonModifiers.all
        if mods & (CarbonModifiers.control | CarbonModifiers.option | CarbonModifiers.command) == 0, !KeyNames.isFunctionKey(keyCode) {
            return .needsModifier
        }
        if mods == presetModifiers, (18...29).contains(keyCode), keyCode != 24, keyCode != 27, keyCode != 29 {
            return .reservedForLayouts
        }
        if let other = current.first(where: { $0.action != action && $0.keyCode == keyCode && $0.carbonModifiers == mods }) {
            return .usedBy(other.action)
        }
        return nil
    }

    /// Nil keyCode removes the shortcut.
    public static func set(keyCode: UInt32?, modifiers: UInt32, for action: WindowAction) {
        var changes = overrides
        if let keyCode {
            let fallback = defaults.first { $0.action == action }
            if fallback?.keyCode == keyCode, fallback?.carbonModifiers == modifiers & CarbonModifiers.all {
                changes[action.rawValue] = nil
            } else {
                changes[action.rawValue] = [keyCode, modifiers & CarbonModifiers.all]
            }
        } else {
            changes[action.rawValue] = []
        }
        overrides = changes
    }

    public static func resetAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
