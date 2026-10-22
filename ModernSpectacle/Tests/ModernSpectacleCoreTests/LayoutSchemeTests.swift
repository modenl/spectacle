import CoreGraphics
import Foundation
import Testing
@testable import ModernSpectacleCore

@Suite
struct LayoutSchemeTests {
    private func scheme(_ json: String) throws -> LayoutScheme {
        try SchemeLoader.decode(Data(json.utf8))
    }

    @Test
    func theBuiltInSchemeIsValidAndCoversEveryKindOfDisplay() {
        let builtIn = SchemeLoader.builtIn
        #expect(builtIn.classes.map(\.displayClass.id) == ["portrait", "small", "standard", "wide"])
        #expect(builtIn.displayClass(width: 1080, height: 1890).displayClass.id == "portrait")
        #expect(builtIn.displayClass(width: 1512, height: 871).displayClass.id == "small")
        #expect(builtIn.displayClass(width: 1920, height: 1092).displayClass.id == "standard")
        #expect(builtIn.displayClass(width: 3440, height: 1319).displayClass.id == "wide")
        #expect(builtIn.allTemplates.allSatisfy { $0.titles["en"] != nil && $0.titles["zh"] != nil })
    }

    @Test
    func slotsReadNameAwarenessAndHeight() {
        #expect(SchemeLoader.parseSlot("main") == TemplateSlot("main"))
        #expect(SchemeLoader.parseSlot("side-bottom!") == TemplateSlot("side-bottom", awareness: true))
        #expect(SchemeLoader.parseSlot("bottom!:0.2") == TemplateSlot("bottom", share: 0.2, awareness: true))
        #expect(SchemeLoader.parseSlot("Main") == nil)
        #expect(SchemeLoader.parseSlot("main:-1") == nil)
        #expect(SchemeLoader.parseSlot("main:abc") == nil)
    }

    @Test
    func unusableTemplatesAreDroppedWithAReason() throws {
        let pushed = try scheme("""
        {"serial": 2, "version": "x", "displayClasses": [{"id": "small", "maxWidth": 1599}, {"id": "wide"}],
         "templates": {
           "small": [
             {"id": "ok", "title": {"en": "Fine"}, "columns": [[0.6, "main"], [0.4, "side"]]},
             {"id": "no-main", "title": {"en": "x"}, "columns": [[1, "left"]]},
             {"id": "sliver", "title": {"en": "x"}, "columns": [[0.95, "main"], [0.05, "side"]]},
             {"id": "twice", "title": {"en": "x"}, "columns": [[0.5, "main"], [0.5, "main"]]},
             {"id": "Bad Id", "title": {"en": "x"}, "columns": [[1, "main"]]},
             {"id": "five", "title": {"en": "x"}, "columns": [[1, "main"], [1, "a"], [1, "b"], [1, "c"], [1, "d"]]},
             {"id": "no-title", "title": {"zh": "无"}, "columns": [[1, "main"]]}
           ],
           "wide": [{"id": "w", "title": {"en": "W"}, "columns": [[1, "main"]]}]
         }}
        """)
        let (resolved, problems) = SchemeLoader.resolve(pushed, fallback: SchemeLoader.builtIn)
        #expect(resolved.classes[0].templates.map(\.id) == ["ok"])
        #expect(problems.count == 6)
        #expect(problems.contains { $0.contains("no-main") && $0.contains("main") })
        #expect(problems.contains { $0.contains("sliver") && $0.contains("10%") })
    }

    @Test
    func readabilityCanBeRaisedButNotLowered() throws {
        let pushed = try scheme("""
        {"serial": 2, "version": "x", "displayClasses": [{"id": "wide"}],
         "templates": {"wide": [{"id": "w", "title": {"en": "W"}, "columns": [[1, "main"]]}]},
         "readability": {"browser": 700, "coding": 100}}
        """)
        let (resolved, problems) = SchemeLoader.resolve(pushed, fallback: SchemeLoader.builtIn)
        #expect(resolved.readability[.browser] == 700)
        #expect(resolved.readability[.coding] == 480) // the floor
        #expect(problems.contains { $0.contains("coding") })
    }

    @Test
    func missingPiecesFallBackToTheBuiltInScheme() throws {
        // No catch-all class, and a class whose only template is unusable.
        let pushed = try scheme("""
        {"serial": 3, "version": "x", "displayClasses": [{"id": "small", "maxWidth": 1599}],
         "templates": {"small": [{"id": "bad", "title": {"en": "x"}, "columns": [[1, "left"]]}]}}
        """)
        let (resolved, problems) = SchemeLoader.resolve(pushed, fallback: SchemeLoader.builtIn)
        #expect(resolved.classes.first?.templates.map(\.id) == SchemeLoader.builtIn.classes[1].templates.map(\.id))
        #expect(resolved.displayClass(width: 5000, height: 2000).templates.isEmpty == false) // a catch-all was added
        #expect(problems.count == 3)
    }

    @Test
    func aPortraitTemplateStacksRows() {
        let portrait = SchemeLoader.builtIn.classes[0].templates[0]
        let frames = LayoutTemplates.slotFrames(of: portrait, in: CGRect(x: 0, y: 0, width: 1080, height: 1800))
        #expect(frames.map(\.slot.id) == ["main", "below", "bottom"])
        #expect(frames[0].rect.height == 990 && frames[0].rect.width == 1080)
        #expect(frames[2].slot.awareness)
    }
}
