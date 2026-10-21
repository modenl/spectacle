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

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .center: "Center"
        case .maximize: "Maximize"
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .upperLeft: "Upper Left"
        case .lowerLeft: "Lower Left"
        case .upperRight: "Upper Right"
        case .lowerRight: "Lower Right"
        case .nextThird: "Next Third"
        case .previousThird: "Previous Third"
        case .nextDisplay: "Next Display"
        case .previousDisplay: "Previous Display"
        case .larger: "Larger"
        case .smaller: "Smaller"
        case .undo: "Undo"
        case .redo: "Redo"
        }
    }

    public var defaultShortcutDescription: String {
        switch self {
        case .center: "Option+Command+C"
        case .maximize: "Option+Command+F"
        case .leftHalf: "Option+Command+Left"
        case .rightHalf: "Option+Command+Right"
        case .topHalf: "Option+Command+Up"
        case .bottomHalf: "Option+Command+Down"
        case .upperLeft: "Control+Command+Left"
        case .lowerLeft: "Control+Shift+Command+Left"
        case .upperRight: "Control+Command+Right"
        case .lowerRight: "Control+Shift+Command+Right"
        case .nextDisplay: "Control+Option+Command+Right"
        case .previousDisplay: "Control+Option+Command+Left"
        case .nextThird: "Control+Option+Right"
        case .previousThird: "Control+Option+Left"
        case .larger: "Control+Option+Shift+Right"
        case .smaller: "Control+Option+Shift+Left"
        case .undo: "Option+Command+Z"
        case .redo: "Option+Shift+Command+Z"
        }
    }

    public var menuTitle: String {
        "\(title) (\(defaultShortcutDescription))"
    }

    public var isHistoryAction: Bool {
        self == .undo || self == .redo
    }

    public var usesDestinationDisplay: Bool {
        self == .nextDisplay || self == .previousDisplay
    }
}
