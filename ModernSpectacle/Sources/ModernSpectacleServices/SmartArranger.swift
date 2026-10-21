import AppKit
import ModernSpectacleCore

/// One hotkey: snapshot the desktop, get a plan (cached, from Claude, or the heuristic), apply it, and learn from
/// what the user moves afterwards. Plans are pre-computed in the background when the window set changes, so the
/// hotkey usually applies instantly.
@MainActor
public final class SmartArranger {
    public struct Status: Equatable, Sendable {
        public var message: String
        public var planner: String?
        public var date: Date?
    }

    public private(set) var status = Status(message: "Idle", planner: nil, date: nil)
    public var onStatusChange: ((Status) -> Void)?
    /// Pre-compute a plan whenever the window set changes. Costs one small API call per change.
    public var prewarmEnabled = true

    private let enumerator: WindowEnumerator
    private let windowController: WindowController
    // Only exists while a Claude API key is configured: without a key there are no smart features at all.
    private var windowObserver: WindowObserver?
    private let suggestion = SuggestionPanel()
    private let heuristic = HeuristicPlanner()
    private let claude: ClaudePlanner
    private let historyURL: URL
    private var history: LayoutHistory

    private var lastActive: [String: Date] = [:]
    private var recentApps: [String] = []
    private var cachedPlan: (signature: String, plan: LayoutPlan, planner: String, date: Date)?
    private var prewarmTask: Task<Void, Never>?
    private var correctionTask: Task<Void, Never>?
    private var inFlightSignature: String?
    private var observers: [NSObjectProtocol] = []
    /// Moves we make ourselves also arrive through the window observer; ignore them until this time.
    private var suppressObservationUntil = Date.distantPast
    /// Per app: titles the user moved or resized recently, so hand-tiling can be recognised across several drags.
    private var recentUserMoves: [pid_t: [String: Date]] = [:]
    private var suggestionCooldown: [String: Date] = [:]

    private static let cacheLifetime: TimeInterval = 15 * 60
    private static let correctionDelay: TimeInterval = 12
    private static let prewarmDebounce: TimeInterval = 5
    private static let userMoveMemory: TimeInterval = 45
    private static let suggestionCooldownInterval: TimeInterval = 10 * 60

