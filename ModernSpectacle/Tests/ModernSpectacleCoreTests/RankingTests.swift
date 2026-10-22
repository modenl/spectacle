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
        #expect(slot == ["main": 1, "left": 2, "right-1": 3, "right-2": 4]) // background music is not given a slot
        #expect(choice.stack == [5])
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
    func jevRequestAsksTwoQuestionsPerWindowAndParsesTheAnswers() throws {
        let req = request(laptop, [window(1, "claude", .coding, focused: true), window(2, "slack", .chat)])
        let body = JevRankingRequest.body(for: req)
        #expect(body.model == "jev-latest")
        #expect(Set(body.questions.keys) == ["relevance-1", "role-1", "relevance-2", "role-2"])
        #expect(body.questions["relevance-1"]?.type == "score")
        #expect(body.questions["role-2"]?.criteria == .options(["task": "Needed for the current task: keep it visible next to the main window", "awareness": "Kept an eye on but not worked in: chat, mail, calendar, monitors, music", "background": "Not needed now: can wait hidden"]))
        // Encodes the way the API expects: criteria as an array of levels or a map of options.
        let json = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        #expect(json.contains(#""criteria":["Unrelated"#))

        let response = #"{"model":"jev-1.13.0","answers":{"relevance-1":{"type":"score","score":2.9,"confidence":0.8},"role-1":{"type":"choice","choice":"task","confidence":0.9},"relevance-2":{"type":"score","score":0.4},"role-2":{"type":"choice","choice":"awareness"}},"usage":{"input_tokens":300,"output_tokens":20}}"#
        let ranked = try JevRankingRequest.ranking(fromResponse: Data(response.utf8), request: req)
        #expect(ranked.windows.map(\.id) == [1, 2])
        #expect(ranked.windows.map(\.role) == [.task, .awareness])
        #expect(ranked.source == "jev")
    }

    @Test
    func claudeRankingKeepsTheModelsOrderAndCoversForgottenWindows() throws {
        let req = request(laptop, [window(1, "claude", .coding, focused: true), window(2, "iterm", .coding), window(3, "slack", .chat)])
        let text = #"{"windows":[{"id":2,"role":"task"},{"id":1,"role":"task"},{"id":2,"role":"task"},{"id":99,"role":"task"}],"notes":"likes iTerm next to Claude"}"#
        let ranked = try ClaudeRankingPrompt.ranking(fromModelJSON: text, request: req)
        #expect(ranked.windows.map(\.id) == [2, 1, 3]) // duplicates and unknown ids dropped, Slack appended
        #expect(ranked.notes == "likes iTerm next to Claude")
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
    func anAppThatWillNotShrinkIsKeptOutOfNarrowSlots() {
        // Notes refuses to get narrower than 701 points; the laptop's right column is 605.
        var req = LayoutRequest(displays: [laptop], windows: [window(1, "claude", .coding, focused: true), window(2, "iterm", .coding), window(3, "notes", .other)],
                                recentApps: [], corrections: [], notes: "", localTime: "t", focusedWindowID: 1)
        let ranking = WindowRanking(windows: [RankedWindow(id: 1, role: .task, relevance: 3), RankedWindow(id: 2, role: .task, relevance: 2), RankedWindow(id: 3, role: .awareness, relevance: 1)], source: "test")
        #expect(LayoutTemplates.fill(LayoutTemplates.small[0], on: laptop, ranking: ranking, request: req).slots.contains { $0.window == 3 })
        req.minimumWidths = ["notes": 701]
        let choice = LayoutTemplates.fill(LayoutTemplates.small[0], on: laptop, ranking: ranking, request: req)
        #expect(!choice.slots.contains { $0.window == 3 })
        #expect(choice.stack == [3])
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
