import CoreGraphics
import Foundation
import Testing
@testable import ModernSpectacleCore

@Suite
struct RankingTests {
    private let laptop = DisplayInfo(id: 0, visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 871), isMain: true)
    private let wide = DisplayInfo(id: 0, visibleFrame: CGRect(x: 0, y: 30, width: 3440, height: 1319), isMain: true)

    private func window(_ id: Int, _ app: String, _ kind: AppKind, focused: Bool = false, ago: Int? = nil) -> WindowInfo {
        WindowInfo(id: id, app: app, bundleID: app, kind: kind, title: app, frame: CGRect(x: 0, y: 33, width: 800, height: 600),
                   displayID: 0, isFocused: focused, appActiveSecondsAgo: ago, lastFocusedSecondsAgo: ago)
    }

    private func request(_ display: DisplayInfo, _ windows: [WindowInfo]) -> LayoutRequest {
        LayoutRequest(displays: [display], windows: windows, recentApps: [], corrections: [], notes: "", localTime: "t",
                      focusedWindowID: windows.first { $0.isFocused }?.id)
    }

    private func ranking(_ items: [(Int, WindowRole)]) -> WindowRanking {
        WindowRanking(windows: items.enumerated().map { RankedWindow(id: $1.0, role: $1.1, relevance: Double(items.count - $0)) }, source: "test")
    }

    @Test
    func everyDisplaySizeHasThreeTemplatesWithoutAStrip() {
        for catalog in [LayoutTemplates.wide, LayoutTemplates.standard, LayoutTemplates.small] {
            #expect(catalog.count == 3)
            #expect(catalog.allSatisfy { !$0.hasStack && $0.slotsByNearness.first?.id == "main" })
        }
        #expect(LayoutTemplates.small.map(\.id) == ["small-main-2", "small-2col", "small-monocle"])
    }

    @Test
    func laptopFillPutsTheTaskBesideMainAndChatBelow() {
        // Claude focused; iTerm and Chrome belong to the task, Slack is for keeping an eye on, Notes is background.
        let req = request(laptop, [window(1, "claude", .coding, focused: true), window(2, "chrome", .browser), window(3, "iterm", .coding), window(4, "slack", .chat), window(5, "notes", .other)])
        let choice = LayoutTemplates.fill(LayoutTemplates.small[0], on: laptop, ranking: ranking([(1, .task), (2, .task), (3, .task), (4, .awareness), (5, .background)]), request: req)
        let slot = Dictionary(uniqueKeysWithValues: choice.slots.map { ($0.slot, $0.window) })
        #expect(slot["main"] == 1)
        #expect(slot["side-top"] == 3) // Chrome ranks higher but would be unreadable in 605 points
        #expect(slot["side-bottom"] == 4) // the awareness slot takes the chat window
        #expect(choice.stack == [2, 5])
    }

    @Test
    func wideFillKeepsAwarenessOnTheRightAndTaskOnTheLeft() {
        let req = request(wide, [window(1, "claude", .coding, focused: true), window(2, "iterm", .coding), window(3, "slack", .chat), window(4, "mail", .chat), window(5, "music", .media)])
        let choice = LayoutTemplates.fill(LayoutTemplates.wide[0], on: wide, ranking: ranking([(1, .task), (3, .awareness), (2, .task), (4, .awareness), (5, .background)]), request: req)
        let slot = Dictionary(uniqueKeysWithValues: choice.slots.map { ($0.slot, $0.window) })
        #expect(slot == ["main": 1, "left": 2, "right-1": 3, "right-2": 4, "right-3": 5]) // background fills the last free slot
        #expect(choice.stack.isEmpty)
    }

    @Test
    func theFocusedWindowTakesMainWhateverTheRanking() {
        let req = request(laptop, [window(1, "a", .coding), window(2, "b", .coding, focused: true)])
        let choice = LayoutTemplates.fill(LayoutTemplates.small[1], on: laptop, ranking: ranking([(1, .task), (2, .background)]), request: req)
        #expect(choice.slots.first { $0.slot == "main" }?.window == 2)
    }

    @Test
    func localRankingPutsFocusFirstAndRecentBeforeOld() {
        let req = request(laptop, [window(1, "old", .coding, ago: 7200), window(2, "chat", .chat, ago: 30), window(3, "now", .coding, focused: true, ago: 0), window(4, "recent", .coding, ago: 60)])
        let ranked = LocalRanker.rank(req)
        #expect(ranked.windows.map(\.id) == [3, 2, 4, 1])
        #expect(ranked.windows.first { $0.id == 2 }?.role == .awareness)
        #expect(ranked.windows.first { $0.id == 1 }?.role == .background)
    }

    @Test
    func theModelsOrderBecomesTheRankingAndForgottenWindowsAreAppended() {
        let req = request(laptop, [window(1, "claude", .coding, focused: true), window(2, "iterm", .coding), window(3, "slack", .chat)])
        // As the on-device model might answer: a repeat and an id that does not exist, and Slack left out.
        let ranked = RankingPrompt.ranking(task: [2, 1, 2, 99], awareness: [], request: req, source: "apple")
        #expect(ranked.windows.map(\.id) == [2, 1, 3])
        #expect(ranked.windows.map(\.role) == [.task, .task, .background]) // what it left out is background
        #expect(ranked.source == "apple")
        let withChat = RankingPrompt.ranking(task: [1], awareness: [3], request: req, source: "apple")
        #expect(withChat.windows.map(\.role) == [.task, .awareness, .background])
    }

    @Test
    func theModelSeesACompactState() throws {
        let many = (1...40).map { window($0, "app\($0)", .coding, focused: $0 == 1) }
        let state = RankingState(request(laptop, many))
        #expect(state.windows.count == 30)
        let long = request(laptop, [WindowInfo(id: 1, app: "a", bundleID: "a", kind: .coding, title: String(repeating: "x", count: 200), frame: .zero, displayID: 0, isFocused: true, appActiveSecondsAgo: nil)])
        #expect(RankingState(long).windows[0].title.count == 50)
    }

    @Test
    func aCachedRankingFollowsWindowsWhoseIdsChanged() {
        let then = [window(1, "claude", .coding), window(2, "iterm", .coding)]
        let now = [window(5, "iterm", .coding), window(6, "claude", .coding)]
        let translated = ranking([(1, .task), (2, .awareness)]).translated(from: then, to: now)
        #expect(translated.windows.map(\.id) == [6, 5])
        #expect(translated.windows.map(\.role) == [.task, .awareness])
    }
}

