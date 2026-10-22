import CoreGraphics
import Foundation
import Testing
@testable import ModernSpectacleCore

@Suite
struct LayoutPresetTests {
    private let wide = DisplayInfo(id: 1, visibleFrame: CGRect(x: 0, y: 30, width: 3440, height: 1319), isMain: true)
    private let laptop = DisplayInfo(id: 2, visibleFrame: CGRect(x: 3440, y: 30, width: 1512, height: 920), isMain: false)

    private func window(_ id: Int, _ bundle: String, _ title: String, _ kind: AppKind = .coding, display: Int = 1, focused: Bool = false, focusedAgo: Int? = nil) -> WindowInfo {
        WindowInfo(
            id: id, app: bundle, bundleID: bundle, kind: kind, title: title,
            frame: CGRect(x: 100, y: 100, width: 800, height: 600), displayID: display, isFocused: focused,
            appActiveSecondsAgo: nil, lastFocusedSecondsAgo: focusedAgo
        )
    }

    private func request(_ windows: [WindowInfo], displays: [DisplayInfo]? = nil) -> LayoutRequest {
        var req = LayoutRequest(displays: displays ?? [wide], windows: windows, recentApps: [], corrections: [], notes: "", localTime: "t")
        req.focusedWindowID = windows.first { $0.isFocused }?.id
        return req
    }

    private var codingPreset: LayoutPreset {
        let req = request([
            window(1, "code", "spectacle"), window(2, "term", "zsh"), window(3, "claude", "Claude"),
            window(4, "slack", "general", .chat), window(5, "mail", "Inbox", .chat),
        ])
        let choice = DisplayChoice(id: 1, template: "wide-1-1-n", slots: [
            TemplateAssignment(slot: "main", window: 1), TemplateAssignment(slot: "left", window: 2),
            TemplateAssignment(slot: "right-1", window: 3), TemplateAssignment(slot: "right-2", window: 4),
        ], stack: [5])
        return LayoutPresets.make(name: "Coding", from: [choice], request: req)!
    }

    @Test
    func roundTripPutsEveryWindowBackInItsSlot() {
        let preset = codingPreset
        #expect(preset.windowCount == 5)
        // New ids, and the user is focused on Slack: the preset still decides what is main.
        let now = request([
            window(11, "slack", "general", .chat, focused: true), window(12, "code", "spectacle"),
            window(13, "mail", "Inbox", .chat), window(14, "claude", "Claude"), window(15, "term", "zsh"),
        ])
        let (choices, moved) = LayoutPresets.restore(preset, for: now)
        #expect(choices.count == 1 && choices[0].template == "wide-1-1-n")
        let slotOf = Dictionary(uniqueKeysWithValues: choices[0].slots.map { ($0.window, $0.slot) })
        #expect(slotOf == [12: "main", 15: "left", 14: "right-1", 11: "right-2"])
        #expect(choices[0].stack == [13])
        #expect(moved.focusedWindowID == nil)

        let plan = LayoutComposer.plan(from: LayoutTemplates.design(from: TemplatePlan(summary: "", notes: "", displays: choices), for: moved), for: moved)
        let main = plan.placements.first { $0.id == 12 }!.rect
        #expect(main.minX > 0 && main.maxX < 3440) // centered, not taken over by the focused Slack window
        #expect(plan.placements.first { $0.id == 13 }?.group == "behind")
    }

    @Test
    func matchesByAppWhenTitlesChangedAndLeavesMissingAppsOut() {
        let now = request([
            window(21, "code", "other-project", focusedAgo: 300), window(22, "code", "spectacle-2", focusedAgo: 5),
            window(23, "term", "zsh"), window(24, "safari", "News", .browser),
        ])
        let (choices, moved) = LayoutPresets.restore(codingPreset, for: now)
        let slots = choices[0].slots
        #expect(slots.first { $0.slot == "main" }?.window == 22) // most recently focused Code window wins
        #expect(slots.first { $0.slot == "left" }?.window == 23)
        #expect(!slots.contains { $0.slot == "right-1" || $0.slot == "right-2" }) // Claude and Slack are not open
        #expect(choices[0].stack.isEmpty)

        // Windows the preset does not mention (the other Code window, Safari) wait behind, not tiled.
        let plan = LayoutComposer.plan(from: LayoutTemplates.design(from: TemplatePlan(summary: "", notes: "", displays: choices), for: moved), for: moved)
        #expect(plan.placements.first { $0.id == 21 }?.group == "behind")
        #expect(plan.placements.first { $0.id == 24 }?.group == "behind")
    }

