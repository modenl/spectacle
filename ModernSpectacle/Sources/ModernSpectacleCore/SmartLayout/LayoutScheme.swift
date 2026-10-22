import CoreGraphics
import Foundation

/// Which layouts each kind of display gets, as data: the built-in copy below, or a newer one pushed from the server
/// (signed; see SchemeSignature). Every part is checked before use, and anything unusable falls back to the built-in
/// copy, so a bad push can make a layout less good but never breaks arranging.
///
/// A column is written `[share, slot, slot…]`. A slot is a name, `!` after it marks an awareness slot, and `:number`
/// gives its height share within the column: `"side-bottom!:0.4"`.
public struct LayoutScheme: Codable, Equatable, Sendable {
    public struct DisplayClass: Codable, Equatable, Sendable {
        public var id: String
        public var minWidth: Double?
        public var maxWidth: Double?
        public var minAspect: Double?
        public var maxAspect: Double?

        public init(id: String, minWidth: Double? = nil, maxWidth: Double? = nil, minAspect: Double? = nil, maxAspect: Double? = nil) {
            self.id = id
            self.minWidth = minWidth
            self.maxWidth = maxWidth
            self.minAspect = minAspect
            self.maxAspect = maxAspect
        }

        func matches(width: Double, height: Double) -> Bool {
            let aspect = width / max(height, 1)
            return (minWidth.map { width >= $0 } ?? true) && (maxWidth.map { width <= $0 } ?? true)
                && (minAspect.map { aspect >= $0 } ?? true) && (maxAspect.map { aspect <= $0 } ?? true)
        }
    }

    /// A number (a column's share) or a slot.
    public enum Item: Codable, Equatable, Sendable {
        case number(Double)
        case text(String)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) { self = .number(number) } else { self = .text(try container.decode(String.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .number(number): try container.encode(number)
            case let .text(text): try container.encode(text)
            }
        }
    }

    public struct Template: Codable, Equatable, Sendable {
        public var id: String
        public var title: [String: String]
        public var columns: [[Item]]
    }

    public struct Readability: Codable, Equatable, Sendable {
        public var browser: Double?
        public var coding: Double?
        public var other: Double?
    }

    /// Increases with every published scheme; an older one is never accepted after a newer one.
    public var serial: Int
    public var version: String
    public var displayClasses: [DisplayClass]
    public var templates: [String: [Template]]
    public var readability: Readability?
}

/// A scheme after checking: ready to use.
public struct ResolvedScheme: Sendable {
    public var serial: Int
    public var version: String
    public var classes: [(displayClass: LayoutScheme.DisplayClass, templates: [LayoutTemplate])]
    public var readability: [AppKind: CGFloat]

    public func displayClass(width: CGFloat, height: CGFloat) -> (displayClass: LayoutScheme.DisplayClass, templates: [LayoutTemplate]) {
        classes.first { $0.displayClass.matches(width: Double(width), height: Double(height)) } ?? classes[classes.count - 1]
    }

    public var allTemplates: [LayoutTemplate] { classes.flatMap(\.templates) }
}

