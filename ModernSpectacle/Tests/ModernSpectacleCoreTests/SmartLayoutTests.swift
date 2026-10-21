import CoreGraphics
import Foundation
import Testing
@testable import ModernSpectacleCore

@Suite
struct SmartLayoutTests {
    private let display = DisplayInfo(id: 0, visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875), isMain: true)

    private func window(_ id: Int, _ kind: AppKind, bundle: String, focused: Bool = false, ago: Int? = nil) -> WindowInfo {
        WindowInfo(
            id: id, app: bundle, bundleID: bundle, kind: kind, title: "w\(id)",
            frame: CGRect(x: 10, y: 50, width: 600, height: 400), displayID: 0, isFocused: focused, appActiveSecondsAgo: ago
        )
    }

    private func request(_ windows: [WindowInfo]) -> LayoutRequest {
        LayoutRequest(displays: [display], windows: windows, recentApps: [], corrections: [], notes: "", localTime: "t")
    }

    @Test
    func heuristicSplitsCodingLeftAndBrowserRight() {
        let plan = HeuristicPlanner().planNow(request([
            window(1, .coding, bundle: "com.microsoft.VSCode", focused: true),
            window(2, .browser, bundle: "com.google.Chrome"),
        ]))

        let coding = plan.placements.first { $0.id == 1 }!
        let browser = plan.placements.first { $0.id == 2 }!
        #expect(coding.group == "coding")
        #expect(coding.x == 0)
        #expect(abs(Double(coding.w) - 1440 * 0.6) < 10)
        #expect(browser.x >= coding.x + coding.w)
        #expect(browser.x + browser.w <= 1440)
        #expect(!coding.rect.intersects(browser.rect))
    }

    @Test
    func heuristicCascadesFinderAndSkipsUnrelatedApps() {
        let plan = HeuristicPlanner().planNow(request([
            window(1, .coding, bundle: "com.apple.Terminal"),
            window(2, .files, bundle: "com.apple.finder"),
            window(3, .files, bundle: "com.apple.finder"),
            window(4, .media, bundle: "com.spotify.client"),
        ]))

        let finders = plan.placements.filter { $0.group == "files" }
        #expect(finders.count == 2)
        #expect(finders[0].x != finders[1].x)
        #expect(plan.placements.contains { $0.id == 4 } == false)
        #expect(plan.placements.first { $0.id == 1 }?.w == 1440)
    }

    @Test
    func heuristicTilesWithoutOverlap() {
        let windows = (1...5).map { window($0, .coding, bundle: "com.apple.dt.Xcode", ago: $0 * 10) }
        let plan = HeuristicPlanner().planNow(request(windows))
        #expect(plan.placements.count == 5)
        for a in plan.placements {
            for b in plan.placements where a.id < b.id {
                #expect(!a.rect.insetBy(dx: 1, dy: 1).intersects(b.rect.insetBy(dx: 1, dy: 1)))
            }
            #expect(display.visibleFrame.insetBy(dx: -1, dy: -1).contains(a.rect))
        }
    }

    @Test
    func validatorClampsAndDropsUnknownWindows() {
        let req = request([window(1, .coding, bundle: "x")])
        let plan = LayoutPlan(summary: "s", notes: "n", placements: [
            Placement(id: 1, group: "g", rect: CGRect(x: -200, y: -200, width: 50, height: 20)),
            Placement(id: 1, group: "g", rect: CGRect(x: 0, y: 25, width: 100, height: 100)),
            Placement(id: 99, group: "g", rect: CGRect(x: 0, y: 25, width: 500, height: 500)),
        ])

        let safe = PlanValidator.sanitized(plan, for: req)
        #expect(safe.placements.count == 1)
        let rect = safe.placements[0].rect
        #expect(rect.minX == 0 && rect.minY == 25)
        #expect(rect.width == PlanValidator.minimumSize.width)
        #expect(rect.height == PlanValidator.minimumSize.height)

        let huge = PlanValidator.sanitized(LayoutPlan(summary: "", notes: "", placements: [
            Placement(id: 1, group: "g", rect: CGRect(x: 1000, y: 800, width: 3000, height: 3000)),
        ]), for: req)
        #expect(huge.placements[0].rect == display.visibleFrame)
    }

    @Test
    func validatorKeepsWindowsOnTheirOwnDisplay() {
        let second = DisplayInfo(id: 1, visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), isMain: false)
        var onSecond = window(2, .browser, bundle: "b")
        onSecond.displayID = 1
        let req = LayoutRequest(displays: [display, second], windows: [window(1, .coding, bundle: "a"), onSecond], recentApps: [], corrections: [], notes: "", localTime: "t")

        let plan = LayoutPlan(summary: "", notes: "", placements: [
            Placement(id: 1, group: "g", rect: CGRect(x: 1500, y: 100, width: 800, height: 600)), // tries to pull 1 to display 1
            Placement(id: 2, group: "g", rect: CGRect(x: 0, y: 25, width: 800, height: 600)), // tries to pull 2 to display 0
        ])
        let safe = PlanValidator.sanitized(plan, for: req)
        #expect(display.visibleFrame.contains(safe.placements[0].rect))
        #expect(second.visibleFrame.contains(safe.placements[1].rect))
    }

    @Test
    func heuristicLaysOutEachDisplaySeparately() {
        let second = DisplayInfo(id: 1, visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), isMain: false)
        var browser = window(2, .browser, bundle: "b")
        browser.displayID = 1
        let req = LayoutRequest(displays: [display, second], windows: [window(1, .coding, bundle: "a"), browser], recentApps: [], corrections: [], notes: "", localTime: "t")
        let plan = HeuristicPlanner().planNow(req)
        #expect(plan.placements.first { $0.id == 1 }?.rect == display.visibleFrame)
        #expect(plan.placements.first { $0.id == 2 }?.rect == second.visibleFrame)
    }

    @Test
    func planDecodesFromModelJSON() throws {
        let json = #"{"summary":"ok","notes":"keeps Slack narrow","placements":[{"id":2,"group":"coding","x":0,"y":25,"w":864,"h":875}]}"#
        let plan = try LayoutPrompt.decodePlan(from: json)
        #expect(plan.placements == [Placement(id: 2, group: "coding", rect: CGRect(x: 0, y: 25, width: 864, height: 875))])
        #expect(plan.notes == "keeps Slack narrow")
    }

    @Test
    func signatureIgnoresWindowPositionsButNotMembership() {
        var a = window(1, .coding, bundle: "x")
        let b = window(2, .browser, bundle: "y")
        let r1 = request([a, b])
        a = WindowInfo(id: 1, app: "x", bundleID: "x", kind: .coding, title: "w1", frame: CGRect(x: 500, y: 500, width: 300, height: 300), displayID: 0, isFocused: false, appActiveSecondsAgo: nil)
        let r2 = request([a, b])
        #expect(r1.signature == r2.signature)
        #expect(request([a]).signature != r1.signature)
    }

    @Test
    func historyKeepsBoundedCorrections() {
        var history = LayoutHistory()
        for i in 0..<(LayoutHistory.maxCorrections + 5) {
            history.record(LayoutCorrection(app: "a", title: "\(i)", planned: RectInfo(x: 0, y: 0, w: 1, h: 1), actual: RectInfo(x: 1, y: 1, w: 1, h: 1), date: Date()))
        }
        #expect(history.corrections.count == LayoutHistory.maxCorrections)
        #expect(history.corrections.first?.title == "5")
    }

    @Test
    func classifierUsesBundleThenCategoryThenName() {
        #expect(AppClassifier.kind(bundleID: "com.google.Chrome", category: nil, name: "Google Chrome") == .browser)
        #expect(AppClassifier.kind(bundleID: "com.example.ide", category: "public.app-category.developer-tools", name: "IDE") == .coding)
        #expect(AppClassifier.kind(bundleID: "com.example.x", category: nil, name: "Fancy Terminal") == .coding)
        #expect(AppClassifier.kind(bundleID: "com.example.y", category: nil, name: "Numbers") == .other)
    }
}
