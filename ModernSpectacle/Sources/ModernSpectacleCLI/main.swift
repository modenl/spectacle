import AppKit
import Foundation
import ModernSpectacleCore
import ModernSpectacleServices

// Developer tool: inspect the snapshot the planner sees and try planners without the app.
//
//   spectacle-cli snapshot            print the windows and displays as JSON
//   spectacle-cli plan [--heuristic]  ask Claude (or the heuristic) for a plan and print it
//   spectacle-cli plan --sample       plan a built-in sample desktop (no Accessibility needed)
//   spectacle-cli arrange [--heuristic]  plan and apply
//   spectacle-cli trigger             ask the running app to Smart Arrange (same as ⌃⌥⌘A)
//   spectacle-cli trigger <command> [argument]
//                                     ask the running app to run a WindowAction by name (leftHalf, promoteFocused…),
//                                     restore <n>, save <name>, delete <name>, or check-updates

@MainActor
func run() async {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        print("usage: spectacle-cli snapshot | plan [--heuristic|--sample] | arrange [--heuristic]")
        exit(2)
    }
    // `trigger` must not touch the keychain: reading an item the app created makes macOS show a permission dialog.
    if command == "trigger", args.count >= 2, args[1] != "--fresh" {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("xyz.alvumo.ModernSpectacle.command"), object: nil,
            userInfo: ["command": args[1], "argument": args.dropFirst(2).joined(separator: " ")], deliverImmediately: true
        )
        print("sent \(args[1])")
        return
    }
    if command == "trigger" {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("xyz.alvumo.ModernSpectacle.arrange"), object: nil,
            userInfo: args.contains("--fresh") ? ["fresh": "1"] : nil, deliverImmediately: true
        )
        print("sent")
        return
    }
    let useHeuristic = args.contains("--heuristic") || !KeychainStore.hasAPIKey
    let planner: any LayoutPlanner = useHeuristic ? HeuristicPlanner() : ClaudePlanner()

    let request: LayoutRequest
    let snapshot: WindowEnumerator.Snapshot?
    if args.contains("--sample") {
        request = sampleRequest()
        snapshot = nil
    } else {
        guard AccessibilityPermission.isTrusted else {
            print("error: this process has no Accessibility permission; run from a trusted terminal or use --sample")
            exit(1)
        }
        let enumerator = WindowEnumerator()
        let snap = enumerator.snapshot(lastActive: [:])
        snapshot = snap
        request = LayoutRequest(displays: snap.displays, windows: snap.windows, recentApps: [], corrections: [], notes: "", localTime: "now")
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    switch command {
    case "snapshot":
        print(String(decoding: try! encoder.encode(request), as: UTF8.self))
    case "plan", "arrange":
        let started = Date()
        do {
            let plan = try await planner.plan(request)
            let safe = PlanValidator.sanitized(plan, for: request)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            print("planner: \(planner.name)  time: \(elapsed) ms")
            print(String(decoding: try! encoder.encode(safe), as: UTF8.self))
            if command == "arrange", let snapshot {
                let byID = Dictionary(snapshot.entries.map { ($0.info.id, $0) }, uniquingKeysWith: { a, _ in a })
                for placement in safe.placements {
                    byID[placement.id]?.window.setFrame(placement.rect)
                }
                print("applied \(safe.placements.count) placements")
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    default:
        print("unknown command \(command)")
        exit(2)
    }
}

func sampleRequest() -> LayoutRequest {
    let display = DisplayInfo(id: 0, visibleFrame: CGRect(x: 0, y: 25, width: 1728, height: 1052), isMain: true)
    func window(_ id: Int, _ app: String, _ bundle: String, _ kind: AppKind, _ title: String, _ frame: CGRect, focused: Bool = false, ago: Int?) -> WindowInfo {
        WindowInfo(id: id, app: app, bundleID: bundle, kind: kind, title: title, frame: frame, displayID: 0, isFocused: focused, appActiveSecondsAgo: ago)
    }
    return LayoutRequest(
        displays: [display],
        windows: [
            window(1, "Code", "com.microsoft.VSCode", .coding, "SmartArranger.swift — spectacle", CGRect(x: 100, y: 100, width: 1200, height: 800), focused: true, ago: 0),
            window(2, "Terminal", "com.apple.Terminal", .coding, "spectacle — zsh", CGRect(x: 300, y: 400, width: 700, height: 500), ago: 40),
            window(3, "Claude", "com.anthropic.claudefordesktop", .coding, "Claude", CGRect(x: 600, y: 200, width: 900, height: 700), ago: 15),
            window(4, "Google Chrome", "com.google.Chrome", .browser, "GitHub - modenl/spectacle", CGRect(x: 200, y: 150, width: 1100, height: 850), ago: 120),
            window(5, "Google Chrome", "com.google.Chrome", .browser, "YouTube", CGRect(x: 250, y: 200, width: 1100, height: 850), ago: 3000),
            window(6, "Finder", "com.apple.finder", .files, "Downloads", CGRect(x: 800, y: 500, width: 800, height: 500), ago: 600),
            window(7, "Slack", "com.tinyspeck.slackmacgap", .chat, "general - Acme", CGRect(x: 400, y: 300, width: 900, height: 700), ago: 900),
        ],
        recentApps: ["Code", "Claude", "Terminal", "Google Chrome"],
        corrections: [],
        notes: "",
        localTime: "Tuesday 14:30"
    )
}

await run()