public enum SchemeLoader {
    /// Hard floors: a pushed scheme may ask for wider slots, never narrower ones.
    public static let readabilityFloor: [AppKind: CGFloat] = [.browser: 560, .coding: 480, .other: 280]
    /// Lowercase letters, digits and dashes, starting with a letter or digit.
    static func isValidID(_ id: String, maxLength: Int = 32) -> Bool {
        guard let first = id.first, !id.isEmpty, id.count <= maxLength, first != "-" else { return false }
        return id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    public static func decode(_ data: Data) throws -> LayoutScheme {
        try JSONDecoder().decode(LayoutScheme.self, from: data)
    }

    /// Checks every part. Unusable templates are dropped with a reason; a display class left without templates takes
    /// the built-in templates for that class; a scheme without a catch-all class gets the built-in one appended.
    public static func resolve(_ scheme: LayoutScheme, fallback: ResolvedScheme? = nil) -> (scheme: ResolvedScheme, problems: [String]) {
        var problems: [String] = []
        var seen = Set<String>()
        var classes: [(LayoutScheme.DisplayClass, [LayoutTemplate])] = []

        for displayClass in scheme.displayClasses.prefix(8) {
            guard isValidID(displayClass.id) else {
                problems.append("display class \"\(displayClass.id)\": bad id")
                continue
            }
            var templates: [LayoutTemplate] = []
            for spec in (scheme.templates[displayClass.id] ?? []) {
                switch template(from: spec) {
                case let .success(template):
                    if seen.contains(template.id) { problems.append("template \(template.id): duplicate id"); continue }
                    seen.insert(template.id)
                    templates.append(template)
                case let .failure(problem):
                    problems.append("template \(spec.id): \(problem.message)")
                }
            }
            if templates.count > 5 {
                problems.append("display class \(displayClass.id): more than 5 templates, extra ones dropped")
                templates = Array(templates.prefix(5))
            }
            if templates.isEmpty, let builtIn = fallback?.classes.first(where: { $0.displayClass.id == displayClass.id })?.templates {
                problems.append("display class \(displayClass.id): no usable template, built-in ones used")
                templates = builtIn
            }
            if templates.isEmpty {
                problems.append("display class \(displayClass.id): no usable template, class dropped")
                continue
            }
            classes.append((displayClass, templates))
        }
        let isCatchAll = { (c: LayoutScheme.DisplayClass) in c.minWidth == nil && c.maxWidth == nil && c.minAspect == nil && c.maxAspect == nil }
        if !classes.contains(where: { isCatchAll($0.0) }) {
            problems.append("no display class without limits; the built-in catch-all is used")
            if let catchAll = fallback?.classes.last { classes.append(catchAll) }
        }

        var readability: [AppKind: CGFloat] = [:]
        let asked: [(AppKind, Double?, CGFloat)] = [(.browser, scheme.readability?.browser, 640), (.coding, scheme.readability?.coding, 520), (.other, scheme.readability?.other, 300)]
        for (kind, value, standard) in asked {
            let floor = readabilityFloor[kind]!
            let wanted = value.map { CGFloat($0) } ?? standard
            if wanted < floor { problems.append("readability \(kind.rawValue): \(Int(wanted)) is below the floor \(Int(floor))") }
            readability[kind] = min(max(wanted, floor), 1200)
        }
        return (ResolvedScheme(serial: scheme.serial, version: scheme.version, classes: classes, readability: readability), problems)
    }

    private struct Problem: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    private static func template(from spec: LayoutScheme.Template) -> Result<LayoutTemplate, Problem> {
        guard isValidID(spec.id) else { return .failure(Problem("bad id")) }
        guard (1...4).contains(spec.columns.count) else { return .failure(Problem("needs 1 to 4 columns")) }
        var columns: [TemplateColumn] = []
        var slotIDs = Set<String>()
        for column in spec.columns {
            guard case let .number(share)? = column.first, share > 0, share.isFinite else { return .failure(Problem("a column must start with its share")) }
            let names = column.dropFirst().compactMap { item -> String? in if case let .text(text) = item { text } else { nil } }
            guard names.count == column.count - 1, (1...4).contains(names.count) else { return .failure(Problem("a column needs 1 to 4 slots")) }
            var slots: [TemplateSlot] = []
            for name in names {
                guard let slot = parseSlot(name) else { return .failure(Problem("bad slot \"\(name)\"")) }
                guard slotIDs.insert(slot.id).inserted else { return .failure(Problem("slot \(slot.id) appears twice")) }
                slots.append(slot)
            }
            columns.append(TemplateColumn(share: share, slots: slots))
        }
        let total = columns.map(\.share).reduce(0, +)
        guard columns.allSatisfy({ $0.share / total >= 0.1 }) else { return .failure(Problem("every column needs at least 10% of the width")) }
        guard slotIDs.contains("main") else { return .failure(Problem("needs a slot called main")) }
        let mainShare = columns.first { $0.slots.contains { $0.id == "main" } }!.share / total
        guard mainShare >= 0.25 || columns.count >= 3 && mainShare >= 0.2 else { return .failure(Problem("main is too narrow")) }
        let titles = spec.title.filter { ["en", "zh"].contains($0.key) && !$0.value.isEmpty && $0.value.count <= 40 }
        guard titles["en"] != nil else { return .failure(Problem("needs an English title of at most 40 characters")) }
        return .success(LayoutTemplate(id: spec.id, description: titles["en"]!, columns: columns, titles: titles))
    }

    /// "name", "name!" (awareness), "name:0.4" (height share), "name!:0.4".
    static func parseSlot(_ text: String) -> TemplateSlot? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        var name = parts[0]
        let awareness = name.hasSuffix("!")
        if awareness { name.removeLast() }
        guard isValidID(name, maxLength: 24) else { return nil }
        var share = 1.0
        if parts.count == 2 {
            guard let value = Double(parts[1]), value > 0, value.isFinite else { return nil }
            share = value
        }
        return TemplateSlot(name, share: share, awareness: awareness)
    }