@Suite(.serialized)
struct ShortcutStoreTests {
    @Test
    func smartArrangeDefaultsToControlOptionCommandM() {
        ShortcutStore.resetAll()
        #expect(WindowAction.smartArrange.shortcutDescription == "⌃⌥⌘M")
        #expect(WindowAction.leftHalf.shortcutDescription == "⌥⌘←")
    }

    @Test
    func changesAreStoredRemovedAndReset() {
        ShortcutStore.resetAll()
        ShortcutStore.set(keyCode: 0, modifiers: CarbonModifiers.control | CarbonModifiers.option | CarbonModifiers.command, for: .smartArrange)
        #expect(WindowAction.smartArrange.shortcutDescription == "⌃⌥⌘A")
        ShortcutStore.set(keyCode: nil, modifiers: 0, for: .center)
        #expect(ShortcutStore.binding(for: .center) == nil)
        #expect(WindowAction.center.shortcutDescription == "–")
        ShortcutStore.resetAll()
        #expect(WindowAction.smartArrange.shortcutDescription == "⌃⌥⌘M")
        #expect(ShortcutStore.binding(for: .center) != nil)
    }

    @Test
    func unusableCombinationsAreRefused() {
        let current = ShortcutStore.defaults
        let cmdOptCtrl = CarbonModifiers.control | CarbonModifiers.option | CarbonModifiers.command
        #expect(ShortcutStore.problem(keyCode: 46, modifiers: 0, for: .center, in: current) == .needsModifier)
        #expect(ShortcutStore.problem(keyCode: 46, modifiers: CarbonModifiers.shift, for: .center, in: current) == .needsModifier)
        #expect(ShortcutStore.problem(keyCode: 122, modifiers: 0, for: .center, in: current) == nil) // F1 alone is fine
        #expect(ShortcutStore.problem(keyCode: 19, modifiers: cmdOptCtrl, for: .center, in: current) == .reservedForLayouts)
        #expect(ShortcutStore.problem(keyCode: 46, modifiers: cmdOptCtrl, for: .center, in: current) == .usedBy(.smartArrange))
        #expect(ShortcutStore.problem(keyCode: 46, modifiers: cmdOptCtrl, for: .smartArrange, in: current) == nil) // its own
    }
}