    @Test
    func restoreMovesWindowsToThePresetsDisplay() {
        let both = [wide, laptop]
        let saved = request([window(1, "code", "spectacle"), window(2, "slack", "general", .chat, display: 2)], displays: both)
        let preset = LayoutPresets.make(name: "Two screens", from: [
            DisplayChoice(id: 1, template: "wide-1-1-n", slots: [TemplateAssignment(slot: "main", window: 1)]),
            DisplayChoice(id: 2, template: "small-monocle", slots: [TemplateAssignment(slot: "main", window: 2)]),
        ], request: saved)!

        // Slack has wandered onto the wide display since.
        let now = request([window(7, "code", "spectacle"), window(8, "slack", "general", .chat)], displays: both)
        let (choices, moved) = LayoutPresets.restore(preset, for: now)
        #expect(choices.map(\.id) == [1, 2])
        #expect(moved.windows.first { $0.id == 8 }?.displayID == 2)

        let plan = PlanValidator.sanitized(LayoutComposer.plan(from: LayoutTemplates.design(from: TemplatePlan(summary: "", notes: "", displays: choices), for: moved), for: moved), for: moved)
        #expect(laptop.visibleFrame.contains(plan.placements.first { $0.id == 8 }!.rect))
    }

    @Test
    func displaysAreMatchedBySizeClassWhenIdsChange() {
        let preset = codingPreset
        let replugged = DisplayInfo(id: 9, visibleFrame: CGRect(x: 0, y: 25, width: 3840, height: 2135), isMain: true)
        let mapping = LayoutPresets.displayMapping(for: preset, displays: [laptop, replugged])
        #expect(mapping[1]?.id == 9) // the laptop cannot take a wide template

        #expect(LayoutPresets.displayMapping(for: preset, displays: [laptop]).isEmpty)
    }

    @Test
    func savingReplacesByNameAndKeepsNineAtMost() {
        var presets: [LayoutPreset] = []
        for i in 1...10 {
            presets = LayoutPresets.saving(LayoutPreset(name: "p\(i)", date: Date(), displays: []), into: presets)
        }
        #expect(presets.count == LayoutPresets.maxPresets)
        #expect(presets.first?.name == "p2")

        let replaced = LayoutPresets.saving(LayoutPreset(name: "p5", date: .distantFuture, displays: []), into: presets)
        #expect(replaced.count == presets.count)
        #expect(replaced.firstIndex { $0.name == "p5" } == presets.firstIndex { $0.name == "p5" }) // keeps its number
        #expect(replaced.first { $0.name == "p5" }?.date == .distantFuture)
    }

    @Test
    func historyWithoutPresetsStillLoads() throws {
        let old = #"{"notes":"likes centered","corrections":[],"arrangements":[]}"#
        let history = try JSONDecoder().decode(LayoutHistory.self, from: Data(old.utf8))
        #expect(history.notes == "likes centered")
        #expect(history.presets.isEmpty)
    }
}

@Suite
struct LanguageTests {
    @Test
    func languageFollowsSystemUnlessChosen() {
        #expect(Localization.isChinese(.system, preferredLanguages: ["zh-Hans-CN", "en-US"]))
        #expect(Localization.isChinese(.system, preferredLanguages: ["zh-Hant-TW"]))
        #expect(!Localization.isChinese(.system, preferredLanguages: ["en-US", "zh-Hans"]))
        #expect(!Localization.isChinese(.system, preferredLanguages: []))
        #expect(Localization.isChinese(.chinese, preferredLanguages: ["en-US"]))
        #expect(!Localization.isChinese(.english, preferredLanguages: ["zh-Hans"]))
    }
}

@Suite
struct PlanReuseTests {
    private let display = DisplayInfo(id: 0, visibleFrame: CGRect(x: 0, y: 30, width: 1920, height: 1092), isMain: true)

