import Foundation

/// What either model sees: the desktop as the person is using it right now. Window geometry is left out on purpose:
/// where windows go is decided locally from the template.
public struct RankingState: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var id: Int
        public var app: String
        public var title: String
        public var kind: AppKind
        public var focused: Bool
        public var lastFocusedSecondsAgo: Int?
        public var appActiveSecondsAgo: Int?
    }

    public var windows: [Window]
    /// Newest first: "App – window title, 40s in front".
    public var recentSwitches: [String]
    public var localTime: String
    public var notes: String

    public init(_ request: LayoutRequest) {
        windows = request.windows.map {
            Window(id: $0.id, app: $0.app, title: $0.title, kind: $0.kind, focused: $0.id == request.focusedWindowID,
                   lastFocusedSecondsAgo: $0.lastFocusedSecondsAgo, appActiveSecondsAgo: $0.appActiveSecondsAgo)
        }
        recentSwitches = request.focusTimeline.prefix(12).map { "\($0.app) – \($0.window), \($0.dwellSeconds)s in front, \($0.secondsAgo)s ago" }
        localTime = request.localTime
        notes = request.notes
    }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// Claude: one call returns every window in order with its role, plus updated notes.
public enum ClaudeRankingPrompt {
    public static let systemPrompt = """
    You help arrange macOS windows for one person by deciding which windows matter right now. You receive the open \
    windows (id, app, title, kind, which one has focus, how long ago each had focus), the most recent app switches with \
    how long each stayed in front, and your own notes from earlier runs.

    Infer the person's current task from the focused window, the switches and the titles. Then return every window, \
    most relevant first, each with a role:
    - "task": needed for the current task, worth a visible place next to the main window (the editor, terminal or AI \
    assistant they are working with, docs or a browser showing the same project).
    - "awareness": something they keep an eye on but do not work in (chat, mail, calendar, monitors, music).
    - "background": not needed now.
    The focused window comes first. Windows the person keeps switching between come right after it. Something untouched \
    for hours is background unless its title ties it to the current task.

    Also return "notes": a few short lines about this person's habits worth remembering next time (keep and update the \
    notes you were given; at most 600 characters). JSON only, matching the schema.
    """

    public static let outputSchemaJSON = """
    {
      "type": "object",
      "properties": {
        "windows": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "id": {"type": "integer"},
              "role": {"type": "string", "enum": ["task", "awareness", "background"]}
            },
            "required": ["id", "role"],
            "additionalProperties": false
          }
        },
        "notes": {"type": "string"}
      },
      "required": ["windows", "notes"],
      "additionalProperties": false
    }
    """

    struct Answer: Decodable {
        struct Item: Decodable {
            var id: Int
            var role: WindowRole
        }
        var windows: [Item]
        var notes: String
    }

    /// The model's order is the ranking; relevance just encodes the position.
    public static func ranking(fromModelJSON text: String, request: LayoutRequest) throws -> WindowRanking {
        let answer = try JSONDecoder().decode(Answer.self, from: Data(text.utf8))
        var seen = Set<Int>()
        let items = answer.windows.filter { seen.insert($0.id).inserted }
        let windows = items.enumerated().map { RankedWindow(id: $1.id, role: $1.role, relevance: Double(items.count - $0)) }
        return WindowRanking(windows: windows, source: "claude", notes: answer.notes).covering(request)
    }
}

/// Jev (TypeSafe's decision model): two typed questions per window, all answered in parallel in one request.
/// A score for relevance and a choice for the role; the ranking is the scores sorted.
public enum JevRankingRequest {
    public static let model = "jev-latest"
    static let relevanceLevels = [
        "Unrelated to what the person is doing now",
        "Might be useful later",
        "Related to the current task",
        "In use right now, together with the focused window",
    ]
    static let roles: [WindowRole: String] = [
        .task: "Needed for the current task: keep it visible next to the main window",
        .awareness: "Kept an eye on but not worked in: chat, mail, calendar, monitors, music",
        .background: "Not needed now: can wait hidden",
    ]

    public struct Question: Codable, Equatable, Sendable {
        public enum Criteria: Codable, Equatable, Sendable {
            case levels([String])
            case options([String: String])

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case let .levels(levels): try container.encode(levels)
                case let .options(options): try container.encode(options)
                }
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let levels = try? container.decode([String].self) { self = .levels(levels) }
                else { self = .options(try container.decode([String: String].self)) }
            }
        }

        public var type: String
        public var instructions: String
        public var criteria: Criteria
    }

    public struct Body: Codable, Equatable, Sendable {
        public var model: String
        public var state: RankingState
        public var questions: [String: Question]
    }

    public static func body(for request: LayoutRequest) -> Body {
        var questions: [String: Question] = [:]
        for window in request.windows {
            let name = "window \(window.id) (\(window.app): \(window.title))"
            questions["relevance-\(window.id)"] = Question(
                type: "score",
                instructions: "How relevant is \(name) to what the person is doing right now, judging by the focused window, the recent switches and the titles?",
                criteria: .levels(relevanceLevels)
            )
            questions["role-\(window.id)"] = Question(
                type: "choice",
                instructions: "What place should \(name) get on screen?",
                criteria: .options(Dictionary(uniqueKeysWithValues: roles.map { ($0.key.rawValue, $0.value) }))
            )
        }
        return Body(model: model, state: RankingState(request), questions: questions)
    }

    struct Response: Decodable {
        struct Answer: Decodable {
            var type: String
            var score: Double?
            var choice: String?
        }
        var model: String?
        var answers: [String: Answer]
    }

    public static func ranking(fromResponse data: Data, request: LayoutRequest) throws -> WindowRanking {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let windows = request.windows.map { window -> RankedWindow in
            let score = response.answers["relevance-\(window.id)"]?.score ?? 0
            let role = response.answers["role-\(window.id)"]?.choice.flatMap(WindowRole.init(rawValue:)) ?? .background
            return RankedWindow(id: window.id, role: role, relevance: score)
        }
        return WindowRanking.sorted(windows, request: request, source: "jev")
    }
}