@Suite
struct LearnedWidthTests {
    private let laptop = DisplayInfo(id: 0, visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 871), isMain: true)

    private func window(_ id: Int, _ app: String, _ kind: AppKind, title: String? = nil, focused: Bool = false) -> WindowInfo {
        WindowInfo(id: id, app: app, bundleID: app, kind: kind, title: title ?? app, frame: CGRect(x: 0, y: 33, width: 800, height: 600),
                   displayID: 0, isFocused: focused, appActiveSecondsAgo: nil)
    }

    @Test
    func retitledWindowsDoNotInvalidateTheRanking() {
        let before = LayoutRequest(displays: [laptop], windows: [window(1, "iterm", .coding, title: "-zsh")], recentApps: [], corrections: [], notes: "", localTime: "t")
        let after = LayoutRequest(displays: [laptop], windows: [window(1, "iterm", .coding, title: "swift test")], recentApps: [], corrections: [], notes: "", localTime: "t")
        let more = LayoutRequest(displays: [laptop], windows: [window(1, "iterm", .coding), window(2, "iterm", .coding)], recentApps: [], corrections: [], notes: "", localTime: "t")
        #expect(before.signature == after.signature)
        #expect(before.signature != more.signature) // a new window is a new situation
    }
}

@Suite
struct SlotFrameTests {
    @Test
    func aTemplatesSlotsTileTheDisplayExactly() {
        let frame = CGRect(x: 0, y: 33, width: 1512, height: 871)
        let slots = LayoutTemplates.slotFrames(of: LayoutTemplates.small[0], in: frame)
        #expect(slots.map(\.slot.id) == ["main", "side-top", "side-bottom"])
        #expect(slots[0].rect == CGRect(x: 0, y: 33, width: 907, height: 871))
        #expect(slots[1].rect.minX == 907 && slots[1].rect.maxX == 1512)
        #expect(slots[1].rect.maxY == slots[2].rect.minY && slots[2].rect.maxY == frame.maxY)
        #expect(slots[2].slot.awareness)
    }
}

@Suite
struct ActiveDisplayTests {
    private let external = DisplayInfo(id: 0, visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 1092), isMain: true)
    private let laptop = DisplayInfo(id: 1, visibleFrame: CGRect(x: 1920, y: 142, width: 1512, height: 949), isMain: false)

    private func window(_ id: Int, display: Int, focused: Bool = false) -> WindowInfo {
        WindowInfo(id: id, app: "a\(id)", bundleID: "a\(id)", kind: .coding, title: "", frame: CGRect(x: display == 0 ? 10 : 1930, y: 150, width: 600, height: 400),
                   displayID: display, isFocused: focused, appActiveSecondsAgo: nil)
    }

    @Test
    func onlyTheFocusedWindowsDisplayIsArranged() {
        let request = LayoutRequest(displays: [external, laptop], windows: [window(1, display: 1, focused: true), window(2, display: 0), window(3, display: 0)],
                                    recentApps: [], corrections: [], notes: "", localTime: "t", focusedWindowID: 1)
        #expect(request.activeDisplayID(pointer: nil) == 1)
        let laptopOnly = request.restricted(to: 1)
        #expect(laptopOnly.displays.map(\.id) == [1])
        #expect(laptopOnly.windows.map(\.id) == [1])
        // Nothing on the other display is planned, so nothing there moves.
        let ranking = LocalRanker.rank(request)
        let choice = LayoutTemplates.fill(LayoutTemplates.small[0], on: laptop, ranking: ranking, request: laptopOnly)
        let plan = PlanValidator.completed(PlanValidator.sanitized(LayoutTemplates.plan(from: TemplatePlan(summary: "", notes: "", displays: [choice]), for: laptopOnly), for: laptopOnly), for: laptopOnly)
        #expect(Set(plan.placements.map(\.id)) == [1])
    }

    @Test
    func withoutAFocusedWindowThePointerDecides() {
        let request = LayoutRequest(displays: [external, laptop], windows: [window(2, display: 0)], recentApps: [], corrections: [], notes: "", localTime: "t")
        #expect(request.activeDisplayID(pointer: CGPoint(x: 2500, y: 600)) == 1)
        #expect(request.activeDisplayID(pointer: CGPoint(x: 500, y: 600)) == 0)
        #expect(request.activeDisplayID(pointer: nil) == 0) // the main display
    }
}