    private func window(_ id: Int, _ bundle: String, _ kind: AppKind, focused: Bool = false) -> WindowInfo {
        WindowInfo(id: id, app: bundle, bundleID: bundle, kind: kind, title: bundle, frame: CGRect(x: 0, y: 30, width: 800, height: 600), displayID: 0, isFocused: focused, appActiveSecondsAgo: nil)
    }

    private func request(_ windows: [WindowInfo]) -> LayoutRequest {
        var req = LayoutRequest(displays: [display], windows: windows, recentApps: [], corrections: [], notes: "", localTime: "t")
        req.focusedWindowID = windows.first { $0.isFocused }?.id
        return req
    }

    @Test
    func terminalsFitALaptopSideColumnButBrowsersWaitBehind() {
        let laptop = DisplayInfo(id: 0, visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 871), isMain: true)
        var req = LayoutRequest(displays: [laptop], windows: [window(1, "claude", .coding, focused: true), window(2, "chrome", .browser), window(3, "term", .coding), window(4, "notes", .other)], recentApps: [], corrections: [], notes: "", localTime: "t")
        req.focusedWindowID = 1
        let choice = TemplatePlan(summary: "", notes: "", displays: [
            DisplayChoice(id: 0, template: "small-main-2", slots: [TemplateAssignment(slot: "main", window: 1), TemplateAssignment(slot: "side-top", window: 2), TemplateAssignment(slot: "side-bottom", window: 3)], stack: [4]),
        ])
        let design = LayoutTemplates.design(from: choice, for: req)
        let tiled = design.displays[0].columns.flatMap { $0.windows.map(\.id) }
        #expect(tiled == [1, 3]) // the 605-point side column keeps the terminal
        #expect(design.displays[0].peek == [4, 2]) // the plan's background first, the browser that did not fit after it
        #expect(design.displays[0].hideBackground)
    }

    @Test
    func validatedPlansKeepTheirChoicesForSavingAndPromotion() {
        let req = request([window(1, "a", .coding, focused: true)])
        let choices = [DisplayChoice(id: 0, template: "std-2col", slots: [TemplateAssignment(slot: "main", window: 1)])]
        let plan = LayoutPlan(summary: "", notes: "", placements: [Placement(id: 1, group: "column1", rect: display.visibleFrame)], choices: choices)
        #expect(PlanValidator.sanitized(plan, for: req).choices == choices)
        #expect(PlanValidator.completed(plan, for: req).choices == choices)
    }
}

@Suite
struct LaptopLayoutTests {
    private let laptop = DisplayInfo(id: 0, visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 871), isMain: true)

    private func window(_ id: Int, _ bundle: String, _ kind: AppKind, focused: Bool = false) -> WindowInfo {
        WindowInfo(id: id, app: bundle, bundleID: bundle, kind: kind, title: bundle, frame: CGRect(x: 100, y: 100, width: 700, height: 600), displayID: 0, isFocused: focused, appActiveSecondsAgo: nil)
    }

    @Test
    func laptopTemplatesHaveAtMostTwoColumnsAndNoStrip() {
        for template in LayoutTemplates.small {
            #expect(!template.hasStack)
            #expect(template.columns.count <= 2)
        }
    }

    @Test
    func backgroundWindowsHideFullyBehindTheTilesOnALaptop() {
        // The arrangement that looked messy: Claude and Chrome tiled, five windows in the stack.
        var req = LayoutRequest(displays: [laptop], windows: [
            window(7, "claude", .coding, focused: true), window(6, "chrome", .browser),
            window(3, "iterm", .coding), window(4, "sublime", .coding), window(5, "notes", .other), window(1, "activity", .other),
        ], recentApps: [], corrections: [], notes: "", localTime: "t")
        req.focusedWindowID = 7
        let choice = TemplatePlan(summary: "", notes: "", displays: [
            DisplayChoice(id: 0, template: "small-2col", slots: [TemplateAssignment(slot: "main", window: 7), TemplateAssignment(slot: "second", window: 6)], stack: [3, 4, 5, 1]),
        ])
        let plan = LayoutTemplates.plan(from: choice, for: req)
        let rect = { (id: Int) in plan.placements.first { $0.id == id }!.rect }
        // Two tiles share the whole width: nothing squeezes them, so Chrome keeps its readable 680 points.
        #expect(rect(7).minX == 0 && rect(6).maxX == 1512)
        #expect(rect(6).width >= LayoutTemplates.minimumWidth(for: .browser))
        // Everything else is exactly behind the tiles: nothing sticks out.
        for id in [3, 4, 5, 1] {
            #expect(plan.placements.first { $0.id == id }?.group == "behind")
            #expect(rect(id) == laptop.visibleFrame)
        }
    }
}

