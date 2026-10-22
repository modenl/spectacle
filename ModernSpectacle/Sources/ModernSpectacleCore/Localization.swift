import Foundation

/// The UI speaks English or Simplified Chinese: the system's choice by default, or what the user picked in Settings.
/// Strings live next to the code that shows them as `L("English", "中文")`, so the two never drift apart.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english
    case chinese

    public var title: String {
        switch self {
        case .system: L("System", "跟随系统")
        case .english: "English"
        case .chinese: "中文"
        }
    }
}

public enum Localization {
    public static let defaultsKey = "language"

    public static var language: AppLanguage {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            // Text AppKit and Sparkle draw (standard buttons, the About panel, update dialogs) follows the app's
            // AppleLanguages, read at launch.
            switch newValue {
            case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            case .english: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            case .chinese: UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
            }
        }
    }

    public static var isChinese: Bool {
        isChinese(language, preferredLanguages: Locale.preferredLanguages)
    }

    static func isChinese(_ language: AppLanguage, preferredLanguages: [String]) -> Bool {
        switch language {
        case .english: false
        case .chinese: true
        case .system: preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        }
    }
}

public func L(_ english: String, _ chinese: String) -> String {
    Localization.isChinese ? chinese : english
}
