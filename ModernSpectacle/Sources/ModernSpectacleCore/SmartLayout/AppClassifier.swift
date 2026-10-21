import Foundation

/// Cold-start classification of apps. The model and the user's corrections override this; it only seeds the heuristic planner.
public enum AppClassifier {
    private static let codingBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "com.apple.dt.Xcode",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.goland",
        "com.sublimetext.4",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
        "com.github.GitHubClient",
        "com.fournova.Tower3",
        "com.postmanlabs.mac",
    ]

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser", // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    private static let chatBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.tencent.xinWeChat",
        "ru.keepcoder.Telegram",
        "com.hnc.Discord",
        "com.apple.MobileSMS",
        "com.microsoft.teams2",
        "us.zoom.xos",
        "com.openai.chat",
        "com.apple.mail",
        "com.readdle.smartemail-Mac",
    ]

    private static let mediaBundleIDs: Set<String> = [
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.TV",
        "com.apple.QuickTimePlayerX",
        "org.videolan.vlc",
        "com.colliderli.iina",
    ]

    public static func kind(bundleID: String, category: String?, name: String) -> AppKind {
        if codingBundleIDs.contains(bundleID) { return .coding }
        if browserBundleIDs.contains(bundleID) { return .browser }
        if chatBundleIDs.contains(bundleID) { return .chat }
        if mediaBundleIDs.contains(bundleID) { return .media }
        if bundleID == "com.apple.finder" { return .files }

        switch category {
        case "public.app-category.developer-tools":
            return .coding
        case "public.app-category.social-networking":
            return .chat
        case "public.app-category.music", "public.app-category.video", "public.app-category.entertainment":
            return .media
        default:
            break
        }

        let lowered = name.lowercased()
        if lowered.contains("terminal") || lowered.contains("code") || lowered.contains("claude") || lowered.contains("codex") {
            return .coding
        }
        if lowered.contains("browser") {
            return .browser
        }
        return .other
    }
}
