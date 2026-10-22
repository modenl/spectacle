import Foundation

public enum WindowAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case center
    case maximize
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case upperLeft
    case lowerLeft
    case upperRight
    case lowerRight
    case nextThird
    case previousThird
    case nextDisplay
    case previousDisplay
    case larger
    case smaller
    case undo
    case redo
    case smartArrange
    case promoteFocused

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .center: L("Center", "居中")
        case .maximize: L("Maximize", "最大化")
        case .leftHalf: L("Left Half", "左半屏")
        case .rightHalf: L("Right Half", "右半屏")
        case .topHalf: L("Top Half", "上半屏")
        case .bottomHalf: L("Bottom Half", "下半屏")
        case .upperLeft: L("Upper Left", "左上角")
        case .lowerLeft: L("Lower Left", "左下角")
        case .upperRight: L("Upper Right", "右上角")
        case .lowerRight: L("Lower Right", "右下角")
        case .nextThird: L("Next Third", "下一个三分之一")
        case .previousThird: L("Previous Third", "上一个三分之一")
        case .nextDisplay: L("Next Display", "下一个显示器")
        case .previousDisplay: L("Previous Display", "上一个显示器")
        case .larger: L("Larger", "放大")
        case .smaller: L("Smaller", "缩小")
        case .undo: L("Undo", "撤销")
        case .redo: L("Redo", "重做")
        case .smartArrange: L("Smart Arrange", "智能排列")
        case .promoteFocused: L("Bring to Main", "移到主位")
        }
    }

    public var defaultShortcutDescription: String {
        switch self {
        case .center: "⌥⌘C"
        case .maximize: "⌥⌘F"
        case .leftHalf: "⌥⌘←"
        case .rightHalf: "⌥⌘→"
        case .topHalf: "⌥⌘↑"
        case .bottomHalf: "⌥⌘↓"
        case .upperLeft: "⌃⌘←"
        case .lowerLeft: "⌃⇧⌘←"
        case .upperRight: "⌃⌘→"
        case .lowerRight: "⌃⇧⌘→"
        case .nextDisplay: "⌃⌥⌘→"
        case .previousDisplay: "⌃⌥⌘←"
        case .nextThird: "⌃⌥→"
        case .previousThird: "⌃⌥←"
        case .larger: "⌃⌥⇧→"
        case .smaller: "⌃⌥⇧←"
        case .undo: "⌥⌘Z"
        case .redo: "⌥⇧⌘Z"
        case .smartArrange: "⌃⌥⌘M"
        case .promoteFocused: "⌃⌥⌘↩"
        }
    }

    public var menuTitle: String {
        "\(title) (\(shortcutDescription))"
    }

    /// The shortcut in effect, after the user's changes.
    public var shortcutDescription: String {
        ShortcutStore.description(for: self)
    }

    public var isHistoryAction: Bool {
        self == .undo || self == .redo
    }

    public var usesDestinationDisplay: Bool {
        self == .nextDisplay || self == .previousDisplay
    }
}