    /// The layouts the app ships with, used until a newer signed scheme arrives and whenever one is unusable.
    public static let builtIn: ResolvedScheme = {
        let scheme = try! decode(Data(builtInJSON.utf8))
        let (resolved, problems) = resolve(scheme)
        precondition(problems.isEmpty, "built-in scheme: \(problems)")
        return resolved
    }()

    public static let builtInJSON = """
    {
      "serial": 1,
      "version": "2026.10.22",
      "displayClasses": [
        {"id": "portrait", "maxAspect": 0.9},
        {"id": "small", "maxWidth": 1599},
        {"id": "standard", "maxWidth": 2999},
        {"id": "wide"}
      ],
      "templates": {
        "portrait": [
          {"id": "portrait-main-2", "title": {"en": "Main · Two below", "zh": "上主 · 下两格"}, "columns": [[1, "main:0.55", "below:0.25", "bottom!:0.2"]]},
          {"id": "portrait-2row", "title": {"en": "Two rows", "zh": "上下两栏"}, "columns": [[1, "main", "second"]]},
          {"id": "portrait-monocle", "title": {"en": "One window", "zh": "单窗口"}, "columns": [[1, "main"]]}
        ],
        "small": [
          {"id": "small-main-2", "title": {"en": "Main · Two on the right", "zh": "左主 · 右上下"}, "columns": [[0.6, "main"], [0.4, "side-top", "side-bottom!"]]},
          {"id": "small-2col", "title": {"en": "Two columns", "zh": "左右两栏"}, "columns": [[0.55, "main"], [0.45, "second"]]},
          {"id": "small-monocle", "title": {"en": "One window", "zh": "单窗口"}, "columns": [[1, "main"]]}
        ],
        "standard": [
          {"id": "std-main-2", "title": {"en": "Main · Two on the right", "zh": "左主 · 右上下"}, "columns": [[0.6, "main"], [0.4, "side-top", "side-bottom!"]]},
          {"id": "std-2col", "title": {"en": "Two columns", "zh": "左右两栏"}, "columns": [[0.5, "main"], [0.5, "second"]]},
          {"id": "std-grid-4", "title": {"en": "Grid", "zh": "平铺"}, "columns": [[1, "main", "grid-3"], [1, "grid-2", "grid-4"]]}
        ],
        "wide": [
          {"id": "wide-1-1-n", "title": {"en": "Left · Main · Right column", "zh": "左1 · 中1 · 右n"}, "columns": [[0.22, "left"], [0.48, "main"], [0.30, "right-1!", "right-2!", "right-3!"]]},
          {"id": "wide-1-2-n", "title": {"en": "Left · Two main · Right column", "zh": "左1 · 中2 · 右n"}, "columns": [[0.2, "left"], [0.3, "main"], [0.3, "second"], [0.2, "right-1!", "right-2!", "right-3!"]]},
          {"id": "wide-grid-6", "title": {"en": "Grid", "zh": "平铺"}, "columns": [[1, "main", "grid-4"], [1, "grid-2", "grid-5"], [1, "grid-3", "grid-6"]]}
        ]
      },
      "readability": {"browser": 640, "coding": 520, "other": 300}
    }
    """
}