@Suite
struct PromotionMatchingTests {
    private let laptop = DisplayInfo(id: 0, visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 871), isMain: true)

    private func window(_ id: Int, _ bundle: String, _ title: String, _ kind: AppKind, focused: Bool = false) -> WindowInfo {
        WindowInfo(id: id, app: bundle, bundleID: bundle, kind: kind, title: title, frame: CGRect(x: 0, y: 33, width: 700, height: 600), displayID: 0, isFocused: focused, appActiveSecondsAgo: nil)
    }

    @Test
    func aTerminalWhoseTitleChangedIsStillTheSideWindow() {
        // Arranged with iTerm titled "-zsh"; by the time Bring to Main is pressed it is running a command.
        let stored = [(display: 0, template: "small-main-2", slots: [(slot: "main", key: "claude|Claude"), (slot: "side-top", key: "iterm|-zsh")], stack: ["chrome|Docs"], cascade: [String]())]
        let now = [window(1, "claude", "Claude", .coding), window(2, "iterm", "swift test — ModernSpectacle", .coding, focused: true), window(3, "chrome", "Docs", .browser)]
        let previous = LayoutTemplates.choices(fromKeys: stored, in: now)
        #expect(previous[0].slots == [TemplateAssignment(slot: "main", window: 1), TemplateAssignment(slot: "side-top", window: 2)])

        // So promoting it is a swap: Claude goes to the side, not to the background.
        let promoted = LayoutTemplates.promoted(previous[0], focusedID: 2)
        #expect(promoted.slots == [TemplateAssignment(slot: "main", window: 2), TemplateAssignment(slot: "side-top", window: 1)])
        #expect(promoted.stack == [3])
    }

    @Test
    func ambiguousTitlesAreNotGuessed() {
        // Two stored Chrome windows, both retitled, two open: each still finds one, nothing is dropped or doubled.
        let stored = [(display: 0, template: "small-2col", slots: [(slot: "main", key: "chrome|A"), (slot: "second", key: "chrome|B")], stack: [String](), cascade: [String]())]
        let now = [window(1, "chrome", "A", .browser), window(2, "chrome", "C", .browser)]
        let previous = LayoutTemplates.choices(fromKeys: stored, in: now)
        #expect(previous[0].slots == [TemplateAssignment(slot: "main", window: 1), TemplateAssignment(slot: "second", window: 2)])
    }

    @Test
    func aBrowserSwappedToTheSideGetsTheWiderTwoColumnLayout() {
        // Chrome was main, iTerm top right; bringing iTerm to main puts Chrome in a 605-point column: too narrow.
        var req = LayoutRequest(displays: [laptop], windows: [window(1, "chrome", "Docs", .browser), window(2, "iterm", "zsh", .coding, focused: true)], recentApps: [], corrections: [], notes: "", localTime: "t")
        req.focusedWindowID = 2
        let previous = DisplayChoice(id: 0, template: "small-main-2", slots: [TemplateAssignment(slot: "main", window: 1), TemplateAssignment(slot: "side-top", window: 2)])
        let fitted = LayoutTemplates.fitted(LayoutTemplates.promoted(previous, focusedID: 2), for: req)
        #expect(fitted.template == "small-2col")
        #expect(fitted.slots == [TemplateAssignment(slot: "main", window: 2), TemplateAssignment(slot: "second", window: 1)])
        let plan = LayoutTemplates.plan(from: TemplatePlan(summary: "", notes: "", displays: [fitted]), for: req)
        #expect(plan.placements.first { $0.id == 1 }?.group == "column2") // Chrome stays visible

        // A terminal on the side fits as it is: no template change.
        let fine = DisplayChoice(id: 0, template: "small-main-2", slots: [TemplateAssignment(slot: "main", window: 1), TemplateAssignment(slot: "side-top", window: 2)])
        #expect(LayoutTemplates.fitted(fine, for: req) == fine)
    }
}
