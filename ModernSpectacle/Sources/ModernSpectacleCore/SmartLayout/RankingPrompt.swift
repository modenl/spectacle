import Foundation

/// What Jev sees: the desktop as the person is using it right now. Window geometry is left out on purpose:
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
        // Compact: fewer questions and fewer bytes make the answer faster.
        windows = request.windows.prefix(30).map {
            Window(id: $0.id, app: $0.app, title: String($0.title.prefix(50)), kind: $0.kind, focused: $0.id == request.focusedWindowID,
                   lastFocusedSecondsAgo: $0.lastFocusedSecondsAgo, appActiveSecondsAgo: $0.appActiveSecondsAgo)
        }
        recentSwitches = request.focusTimeline.prefix(6).map { "\($0.app) – \($0.window), \($0.dwellSeconds)s in front, \($0.secondsAgo)s ago" }
        localTime = request.localTime
        notes = String(request.notes.prefix(500))
    }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// Jev (TypeSafe's decision model): two typed questions per window, all answered in parallel in one request — a score
/// for relevance and a choice for the role. No prose comes back, which is what makes it fast enough for a key press.
public enum JevRequest {
    public static let model = "jev-latest"
    static let relevanceLevels = [
        "Unrelated to what the person is doing now",
        "Might be useful later",
        "Related to the current task",
        "In use right now, together with the focused window",
    ]
    static let roles: [String: String] = [
        WindowRole.task.rawValue: "Needed for the current task: keep it visible next to the main window",
        WindowRole.awareness.rawValue: "Kept an eye on but not worked in: chat, mail, calendar, monitors, music",
        WindowRole.background.rawValue: "Not needed now: can wait hidden",
    ]

    public struct Question: Encodable, Equatable, Sendable {
        public enum Criteria: Encodable, Equatable, Sendable {
            case levels([String])
            case options([String: String])

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case let .levels(levels): try container.encode(levels)
                case let .options(options): try container.encode(options)
                }
            }
        }

        public var type: String
        public var instructions: String
        public var criteria: Criteria
    }

    public struct Body: Encodable, Equatable, Sendable {
        public var model: String
        public var state: RankingState
        public var questions: [String: Question]
    }

    /// Windows are referred to by id; their titles are in the state, where they are data, never instructions.
    public static func body(for request: LayoutRequest) -> Body {
        let state = RankingState(request)
        var questions: [String: Question] = [:]
        for window in state.windows {
            questions["relevance-\(window.id)"] = Question(
                type: "score",
                instructions: "How relevant is window \(window.id) to what the person is doing right now, judging by the focused window, the recent switches and the titles?",
                criteria: .levels(relevanceLevels)
            )
            questions["role-\(window.id)"] = Question(
                type: "choice",
                instructions: "What place should window \(window.id) get on screen?",
                criteria: .options(roles)
            )
        }
        return Body(model: model, state: state, questions: questions)
    }

    struct Response: Decodable {
        struct Answer: Decodable {
            var score: Double?
            var choice: String?
        }
        var answers: [String: Answer]
    }

    /// Sorted by score, ties by recency. The focused window always comes first: it is what the person is working in.
    /// Windows Jev did not score are ranked locally after the scored ones.
    public static func ranking(fromResponse data: Data, request: LayoutRequest, source: String = "jev") throws -> WindowRanking {
        let answers = try JSONDecoder().decode(Response.self, from: data).answers
        let scored = request.windows.compactMap { window -> RankedWindow? in
            guard let score = answers["relevance-\(window.id)"]?.score, score.isFinite else { return nil }
            let role = answers["role-\(window.id)"]?.choice.flatMap(WindowRole.init(rawValue:)) ?? .background
            let focused = window.id == request.focusedWindowID
            return RankedWindow(id: window.id, role: focused ? .task : role, relevance: focused ? 1_000 : score)
        }
        return WindowRanking.sorted(scored, request: request, source: source).covering(request)
    }
}
