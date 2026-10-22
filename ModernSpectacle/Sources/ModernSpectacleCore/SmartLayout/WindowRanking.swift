import Foundation

/// What a window is to the current task: worked in, kept an eye on, or not needed now.
public enum WindowRole: String, Codable, CaseIterable, Sendable {
    case task
    case awareness
    case background
}

public struct RankedWindow: Codable, Equatable, Sendable {
    public var id: Int
    public var role: WindowRole
    /// Higher is more relevant to what the person is doing now.
    public var relevance: Double

    public init(id: Int, role: WindowRole, relevance: Double) {
        self.id = id
        self.role = role
        self.relevance = relevance
    }
}

/// The model's whole job: which windows matter now, in order, and in what role. Templates and frames are local, so
/// switching templates or bringing a window to main never waits for the model.
public struct WindowRanking: Codable, Equatable, Sendable {
    /// Most relevant first.
    public var windows: [RankedWindow]
    /// Who ranked: "jev", "claude" or "local".
    public var source: String
    /// Notes the model keeps about the person across runs (Claude only; Jev answers questions, it does not write).
    public var notes: String?

    public init(windows: [RankedWindow], source: String, notes: String? = nil) {
        self.windows = windows
        self.source = source
        self.notes = notes
    }

    /// Sorted by relevance, ties broken by how recently each window had focus.
    public static func sorted(_ windows: [RankedWindow], request: LayoutRequest, source: String, notes: String? = nil) -> WindowRanking {
        let recency = Dictionary(request.windows.map { ($0.id, $0.lastFocusedSecondsAgo ?? $0.appActiveSecondsAgo ?? .max) }, uniquingKeysWith: { a, _ in a })
        let ordered = windows.sorted { a, b in
            if a.relevance != b.relevance { return a.relevance > b.relevance }
            let (ra, rb) = (recency[a.id] ?? .max, recency[b.id] ?? .max)
            return ra != rb ? ra < rb : a.id < b.id
        }
        return WindowRanking(windows: ordered, source: source, notes: notes)
    }

    /// A ranking made for an earlier snapshot, re-expressed with the ids of the windows open now (ids are only stable
    /// within one snapshot). Windows are matched by title, then by app.
    public func translated(from old: [WindowInfo], to new: [WindowInfo]) -> WindowRanking {
        let keyOf = Dictionary(old.map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        let keys = windows.compactMap { keyOf[$0.id] }
        let idOf = LayoutTemplates.match(keys: keys, in: new)
        let mapped = windows.compactMap { ranked in keyOf[ranked.id].flatMap { idOf[$0] }.map { RankedWindow(id: $0, role: ranked.role, relevance: ranked.relevance) } }
        return WindowRanking(windows: mapped, source: source, notes: notes)
    }

    /// Ids in the order given, with any window the ranker left out appended by recency.
    public func covering(_ request: LayoutRequest) -> WindowRanking {
        let known = Set(windows.map(\.id))
        let missing = request.windows.filter { !known.contains($0.id) }
        let fallback = LocalRanker.rank(LayoutRequest(displays: request.displays, windows: missing, recentApps: request.recentApps, corrections: [], notes: "", localTime: request.localTime, focusedWindowID: request.focusedWindowID))
        let present = Set(request.windows.map(\.id))
        return WindowRanking(windows: windows.filter { present.contains($0.id) } + fallback.windows, source: source, notes: notes)
    }
}

/// Ranking without a model: the focused window, then by how recently each window or its app had focus. Roles come from
/// the kind of app. Used when no model key is set and whenever the model cannot be reached.
public enum LocalRanker {
    public static func rank(_ request: LayoutRequest) -> WindowRanking {
        let windows = request.windows.map { window -> RankedWindow in
            let seconds = Double(window.lastFocusedSecondsAgo ?? window.appActiveSecondsAgo ?? 86_400)
            var relevance = 1 / (1 + seconds / 60)
            if window.id == request.focusedWindowID { relevance = 2 }
            let role: WindowRole
            switch window.kind {
            case .coding, .browser: role = seconds < 3600 || window.id == request.focusedWindowID ? .task : .background
            case .chat: role = .awareness
            case .files, .media, .other: role = seconds < 600 ? .awareness : .background
            }
            return RankedWindow(id: window.id, role: role, relevance: relevance)
        }
        return WindowRanking.sorted(windows, request: request, source: "local")
    }
}
