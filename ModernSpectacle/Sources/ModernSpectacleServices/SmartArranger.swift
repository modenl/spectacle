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

    public private(set) var status = Status(message: L("Idle", "空闲"), planner: nil, date: nil)
    public var onStatusChange: ((Status) -> Void)?
    /// True while a plan is being requested from the model (not for cache hits or background pre-warming).
    public var onBusyChange: ((Bool, String) -> Void)?
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
    /// What the planner remembers. Shown and edited in the Profile window.
    public private(set) var history: LayoutHistory {
        didSet { onHistoryChange?(history) }
    }
    public var onHistoryChange: ((LayoutHistory) -> Void)?
    /// The request behind the most recent arrangement, so the Profile window can explain it.
    public private(set) var lastRequest: LayoutRequest?
    /// Last applied template choice per display, with windows identified by their stable key ("bundleID|title").
    private struct StoredChoice {
        var template: String
        var slots: [(slot: String, key: String)]
        var stack: [String]
        var cascade: [String]
    }
    private var lastChoices: [Int: StoredChoice] = [:]

    private var lastActive: [String: Date] = [:]
    private var recentApps: [String] = []
    /// Newest first: which app came to the front, when, and the title of the window that had focus.
    private var focusTimeline: [(bundleID: String, app: String, window: String, start: Date)] = []
    /// "bundleID|title" -> when that window last had keyboard focus.
    private var windowFocus: [String: Date] = [:]
    /// The model's last answer with the windows it was computed for. Only the template choice is reused: frames are
    /// recomputed for the current snapshot, so focus changes since the plan was made are respected.
    private var cachedPlan: (signature: String, plan: LayoutPlan, windows: [WindowInfo], planner: String, date: Date)?
    private var prewarmTask: Task<Void, Never>?
    private var restackTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
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
        focusTimeline = history.activity.map { ($0.bundleID, $0.app, $0.window, $0.date) }
        for entry in focusTimeline.reversed() { lastActive[entry.bundleID] = entry.start }

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
                observer.onFocusChanged = { [weak self] pid, title in
                    self?.noteWindowFocus(pid: pid, title: title)
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
        Self.log("arrange requested (key: \(usesClaude), accessibility: \(AccessibilityPermission.isTrusted))")
        guard usesClaude else {
            update(L("Smart Arrange needs a Claude API key (Settings)", "智能排列需要 Claude API Key（在设置里填写）"), planner: nil)
            return
        }
        guard AccessibilityPermission.isTrusted else {
            update(L("Accessibility permission required", "需要辅助功能权限"), planner: nil)
            return
        }

        let started = Date()
        let snapshot = enumerator.snapshot(lastActive: lastActive, windowFocus: windowFocus, now: started)
        let request = makeRequest(from: snapshot, now: started)
        guard !request.windows.isEmpty else {
            update(L("No windows to arrange", "没有可排列的窗口"), planner: nil)
            return
        }

        lastRequest = request
        let willCallModel = usesClaude && !hasFreshCachedPlan(for: request.signature)
        onBusyChange?(true, willCallModel ? L("Arranging with Claude…", "Claude 正在排列…") : L("Arranging…", "正在排列…"))
        let (plan, plannerName) = await plan(for: request, allowNetwork: true)
        // Frames come from the composer (exact tiling); still clamp and cover anything the design left out.
        let safe = PlanValidator.completed(PlanValidator.sanitized(plan, for: request), for: request)
        apply(safe, to: snapshot)
        dumpLastArrangement(request: request, raw: plan, final: safe, planner: plannerName, rejected: snapshot.rejected, apps: snapshot.apps)

        if plannerName == claude.name {
            history.notes = safe.notes
        }
        remember(plan.choices, windows: request.windows)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        history.record(ArrangementRecord(date: started, planner: plannerName, summary: safe.summary, windowCount: safe.placements.count, durationMs: elapsed))
        saveHistory()

        update("\(safe.summary) (\(plannerName), \(elapsed) ms)", planner: plannerName)
        onBusyChange?(false, "\(safe.summary)  ·  \(elapsed) ms")
        watchForCorrections(after: safe, snapshot: snapshot)
    }

    private func hasFreshCachedPlan(for signature: String) -> Bool {
        guard let cached = cachedPlan else { return false }
        return cached.signature == signature && Date().timeIntervalSince(cached.date) < Self.cacheLifetime
    }

    private func plan(for request: LayoutRequest, allowNetwork: Bool) async -> (LayoutPlan, String) {
        let signature = request.signature
        if let cached = cachedPlan, cached.signature == signature, Date().timeIntervalSince(cached.date) < Self.cacheLifetime {
            guard let choices = cached.plan.choices else { return (cached.plan, cached.planner + " cached") }
            let translated = LayoutTemplates.translate(choices, from: cached.windows, to: request.windows)
            var plan = LayoutTemplates.plan(from: TemplatePlan(summary: cached.plan.summary, notes: cached.plan.notes, displays: translated), for: request)
            plan.summary = cached.plan.summary
            return (plan, cached.planner + " cached")
        }

        if allowNetwork, usesClaude {
            do {
                let plan = try await claude.plan(request)
                cachedPlan = (signature, plan, request.windows, claude.name, Date())
                return (plan, claude.name)
            } catch {
                NSLog("SmartArranger: Claude failed, using heuristic: \(error)")
            }
        }
        return (heuristic.planNow(request), heuristic.name)
    }

    private func apply(_ plan: LayoutPlan, to snapshot: WindowEnumerator.Snapshot, frontID: Int? = nil) {
        let entriesByID = Dictionary(snapshot.entries.map { ($0.info.id, $0) }, uniquingKeysWith: { first, _ in first })
        var undo: [(window: ManagedWindow, frame: CGRect)] = []
        suppressObservationUntil = Date().addingTimeInterval(2)

        for placement in plan.placements {
            guard let entry = entriesByID[placement.id], let current = entry.window.frame else { continue }
            if current.integral == placement.rect.integral { continue }
            undo.append((entry.window, current))
            entry.window.setFrame(placement.rect)
            keepInsideDisplay(entry.window, planned: placement.rect, displays: snapshot.displays)
        }

        if !undo.isEmpty {
            windowController.pushUndo(undo)
        }
        settle(plan, entriesByID: entriesByID, displays: snapshot.displays)
        let front = frontID ?? snapshot.windows.first { $0.isFocused }?.id
        restack(plan, entriesByID: entriesByID, frontID: front)
    }

    /// Some apps resize asynchronously (Sublime Text) and drop a size change that arrives while the previous one is
    /// still in flight, so a window can end up moved but not resized. Check shortly after and set it again, twice at most.
    private func settle(_ plan: LayoutPlan, entriesByID: [Int: WindowEnumerator.Entry], displays: [DisplayInfo]) {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            for _ in 0..<2 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                var retried = 0
                for placement in plan.placements {
                    guard let window = entriesByID[placement.id]?.window, let actual = window.frame else { continue }
                    // A window bigger than planned is at its app's minimum: aim for its own size, kept inside the display.
                    var target = placement.rect
                    if actual.width > target.width + 2 || actual.height > target.height + 2,
                       let display = displays.first(where: { $0.visibleFrame.contains(CGPoint(x: target.midX, y: target.midY)) })?.visibleFrame {
                        target.size = CGSize(width: max(target.width, actual.width), height: max(target.height, actual.height))
                        target.origin.x = max(display.minX, min(target.minX, display.maxX - target.width))
                        target.origin.y = max(display.minY, min(target.minY, display.maxY - target.height))
                    }
                    let off = abs(actual.minX - target.minX) > 4 || abs(actual.minY - target.minY) > 4
                        || abs(actual.width - target.width) > 4 || abs(actual.height - target.height) > 4
                    guard off else { continue }
                    suppressObservationUntil = Date().addingTimeInterval(2)
                    window.setFrame(target)
                    retried += 1
                }
                if retried == 0 { return }
                Self.log("settle: set \(retried) window(s) again")
            }
        }
    }

    /// Some apps will not get narrower (or shorter) than their own minimum (Notes, Activity Monitor). Placed at the
    /// planned origin they would stick out past the display edge, so move such a window back inside.
    private func keepInsideDisplay(_ window: ManagedWindow, planned: CGRect, displays: [DisplayInfo]) {
        guard let actual = window.frame, actual.width > planned.width + 2 || actual.height > planned.height + 2,
              let display = displays.first(where: { $0.visibleFrame.contains(CGPoint(x: planned.midX, y: planned.midY)) })?.visibleFrame
        else { return }
        var fixed = actual
        if fixed.maxX > display.maxX { fixed.origin.x = max(display.minX, display.maxX - fixed.width) }
        if fixed.maxY > display.maxY { fixed.origin.y = max(display.minY, display.maxY - fixed.height) }
        if fixed.origin != actual.origin { window.setFrame(fixed) }
    }

    /// Peeking windows must sit behind the tiles, and the focused window on top. Window order follows raising, one
    /// window at a time (raising a whole app would pull its peeking windows over the tiles): hidden background windows
    /// first, then peeks least useful first, then the tiles, then the front window. Each step raises the window and makes its app frontmost.
    private func restack(_ plan: LayoutPlan, entriesByID: [Int: WindowEnumerator.Entry], frontID: Int?) {
        let peeks = plan.placements.filter { $0.group == "peek" }
        let hidden = plan.placements.filter { $0.group == "behind" }
        guard !peeks.isEmpty || !hidden.isEmpty || frontID != nil else { return }
        let tiles = plan.placements.filter { $0.group.hasPrefix("column") && $0.id != frontID }
        var sequence = (hidden + peeks.reversed()).compactMap { entriesByID[$0.id] } + tiles.compactMap { entriesByID[$0.id] }
        if let frontID, let front = entriesByID[frontID] { sequence.append(front) }
        guard !sequence.isEmpty else { return }

        restackTask?.cancel()
        restackTask = Task { @MainActor in
            for entry in sequence {
                guard !Task.isCancelled else { return }
                entry.window.bringToFront(pid: entry.pid)
                try? await Task.sleep(for: .milliseconds(30))
            }
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
            let current = enumerator.snapshot(lastActive: lastActive, windowFocus: windowFocus, now: now).windows
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
                message: L("You tiled \(partial.tiled.count) \(appName) windows. Tile all \(total) on this display?", "你平铺了 \(partial.tiled.count) 个 \(appName) 窗口。要把这个显示器上的 \(total) 个都平铺吗？"),
                acceptTitle: L("Tile all", "全部平铺"),
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
        update(L("Tiled \(ordered.count) \(ordered.first?.app ?? "") windows", "已平铺 \(ordered.count) 个 \(ordered.first?.app ?? "") 窗口"), planner: "user")
    }

    // MARK: - Pre-warm

    private func noteActivation(bundleID: String?, name: String?) {
        guard let bundleID else { return }
        let now = Date()
        lastActive[bundleID] = now
        if let name {
            recentApps.removeAll { $0 == name }
            recentApps.insert(name, at: 0)
            if recentApps.count > 12 { recentApps.removeLast(recentApps.count - 12) }
            let title = String(enumerator.focusedWindowTitle().prefix(80))
            focusTimeline.insert((bundleID, name, title, now), at: 0)
            if focusTimeline.count > 40 { focusTimeline.removeLast(focusTimeline.count - 40) }
            if !title.isEmpty { windowFocus["\(bundleID)|\(title)"] = now }
            scheduleActivitySave()
        }
        schedulePrewarm()
    }

    private var activitySaveTask: Task<Void, Never>?

    /// The timeline is written a little after activity settles, so relaunching the app does not lose context.
    private func scheduleActivitySave() {
        activitySaveTask?.cancel()
        activitySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            history.activity = focusTimeline.prefix(40).map { ActivityRecord(bundleID: $0.bundleID, app: $0.app, window: $0.window, date: $0.start) }
            saveHistory()
        }
    }

    private func noteWindowFocus(pid: pid_t, title: String) {
        guard !title.isEmpty, let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return }
        let now = Date()
        windowFocus["\(bundleID)|\(String(title.prefix(80)))"] = now
        if windowFocus.count > 200 {
            windowFocus = Dictionary(uniqueKeysWithValues: windowFocus.sorted { $0.value > $1.value }.prefix(150).map { ($0.key, $0.value) })
        }
        // Same app, different window: extend the timeline so the model sees window-level switching too.
        if let first = focusTimeline.first, first.bundleID == bundleID, first.window != title {
            focusTimeline.insert((bundleID, first.app, String(title.prefix(80)), now), at: 0)
        }
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
        let request = makeRequest(from: enumerator.snapshot(lastActive: lastActive, windowFocus: windowFocus, now: now), now: now)
        let signature = request.signature
        guard !request.windows.isEmpty, inFlightSignature != signature else { return }
        if let cached = cachedPlan, cached.signature == signature, now.timeIntervalSince(cached.date) < Self.cacheLifetime {
            return
        }

        inFlightSignature = signature
        defer { inFlightSignature = nil }
        do {
            let plan = try await claude.plan(request)
            cachedPlan = (signature, plan, request.windows, claude.name, Date())
        } catch {
            NSLog("SmartArranger: pre-warm failed: \(error)")
        }
    }

    /// Everything about the last arrangement, for debugging and the Profile window: what was seen, what the model said, what was applied.
    private func dumpLastArrangement(request: LayoutRequest, raw: LayoutPlan, final: LayoutPlan, planner: String, rejected: [String], apps: [String]) {
        struct Dump: Codable {
            var planner: String
            var request: LayoutRequest
            var modelPlan: LayoutPlan
            var appliedPlan: LayoutPlan
            var skippedByModel: [String]
            var rejectedWindows: [String]
            var apps: [String]
        }
        let placed = Set(raw.placements.map(\.id))
        let dump = Dump(
            planner: planner, request: request, modelPlan: raw, appliedPlan: final,
            skippedByModel: request.windows.filter { !placed.contains($0.id) }.map { "\($0.app): \($0.title)" },
            rejectedWindows: rejected,
            apps: apps
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = historyURL.deletingLastPathComponent().appendingPathComponent("last-arrangement.json")
        try? encoder.encode(dump).write(to: url, options: .atomic)
    }

    /// Appends one line to status.log next to the history file; `log show` does not reliably surface NSLog for this app.
    public static func log(_ message: String) {
        let url = defaultHistoryURL.deletingLastPathComponent().appendingPathComponent("status.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Forget the pre-computed plan so the next arrangement asks the model again.
    public func invalidateCache() {
        cachedPlan = nil
    }

    // MARK: - Stability: previous choices and promotion

    private func remember(_ choices: [DisplayChoice]?, windows: [WindowInfo]) {
        guard let choices else { return }
        let keyOf = Dictionary(windows.map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        for choice in choices {
            lastChoices[choice.id] = StoredChoice(
                template: choice.template,
                slots: choice.slots.compactMap { a in keyOf[a.window].map { (a.slot, $0) } },
                stack: choice.stack.compactMap { keyOf[$0] },
                cascade: choice.cascade.compactMap { keyOf[$0] }
            )
        }
    }

    /// Previous choices translated to the ids in `windows`; windows that are gone simply drop out. Matching falls back
    /// from the exact title to the app, since terminal and browser titles change between arranging and the next key press.
    private func previousChoices(for windows: [WindowInfo]) -> [DisplayChoice] {
        let stored = lastChoices.sorted { $0.key < $1.key }.map { displayID, s in
            (display: displayID, template: s.template, slots: s.slots, stack: s.stack, cascade: s.cascade)
        }
        return LayoutTemplates.choices(fromKeys: stored, in: windows)
    }

    /// Bring the focused window into the main slot of its display, pushing the previous main window to where the
    /// focused one came from. Local and instant; falls back to a full arrangement when there is no layout yet.
    public func promoteFocused() {
        let now = Date()
        let snapshot = enumerator.snapshot(lastActive: lastActive, windowFocus: windowFocus, now: now)
        guard let focused = snapshot.windows.first(where: { $0.isFocused }) else {
            update(L("No focused window", "没有焦点窗口"), planner: nil)
            return
        }
        guard let previous = previousChoices(for: snapshot.windows).first(where: { $0.id == focused.displayID }),
              previous.slots.contains(where: { $0.slot == "main" }) else {
            Task { await arrange() }
            return
        }

        let request = makeRequest(from: snapshot, now: now)
        let choice = LayoutTemplates.fitted(LayoutTemplates.promoted(previous, focusedID: focused.id), for: makeRequest(from: snapshot, now: now))
        let plan = LayoutTemplates.design(from: TemplatePlan(summary: L("Brought \(focused.app) to main", "已把 \(focused.app) 移到主位"), notes: history.notes, displays: [choice]), for: request)
        var composed = LayoutComposer.plan(from: plan, for: request)
        composed.choices = [choice]
        let safe = PlanValidator.sanitized(composed, for: request)
        apply(safe, to: snapshot, frontID: focused.id)
        remember(safe.choices, windows: request.windows)
        cachedPlan = nil
        update(L("Brought \(focused.app) to main (\(choice.template))", "已把 \(focused.app) 移到主位（\(choice.template)）"), planner: "local")
        onBusyChange?(false, L("Brought \(focused.app) to main", "已把 \(focused.app) 移到主位"))
    }

    // MARK: - Presets

    public var presets: [LayoutPreset] { history.presets }
    /// Called when presets are added or removed, so the menu can list them.
    public var onPresetsChange: (() -> Void)?

    /// True when there is an applied template layout to save (after ⌃⌥⌘A, Bring to Main, or restoring a preset).
    public var canSavePreset: Bool { !lastChoices.isEmpty }

    /// Saves the layout currently applied, by app and window title, under `name`. Same name replaces.
    @discardableResult
    public func savePreset(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let now = Date()
        let snapshot = enumerator.snapshot(lastActive: lastActive, windowFocus: windowFocus, now: now)
        let request = makeRequest(from: snapshot, now: now)
        guard let preset = LayoutPresets.make(name: trimmed, from: request.previous, request: request, date: now) else {
            update(L("Nothing to save yet: arrange first (⌃⌥⌘A)", "还没有可保存的布局：先按 ⌃⌥⌘A 排列"), planner: nil)
            onBusyChange?(false, L("Arrange first (⌃⌥⌘A), then save the layout", "先按 ⌃⌥⌘A 排列，再保存布局"))
            return false
        }
        history.presets = LayoutPresets.saving(preset, into: history.presets)
        saveHistory()
        onPresetsChange?()
        let number = history.presets.firstIndex { $0.name == trimmed }.map { L(" as ⌃⌥⌘\($0 + 1)", "，快捷键 ⌃⌥⌘\($0 + 1)") } ?? ""
        update(L("Saved layout \"\(trimmed)\"\(number)", "已保存布局「\(trimmed)」\(number)"), planner: "local")
        onBusyChange?(false, L("Saved \"\(trimmed)\"\(number)", "已保存「\(trimmed)」\(number)"))
        return true
    }

    public func deletePreset(named name: String) {
        history.presets.removeAll { $0.name == name }
        saveHistory()
        onPresetsChange?()
    }

    /// Restores preset number `index` (0-based). Local and instant: no model call. Windows of the preset's apps are
    /// matched to what is open now; apps that are not running leave their slot empty, other windows go to the stack.
    public func restorePreset(at index: Int) {
        guard history.presets.indices.contains(index) else {
            update(L("No layout saved as ⌃⌥⌘\(index + 1)", "⌃⌥⌘\(index + 1) 还没有保存布局"), planner: nil)
            onBusyChange?(false, L("No layout saved as ⌃⌥⌘\(index + 1)", "⌃⌥⌘\(index + 1) 还没有保存布局"))
            return
        }
        guard AccessibilityPermission.isTrusted else {
            update(L("Accessibility permission required", "需要辅助功能权限"), planner: nil)
            return
        }
        let preset = history.presets[index]
        let now = Date()
        let snapshot = enumerator.snapshot(lastActive: lastActive, windowFocus: windowFocus, now: now)
        let (choices, request) = LayoutPresets.restore(preset, for: makeRequest(from: snapshot, now: now))
        guard choices.contains(where: { !$0.slots.isEmpty }) else {
            update(L("None of the windows in \"\(preset.name)\" are open", "「\(preset.name)」里的窗口一个都没打开"), planner: nil)
            onBusyChange?(false, L("None of the windows in \"\(preset.name)\" are open", "「\(preset.name)」里的窗口一个都没打开"))
            return
        }

        let design = LayoutTemplates.design(from: TemplatePlan(summary: L("Restored \(preset.name)", "已恢复 \(preset.name)"), notes: history.notes, displays: choices), for: request)
        var composed = LayoutComposer.plan(from: design, for: request)
        composed.choices = choices
        // The preset's main window gets focus, on the main display if the preset spans several.
        let mainChoice = choices.first { c in request.displays.first { $0.id == c.id }?.isMain == true } ?? choices[0]
        let mainID = mainChoice.slots.first(where: { $0.slot == "main" })?.window ?? mainChoice.slots.first?.window
        let safe = PlanValidator.sanitized(composed, for: request)
        apply(safe, to: snapshot, frontID: mainID)
        remember(choices, windows: request.windows)
        cachedPlan = nil

        let placed = choices.map { $0.slots.count + $0.stack.count + $0.cascade.count }.reduce(0, +)
        let missing = preset.windowCount - placed
        let note = missing > 0 ? L(", \(missing) not open", "，\(missing) 个没打开") : ""
        update(L("Restored \"\(preset.name)\" (\(placed) windows\(note))", "已恢复「\(preset.name)」（\(placed) 个窗口\(note)）"), planner: "preset")
        onBusyChange?(false, L("Restored \"\(preset.name)\"\(note)", "已恢复「\(preset.name)」\(note)"))
        watchForCorrections(after: safe, snapshot: snapshot)
    }

    // MARK: - Editing the memory

    public func setNotes(_ notes: String) {
        history.notes = String(notes.prefix(2000))
        cachedPlan = nil
        saveHistory()
    }

    public func setAppStyle(_ style: ArrangementStyle?, for bundleID: String) {
        history.appStyles[bundleID] = style
        cachedPlan = nil
        saveHistory()
    }

    public func clearCorrections() {
        history.corrections.removeAll()
        cachedPlan = nil
        saveHistory()
    }

    /// Forgets what was learned; saved presets are the user's own and stay.
    public func resetLearning() {
        var fresh = LayoutHistory()
        fresh.presets = history.presets
        history = fresh
        cachedPlan = nil
        saveHistory()
    }

    // MARK: - Helpers

    private func makeRequest(from snapshot: WindowEnumerator.Snapshot, now: Date) -> LayoutRequest {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE HH:mm"
        var request = LayoutRequest(
            displays: snapshot.displays,
            windows: snapshot.windows,
            recentApps: recentApps,
            corrections: history.corrections.suffix(20).map { $0 },
            notes: history.notes,
            localTime: formatter.string(from: now),
            appStyles: history.appStyles,
            focusedWindowID: snapshot.windows.first { $0.isFocused }?.id,
            focusTimeline: timelineEvents(now: now)
        )
        request.language = Localization.isChinese ? "zh-Hans" : "en"
        request.templates = LayoutTemplates.offers(for: request)
        request.previous = previousChoices(for: request.windows)
        return request
    }

    /// Newest first, with dwell = time until the next (newer) switch; the current app's dwell runs to now.
    private func timelineEvents(now: Date, limit: Int = 20) -> [FocusEvent] {
        var events: [FocusEvent] = []
        var end = now
        for entry in focusTimeline.prefix(limit) {
            events.append(FocusEvent(
                app: entry.app,
                window: entry.window,
                secondsAgo: Int(now.timeIntervalSince(entry.start)),
                dwellSeconds: max(0, Int(end.timeIntervalSince(entry.start)))
            ))
            end = entry.start
        }
        return events
    }

    private func update(_ message: String, planner: String?) {
        NSLog("SmartArranger: %@", message)
        Self.log(message)
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