    public init(
        windowController: WindowController,
        enumerator: WindowEnumerator = WindowEnumerator(),
        claude: ClaudePlanner = ClaudePlanner(),
        historyURL: URL = SmartArranger.defaultHistoryURL
    ) {
        self.windowController = windowController
        self.enumerator = enumerator
        self.claude = claude
        self.historyURL = historyURL
        history = LayoutHistory.load(from: historyURL)

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            let name = app?.localizedName
            Task { @MainActor in self?.noteActivation(bundleID: bundleID, name: name) }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.schedulePrewarm() }
            })
        }
        apiKeyDidChange()
    }

    /// Starts or stops the smart features depending on whether a key is present.
    public func apiKeyDidChange() {
        if usesClaude {
            if windowObserver == nil {
                let observer = WindowObserver()
                observer.onSettled = { [weak self] settled in
                    self?.handleUserMoves(settled)
                }
                windowObserver = observer
            }
            schedulePrewarm()
        } else {
            windowObserver = nil
            cachedPlan = nil
            prewarmTask?.cancel()
        }
    }

    public static var defaultHistoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ModernSpectacle/layout-history.json")
    }

    public var usesClaude: Bool { KeychainStore.hasAPIKey }

    // MARK: - Arrange

    public func arrange() async {
        guard usesClaude else {
            update("Smart Arrange needs a Claude API key (Settings)", planner: nil)
            return
        }
        guard AccessibilityPermission.isTrusted else {
            update("Accessibility permission required", planner: nil)
            return
        }

        let started = Date()
        let snapshot = enumerator.snapshot(lastActive: lastActive, now: started)
        let request = makeRequest(from: snapshot, now: started)
        guard !request.windows.isEmpty else {
            update("No windows to arrange", planner: nil)
            return
        }

        let (plan, plannerName) = await plan(for: request, allowNetwork: true)
        let safe = PlanValidator.sanitized(plan, for: request)
        apply(safe, to: snapshot)

        if plannerName == claude.name {
            history.notes = safe.notes
        }
        history.record(ArrangementRecord(date: started, planner: plannerName, summary: safe.summary, windowCount: safe.placements.count))
        saveHistory()

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        update("\(safe.summary) (\(plannerName), \(elapsed) ms)", planner: plannerName)
        watchForCorrections(after: safe, snapshot: snapshot)
    }

    private func plan(for request: LayoutRequest, allowNetwork: Bool) async -> (LayoutPlan, String) {
        let signature = request.signature
        if let cached = cachedPlan, cached.signature == signature, Date().timeIntervalSince(cached.date) < Self.cacheLifetime {
            return (cached.plan, cached.planner + " cached")
        }

        if allowNetwork, usesClaude {
            do {
                let plan = try await claude.plan(request)
                cachedPlan = (signature, plan, claude.name, Date())
                return (plan, claude.name)
            } catch {
                NSLog("SmartArranger: Claude failed, using heuristic: \(error)")
            }
        }
        return (heuristic.planNow(request), heuristic.name)
    }

    private func apply(_ plan: LayoutPlan, to snapshot: WindowEnumerator.Snapshot) {
        let entriesByID = Dictionary(snapshot.entries.map { ($0.info.id, $0) }, uniquingKeysWith: { first, _ in first })
        var undo: [(window: ManagedWindow, frame: CGRect)] = []
        suppressObservationUntil = Date().addingTimeInterval(2)

        for placement in plan.placements {
            guard let entry = entriesByID[placement.id], let current = entry.window.frame else { continue }
            if current.integral == placement.rect.integral { continue }
            undo.append((entry.window, current))
            entry.window.setFrame(placement.rect)
        }

        if !undo.isEmpty {
            windowController.pushUndo(undo)
        }
    }

    // MARK: - Learning

    private func watchForCorrections(after plan: LayoutPlan, snapshot: WindowEnumerator.Snapshot) {
        correctionTask?.cancel()
        let planned = plan.placements.compactMap { placement -> (key: String, info: WindowInfo, rect: CGRect)? in
            guard let info = snapshot.windows.first(where: { $0.id == placement.id }) else { return nil }
            return (info.key, info, placement.rect)
        }
        guard !planned.isEmpty else { return }

        correctionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.correctionDelay))
            guard !Task.isCancelled, let self else { return }
            let now = Date()
            let current = enumerator.snapshot(lastActive: lastActive, now: now).windows
            var changed = 0
            for item in planned {
                guard let window = current.first(where: { $0.key == item.key }) else { continue }
                let actual = window.frame.cgRect
                let moved = abs(actual.minX - item.rect.minX) > 20 || abs(actual.minY - item.rect.minY) > 20
                let resized = abs(actual.width - item.rect.width) > 40 || abs(actual.height - item.rect.height) > 40
                if moved || resized {
                    history.record(LayoutCorrection(app: item.info.app, title: item.info.title, planned: RectInfo(item.rect), actual: RectInfo(actual), date: now))
                    changed += 1
                }
            }
            learnStyles(planned: planned.map { ($0.info, $0.rect) }, current: current)
            if changed > 0 {
                cachedPlan = nil
                saveHistory()
            }
        }
    }

    /// If we cascaded an app's windows and the user re-tiled them (or the other way round), remember the style they chose.
    private func learnStyles(planned: [(info: WindowInfo, rect: CGRect)], current: [WindowInfo]) {
        let groups = Dictionary(grouping: planned) { "\($0.info.bundleID)|\($0.info.displayID)" }
        for group in groups.values where group.count >= 2 {
            let actualFrames = group.compactMap { item in current.first { $0.key == item.info.key }?.frame.cgRect }
            guard actualFrames.count == group.count else { continue }
            let plannedStyle = ArrangementAnalyzer.style(of: group.map(\.rect))
            let actualStyle = ArrangementAnalyzer.style(of: actualFrames)
            guard actualStyle != plannedStyle, actualStyle == .tiled || actualStyle == .cascaded else { continue }
            let bundleID = group[0].info.bundleID
            if history.appStyles[bundleID] != actualStyle {
                history.appStyles[bundleID] = actualStyle
                saveHistory()
                NSLog("SmartArranger: learned \(bundleID) prefers \(actualStyle.rawValue)")
            }
        }
    }

    // MARK: - Watching the user's own moves

    private func handleUserMoves(_ settled: WindowObserver.Settled) {
        guard usesClaude, Date() >= suppressObservationUntil, !suggestion.isVisible else { return }
        let now = Date()
        var moves = recentUserMoves[settled.pid, default: [:]].filter { now.timeIntervalSince($0.value) < Self.userMoveMemory }
        for title in settled.movedTitles { moves[title] = now }
        recentUserMoves[settled.pid] = moves

        let snapshot = enumerator.snapshot(lastActive: lastActive, now: now, pids: [settled.pid])
        guard let bundleID = snapshot.windows.first?.bundleID, let appName = snapshot.windows.first?.app else { return }
        if let until = suggestionCooldown[bundleID], now < until { return }

        for display in snapshot.displays {
            let windows = snapshot.windows.filter { $0.displayID == display.id }
            guard windows.count >= 3 else { continue }
            let movedIDs = Set(windows.filter { moves[$0.title] != nil }.map(\.id))
            guard let partial = ArrangementAnalyzer.partialTiling(windows: windows, recentlyMoved: movedIDs) else { continue }

            let total = partial.tiled.count + partial.remaining.count
            let entries = snapshot.entries
            suggestion.show(
                message: "You tiled \(partial.tiled.count) \(appName) windows. Tile all \(total) on this display?",
                acceptTitle: "Tile all",
                near: display.visibleFrame,
                onAccept: { [weak self] in
                    self?.tileAll(tiled: partial.tiled, remaining: partial.remaining, entries: entries, in: display)
                },
                onDismiss: { [weak self] in
                    self?.suggestionCooldown[bundleID] = Date().addingTimeInterval(Self.suggestionCooldownInterval)
                }
            )
            return
        }
    }

    private func tileAll(tiled: [WindowInfo], remaining: [WindowInfo], entries: [WindowEnumerator.Entry], in display: DisplayInfo) {
        let ordered = tiled.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) } + remaining
        let frames = ArrangementAnalyzer.tileFrames(count: ordered.count, in: display.visibleFrame)
        let entriesByID = Dictionary(entries.map { ($0.info.id, $0) }, uniquingKeysWith: { first, _ in first })

        suppressObservationUntil = Date().addingTimeInterval(2)
        var undo: [(window: ManagedWindow, frame: CGRect)] = []
        for (window, frame) in zip(ordered, frames) {
            guard let entry = entriesByID[window.id], let current = entry.window.frame else { continue }
            undo.append((entry.window, current))
            entry.window.setFrame(frame)
        }
        if !undo.isEmpty { windowController.pushUndo(undo) }

        if let bundleID = ordered.first?.bundleID {
            history.appStyles[bundleID] = .tiled
            saveHistory()
        }
        cachedPlan = nil
        recentUserMoves.removeAll()
        update("Tiled \(ordered.count) \(ordered.first?.app ?? "") windows", planner: "user")
    }

    // MARK: - Pre-warm

    private func noteActivation(bundleID: String?, name: String?) {
        guard let bundleID else { return }
        lastActive[bundleID] = Date()
        if let name {
            recentApps.removeAll { $0 == name }
            recentApps.insert(name, at: 0)
            if recentApps.count > 12 { recentApps.removeLast(recentApps.count - 12) }
        }
        schedulePrewarm()
    }

    private func schedulePrewarm() {
        guard prewarmEnabled, usesClaude, AccessibilityPermission.isTrusted else { return }
        prewarmTask?.cancel()
        prewarmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.prewarmDebounce))
            guard !Task.isCancelled else { return }
            await self?.prewarm()
        }
    }

    public func prewarm() async {
        let now = Date()
        let request = makeRequest(from: enumerator.snapshot(lastActive: lastActive, now: now), now: now)
        let signature = request.signature
        guard !request.windows.isEmpty, inFlightSignature != signature else { return }
        if let cached = cachedPlan, cached.signature == signature, now.timeIntervalSince(cached.date) < Self.cacheLifetime {
            return
        }

        inFlightSignature = signature
        defer { inFlightSignature = nil }
        do {
            let plan = try await claude.plan(request)
            cachedPlan = (signature, plan, claude.name, Date())
        } catch {
            NSLog("SmartArranger: pre-warm failed: \(error)")
        }
    }

    // MARK: - Helpers

    private func makeRequest(from snapshot: WindowEnumerator.Snapshot, now: Date) -> LayoutRequest {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE HH:mm"
        return LayoutRequest(
            displays: snapshot.displays,
            windows: snapshot.windows,
            recentApps: recentApps,
            corrections: history.corrections.suffix(20).map { $0 },
            notes: history.notes,
            localTime: formatter.string(from: now),
            appStyles: history.appStyles
        )
    }

    private func update(_ message: String, planner: String?) {
        status = Status(message: message, planner: planner, date: Date())
        onStatusChange?(status)
    }

    private func saveHistory() {
        do {
            try history.save(to: historyURL)
        } catch {
            NSLog("SmartArranger: could not save history: \(error)")
        }
    }
}
