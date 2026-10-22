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
    func completedPlanTilesWindowsOnADisplayTheModelIgnored() {
        let second = DisplayInfo(id: 1, visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), isMain: false)
        var b = window(2, .media, bundle: "b"); b.displayID = 1
        var c = window(3, .media, bundle: "c"); c.displayID = 1
        let req = LayoutRequest(displays: [display, second], windows: [window(1, .coding, bundle: "a"), b, c], recentApps: [], corrections: [], notes: "", localTime: "t")
        let plan = LayoutPlan(summary: "", notes: "", placements: [Placement(id: 1, group: "column1", rect: display.visibleFrame)])
        let full = PlanValidator.completed(plan, for: req)
        let added = full.placements.filter { $0.group == "background" }
        #expect(added.map(\.id) == [2, 3])
        #expect(added[0].rect.area + added[1].rect.area == second.visibleFrame.area)
        #expect(!added[0].rect.intersects(added[1].rect))
    }

    @Test
    func composerTurnsSharesIntoAnExactTiling() {
        let req = request([window(1, .coding, bundle: "a", focused: true), window(2, .browser, bundle: "b"), window(3, .chat, bundle: "c"), window(4, .files, bundle: "f")])
        let design = LayoutDesign(summary: "s", notes: "n", displays: [
            DisplayDesign(id: 0, columns: [
                ColumnDesign(share: 3, windows: [WindowSlot(id: 1, share: 1)]),
                ColumnDesign(share: 2, windows: [WindowSlot(id: 2, share: 2), WindowSlot(id: 3, share: 1)]),
            ], cascade: [4]),
        ])
        let plan = LayoutComposer.plan(from: design, for: req)
        let a = plan.placements[0].rect, b = plan.placements[1].rect, c = plan.placements[2].rect
        #expect(a == CGRect(x: 0, y: 25, width: 864, height: 875))
        #expect(b.minX == 864 && b.maxX == 1440 && b.minY == 25)
        #expect(c.minX == 864 && c.minY == b.maxY && c.maxY == 900)
        #expect(a.area + b.area + c.area == display.visibleFrame.area)
        #expect(abs(b.height - 875 * 2 / 3) < 1)
        #expect(plan.placements[3].group == "cascade")
    }

    @Test
    func composerCascadesOnlyFilesAndFixedSizeWindows() {
        var calculator = window(4, .other, bundle: "calc")
        calculator.resizable = false
        let req = request([window(1, .coding, bundle: "a"), window(2, .coding, bundle: "codex"), window(3, .files, bundle: "f"), calculator, window(5, .other, bundle: "monitor")])
        let design = LayoutDesign(summary: "", notes: "", displays: [
            DisplayDesign(id: 0, columns: [ColumnDesign(share: 1, windows: [WindowSlot(id: 1, share: 1)])], cascade: [2, 3, 4]),
        ])
        let plan = LayoutComposer.plan(from: design, for: req)
        let group = { (id: Int) in plan.placements.first { $0.id == id }?.group }
        #expect(group(2) == "column1") // work window pulled out of the cascade
        #expect(group(3) == "cascade") // Finder may cascade
        #expect(group(4) == "cascade") // fixed size keeps its size in the corner
        #expect(plan.placements.first { $0.id == 4 }?.rect.size == calculator.frame.cgRect.size)
        #expect(group(5) == "peek") // forgotten by the design: background, so it peeks
        #expect(plan.placements.count == 5)
        let column = plan.placements.filter { $0.group == "column1" }
        #expect(column.map(\.rect.height).reduce(0, +) == display.visibleFrame.height)
    }

    @Test
    func composerPeeksBackgroundWindowsBehindTheTiles() {
        var req = request([window(1, .coding, bundle: "a", focused: true), window(2, .other, bundle: "notes"), window(3, .other, bundle: "monitor"), window(4, .chat, bundle: "slack")])
        req.focusedWindowID = 1
        let design = LayoutDesign(summary: "", notes: "", displays: [
            DisplayDesign(id: 0, columns: [ColumnDesign(share: 1, windows: [WindowSlot(id: 1, share: 1)])], peek: [2, 3, 1], cascade: []),
        ])
        let plan = LayoutComposer.plan(from: design, for: req)
        let tile = plan.placements.first { $0.id == 1 }!
        let strip = LayoutComposer.peekStripWidth(for: display.visibleFrame)
        #expect(tile.group == "column1")
        #expect(tile.rect.maxX == display.visibleFrame.maxX - strip) // tiles leave the strip free
        let peeks = plan.placements.filter { $0.group == "peek" }
        #expect(peeks.map(\.id) == [2, 3, 4]) // 4 was forgotten by the design and peeks too; 1 is focused and never peeks
        for p in peeks {
            #expect(p.rect.maxX == display.visibleFrame.maxX)
            #expect(display.visibleFrame.contains(p.rect))
        }
        #expect(peeks[0].rect.minY > peeks[1].rect.minY) // the most useful one sits lowest, on top of the others
    }

    @Test
    func composerKeepsTheFocusedWindowLargest() {
        var req = request([window(1, .coding, bundle: "a", focused: true), window(2, .other, bundle: "b"), window(3, .browser, bundle: "c")])
        req.focusedWindowID = 1
        // The design makes the focused window the smallest thing on screen.
        let design = LayoutDesign(summary: "", notes: "", displays: [
            DisplayDesign(id: 0, columns: [
                ColumnDesign(share: 1, windows: [WindowSlot(id: 2, share: 3), WindowSlot(id: 1, share: 1)]),
                ColumnDesign(share: 3, windows: [WindowSlot(id: 3, share: 1)]),
            ], cascade: []),
        ])
        let plan = LayoutComposer.plan(from: design, for: req)
        let focused = plan.placements.first { $0.id == 1 }!.rect
        let sameColumn = plan.placements.first { $0.id == 2 }!.rect
        let otherColumn = plan.placements.first { $0.id == 3 }!.rect
        #expect(focused.height > sameColumn.height) // tallest in its column
        #expect(focused.width > otherColumn.width) // its column is the widest
    }

    @Test
    func composerDropsWrongDisplayAndDuplicateWindows() {
        let second = DisplayInfo(id: 1, visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), isMain: false)
        var onSecond = window(2, .browser, bundle: "b")
        onSecond.displayID = 1
        let req = LayoutRequest(displays: [display, second], windows: [window(1, .coding, bundle: "a"), onSecond], recentApps: [], corrections: [], notes: "", localTime: "t")
        let design = LayoutDesign(summary: "", notes: "", displays: [
            DisplayDesign(id: 0, columns: [ColumnDesign(share: 1, windows: [WindowSlot(id: 1, share: 1), WindowSlot(id: 2, share: 1), WindowSlot(id: 1, share: 1)])], cascade: []),
        ])
        let plan = LayoutComposer.plan(from: design, for: req)
        #expect(plan.placements.map(\.id) == [1])
        #expect(plan.placements[0].rect == display.visibleFrame)
    }

    @Test
    func promotionSwapsFocusedIntoMain() {
        let choice = DisplayChoice(id: 0, template: "wide-1-1-n", slots: [TemplateAssignment(slot: "main", window: 1), TemplateAssignment(slot: "left", window: 2)], stack: [3, 4], cascade: [])
        let fromSlot = LayoutTemplates.promoted(choice, focusedID: 2)
        #expect(fromSlot.slots == [TemplateAssignment(slot: "main", window: 2), TemplateAssignment(slot: "left", window: 1)])
        let fromStack = LayoutTemplates.promoted(choice, focusedID: 4)
        #expect(fromStack.slots.first { $0.slot == "main" }?.window == 4)
        // The old main stays in view in the slot next to main (left of center); its occupant goes behind.
        #expect(fromStack.slots.first { $0.slot == "left" }?.window == 1)
        #expect(fromStack.stack == [2, 3])
        #expect(LayoutTemplates.promoted(choice, focusedID: 1) == choice)
    }

    @Test
    func promotionOnALaptopSwapsWithTheSecondWindow() {
        // Claude main, iTerm top right, Chrome hidden behind. Bring Chrome to main: Claude moves to the nearest slot,
        // iTerm goes behind.
        let side = DisplayChoice(id: 0, template: "small-main-2", slots: [TemplateAssignment(slot: "main", window: 7), TemplateAssignment(slot: "side-top", window: 3)], stack: [6, 4])
        let promoted = LayoutTemplates.promoted(side, focusedID: 6)
        #expect(promoted.slots == [TemplateAssignment(slot: "main", window: 6), TemplateAssignment(slot: "side-top", window: 7)])
        #expect(promoted.stack == [3, 4])

        let twoColumns = DisplayChoice(id: 0, template: "small-2col", slots: [TemplateAssignment(slot: "main", window: 7), TemplateAssignment(slot: "second", window: 3)], stack: [6])
        #expect(LayoutTemplates.promoted(twoColumns, focusedID: 6).slots.first { $0.slot == "second" }?.window == 7)

        // Monocle has no other slot: the old main goes behind, first in line.
        let monocle = DisplayChoice(id: 0, template: "small-monocle", slots: [TemplateAssignment(slot: "main", window: 7)], stack: [6, 3])
        let alone = LayoutTemplates.promoted(monocle, focusedID: 3)
        #expect(alone.slots == [TemplateAssignment(slot: "main", window: 3)])
        #expect(alone.stack == [7, 6])

        // An empty side slot is simply filled.
        let empty = DisplayChoice(id: 0, template: "small-main-2", slots: [TemplateAssignment(slot: "main", window: 7)], stack: [6])
        #expect(LayoutTemplates.promoted(empty, focusedID: 6).slots == [TemplateAssignment(slot: "main", window: 6), TemplateAssignment(slot: "side-top", window: 7)])
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