@Suite
struct StartingTemplateTests {
    @Test
    func theRememberedTemplateIsKeptWhileItHasRoom() {
        let standard = LayoutTemplates.standard // main+2 (3), two columns (2), grid (4)
        #expect(LayoutTemplates.startingTemplate(in: standard, remembered: "std-2col", needed: 2) == 1)
        #expect(LayoutTemplates.startingTemplate(in: standard, remembered: "std-2col", needed: 1) == 1)
    }

    @Test
    func tooFewSlotsMovesUpToTheSmallestThatFits() {
        let standard = LayoutTemplates.standard
        // Two columns remembered, but Claude, iTerm and Sublime all want a place: main + two on the right.
        #expect(LayoutTemplates.startingTemplate(in: standard, remembered: "std-2col", needed: 3) == 0)
        #expect(LayoutTemplates.startingTemplate(in: standard, remembered: "std-2col", needed: 4) == 2)
        #expect(LayoutTemplates.startingTemplate(in: standard, remembered: "std-2col", needed: 9) == 2) // the largest
        #expect(LayoutTemplates.startingTemplate(in: standard, remembered: nil, needed: 2) == 1)
    }
}

@Suite
struct MainAndTwoTests {
    @Test
    func mainAndTwoOnTheRightPlacesThreeWindows() {
        let display = DisplayInfo(id: 0, visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 1092), isMain: true)
        func window(_ id: Int, _ app: String, _ kind: AppKind, focused: Bool = false) -> WindowInfo {
            WindowInfo(id: id, app: app, bundleID: app, kind: kind, title: app, frame: CGRect(x: 0, y: 30, width: 1920, height: 1091), displayID: 0, isFocused: focused, appActiveSecondsAgo: nil)
        }
        let request = LayoutRequest(displays: [display], windows: [window(6, "claude", .coding, focused: true), window(2, "iterm", .coding), window(3, "sublime", .coding), window(4, "notes", .other)],
                                    recentApps: [], corrections: [], notes: "", localTime: "t", focusedWindowID: 6)
        // The model's actual answer from the bug report.
        let ranking = WindowRanking(windows: [RankedWindow(id: 6, role: .task, relevance: 4), RankedWindow(id: 2, role: .task, relevance: 3),
                                              RankedWindow(id: 3, role: .task, relevance: 2), RankedWindow(id: 4, role: .background, relevance: 1)], source: "claude")
        let choice = LayoutTemplates.fill(LayoutTemplates.standard[0], on: display, ranking: ranking, request: request)
        #expect(Set(choice.slots.map(\.window)) == [6, 2, 3])
        let plan = LayoutTemplates.plan(from: TemplatePlan(summary: "", notes: "", displays: [choice]), for: request)
        #expect(plan.placements.filter { $0.group.hasPrefix("column") }.count == 3)
    }
}


@Suite
struct FullTemplateTests {
    @Test
    func aGridWithFourWindowsShowsAllFour() {
        let display = DisplayInfo(id: 0, visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 1092), isMain: true)
        func window(_ id: Int, _ app: String, _ kind: AppKind, focused: Bool = false) -> WindowInfo {
            WindowInfo(id: id, app: app, bundleID: app, kind: kind, title: app, frame: CGRect(x: 0, y: 30, width: 900, height: 700), displayID: 0, isFocused: focused, appActiveSecondsAgo: nil)
        }
        let request = LayoutRequest(displays: [display], windows: [window(6, "claude", .coding, focused: true), window(2, "iterm", .coding), window(3, "sublime", .coding), window(4, "notes", .other)],
                                    recentApps: [], corrections: [], notes: "", localTime: "t", focusedWindowID: 6)
        let ranking = WindowRanking(windows: [RankedWindow(id: 6, role: .task, relevance: 4), RankedWindow(id: 2, role: .task, relevance: 3),
                                              RankedWindow(id: 3, role: .task, relevance: 2), RankedWindow(id: 4, role: .background, relevance: 1)], source: "claude")
        let grid = LayoutTemplates.standard.first { $0.id == "std-grid-4" }!
        let choice = LayoutTemplates.fill(grid, on: display, ranking: ranking, request: request)
        #expect(choice.slots.count == 4)
        let plan = LayoutTemplates.plan(from: TemplatePlan(summary: "", notes: "", displays: [choice]), for: request)
        let tiles = plan.placements.filter { $0.group.hasPrefix("column") }
        #expect(tiles.count == 4)
        #expect(tiles.allSatisfy { $0.w == 960 && ($0.h == 546 || $0.h == 546) })
    }
}
