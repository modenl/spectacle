import Foundation

public struct ArrangementRecord: Codable, Equatable, Sendable {
    public var date: Date
    public var planner: String
    public var summary: String
    public var windowCount: Int
    /// Hotkey press to windows moved, in milliseconds.
    public var durationMs: Int?

    public init(date: Date, planner: String, summary: String, windowCount: Int, durationMs: Int? = nil) {
        self.date = date
        self.planner = planner
        self.summary = summary
        self.windowCount = windowCount
        self.durationMs = durationMs
    }
}

public struct ActivityRecord: Codable, Equatable, Sendable {
    public var bundleID: String
    public var app: String
    public var window: String
    public var date: Date

    public init(bundleID: String, app: String, window: String, date: Date) {
        self.bundleID = bundleID
        self.app = app
        self.window = window
        self.date = date
    }
}

/// What the planner learns between runs. Small JSON file; the model's notes plus the last corrections and arrangements.
public struct LayoutHistory: Codable, Equatable, Sendable {
    public static let maxCorrections = 30
    public static let maxArrangements = 50

    public var notes: String = ""
    public var corrections: [LayoutCorrection] = []
    public var arrangements: [ArrangementRecord] = []
    /// Learned from the user's own moves: how each app's windows should be arranged.
    public var appStyles: [String: ArrangementStyle] = [:]
    /// Recent app/window switches, newest first, so a relaunch still knows what the person was doing.
    public var activity: [ActivityRecord] = []
    /// Named layouts the user saved; restored with ⌃⌥⌘1…9 in this order.
    public var presets: [LayoutPreset] = []
    /// The template last chosen for each size of display ("wide", "standard", "small"); the next arrangement starts there.
    public var templateChoice: [String: String] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case notes, corrections, arrangements, appStyles, activity, presets, templateChoice
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        corrections = try container.decodeIfPresent([LayoutCorrection].self, forKey: .corrections) ?? []
        arrangements = try container.decodeIfPresent([ArrangementRecord].self, forKey: .arrangements) ?? []
        appStyles = try container.decodeIfPresent([String: ArrangementStyle].self, forKey: .appStyles) ?? [:]
        activity = try container.decodeIfPresent([ActivityRecord].self, forKey: .activity) ?? []
        presets = try container.decodeIfPresent([LayoutPreset].self, forKey: .presets) ?? []
        templateChoice = try container.decodeIfPresent([String: String].self, forKey: .templateChoice) ?? [:]
    }

    public mutating func record(_ correction: LayoutCorrection) {
        corrections.append(correction)
        if corrections.count > Self.maxCorrections {
            corrections.removeFirst(corrections.count - Self.maxCorrections)
        }
    }

    public mutating func record(_ arrangement: ArrangementRecord) {
        arrangements.append(arrangement)
        if arrangements.count > Self.maxArrangements {
            arrangements.removeFirst(arrangements.count - Self.maxArrangements)
        }
    }

    public static func load(from url: URL) -> LayoutHistory {
        guard let data = try? Data(contentsOf: url) else {
            return LayoutHistory()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LayoutHistory.self, from: data)) ?? LayoutHistory()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
