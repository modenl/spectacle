import AppKit
import ModernSpectacleCore

/// One hotkey: snapshot the desktop, rank the windows (Apple's on-device model, or locally), fill the display's
/// template from the ranking, apply it, and learn from what the user moves afterwards. Nothing is computed until the key
/// goes down: the model is asked then, while the preview shows the template, and the windows move when every key is
/// let go. A ranking is reused for a while if the same apps are open, so pressing again does not ask the model again.
@MainActor
public final class SmartArranger {
    public struct Status: Equatable, Sendable {
        public var message: String
        public var planner: String?
        public var date: Date?
    }

    public private(set) var status = Status(message: L("Idle", "空闲"), planner: nil, date: nil)
    public var onStatusChange: ((Status) -> Void)?
    /// True while a ranking is being requested from the model (not for cache hits).
    public var onBusyChange: ((Bool, String) -> Void)?

    private let enumerator: WindowEnumerator
    private let windowController: WindowController
    // Feeds the focus history and the learning from the person's own moves.
    private var windowObserver: WindowObserver?
    private let suggestion = SuggestionPanel()
    private let ranker: any WindowRanker
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
    /// The model's last ranking with the windows it was computed for, reused while the set of windows is the same.
    private var cachedRanking: (signature: String, ranking: WindowRanking, windows: [WindowInfo], date: Date)?
    /// A Smart Arrange press in progress: the preview is up, the windows have not moved yet. Pressing M again switches
    /// template; letting go of the modifiers applies; Esc cancels.
    private struct Session {
        var id = UUID()
        var snapshot: WindowEnumerator.Snapshot
        var request: LayoutRequest
        /// Nil while the model is still ranking: the template's shape is shown, the windows wait.
        var ranking: WindowRanking?
        /// Index into the display's templates, per display. Independent of the ranking.
        var templateIndex: [Int: Int]
        var focusedDisplay: Int
        var started: Date
        var calledModel: Bool
        var pendingRanking: Task<Void, Never>?
        /// The modifiers were let go before the ranking arrived: apply as soon as it does.
        var released = false
    }
    private var session: Session?
    private let preview = ArrangementPreview()
    private var flagsMonitors: [Any] = []
    private var escapeMonitors: [Any] = []
    private var restackTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var correctionTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// Moves we make ourselves also arrive through the window observer; ignore them until this time.
    private var suppressObservationUntil = Date.distantPast
    /// Per app: titles the user moved or resized recently, so hand-tiling can be recognised across several drags.
    private var recentUserMoves: [pid_t: [String: Date]] = [:]
    private var suggestionCooldown: [String: Date] = [:]

    private static let cacheLifetime: TimeInterval = 15 * 60
    private static let correctionDelay: TimeInterval = 12
    private static let userMoveMemory: TimeInterval = 45
    private static let suggestionCooldownInterval: TimeInterval = 10 * 60

    public init(
        windowController: WindowController,
        enumerator: WindowEnumerator = WindowEnumerator(),
        ranker: any WindowRanker = AppleRanker(),
        historyURL: URL = SmartArranger.defaultHistoryURL
    ) {
        self.windowController = windowController
        self.enumerator = enumerator
        self.ranker = ranker
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
        // Letting go of every modifier applies the previewed arrangement.
        let flagsChanged: (NSEvent) -> Void = { [weak self] event in
            let held = !event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty
            Task { @MainActor in if !held { await self?.commitPreview() } }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsChanged) { flagsMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flagsChanged($0); return $0 }) { flagsMonitors.append(local) }
        let observer = WindowObserver()
        observer.onSettled = { [weak self] settled in
            self?.handleUserMoves(settled)
        }
        observer.onFocusChanged = { [weak self] pid, title in
            self?.noteWindowFocus(pid: pid, title: title)
        }
        windowObserver = observer
    }

    public static var defaultHistoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ModernSpectacle/layout-history.json")
    }

    /// Apple's on-device model when it is available; otherwise (nil) windows are ranked locally.
    private var activeRanker: (any WindowRanker)? {
        AppleRanker.status == .available ? ranker : nil
    }

    // MARK: - Arrange

    /// The Smart Arrange key. The first press shows the arrangement as a preview; pressing it again while the modifiers
    /// are held switches the focused display to its next template; letting go applies, Esc cancels. With no modifier
    /// held (a quick tap, or `holding: false` from the developer trigger) it applies straight away.
    public func smartArrangeKey(holding: Bool? = nil) {
        if session != nil {
            nextTemplate()
            return
        }
        guard beginPreview() else { return }
        let held = holding ?? !NSEvent.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty
        if !held { Task { await commitPreview() } }
    }

    /// Arrange without a preview pause (the developer trigger, and Bring to Main with nothing arranged yet).
    public func arrange() async {
        cancelPreview()
        guard beginPreview() else { return }
        await commitPreview()
    }

    /// Snapshot, ranking (cached or local now, the model's when it arrives) and the preview. Nothing moves yet.
    @discardableResult
    private func beginPreview() -> Bool {
        Self.log("arrange requested (ranker: \(activeRanker?.name ?? "local"), accessibility: \(AccessibilityPermission.isTrusted))")
        guard AccessibilityPermission.isTrusted else {
            update(L("Accessibility permission required", "需要辅助功能权限"), planner: nil)
            return false
        }
        let started = Date()
        let snapshot = enumerator.snapshot(lastActive: lastActive, windowFocus: windowFocus, now: started)
        let request = makeRequest(from: snapshot, now: started)
        guard !request.windows.isEmpty else {
            update(L("No windows to arrange", "没有可排列的窗口"), planner: nil)
            return false
        }
        lastRequest = request
        let needsModel = activeRanker != nil && !hasFreshRanking(for: request.signature)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let pointer = CGPoint(x: NSEvent.mouseLocation.x, y: mainHeight - NSEvent.mouseLocation.y)
        let focusedDisplay = request.activeDisplayID(pointer: pointer) ?? 0
        var templateIndex: [Int: Int] = [:]
        // How many task windows want a slot, judged locally (focus and recency) so the template is chosen right away.
        // Awareness windows take an awareness slot when there is one but are no reason to switch template.
        let localRoles = Dictionary(LocalRanker.rank(request).windows.map { ($0.id, $0.role) }, uniquingKeysWith: { a, _ in a })
        for display in request.displays {
            let templates = LayoutTemplates.candidates(for: display)
            let needed = request.windows.filter { $0.displayID == display.id && $0.resizable && localRoles[$0.id] == .task }.count
            templateIndex[display.id] = LayoutTemplates.startingTemplate(in: templates, remembered: history.templateChoice[LayoutTemplates.sizeClass(of: display)], needed: needed)
        }
        // The model is called the moment the key goes down; the template is chosen independently while it works.
        var current = Session(snapshot: snapshot, request: request, ranking: needsModel ? nil : cachedOrLocalRanking(for: request),
                              templateIndex: templateIndex, focusedDisplay: focusedDisplay, started: started, calledModel: needsModel)
        if needsModel {
            let id = current.id
            current.pendingRanking = Task { @MainActor [weak self] in
                let ranking = await self?.rankingWithin(seconds: 10, for: request)
                guard let self, let ranking, session?.id == id else { return }
                session?.ranking = ranking
                showPreview(morphing: true)
                if session?.released == true {
                    // Let the cards land, then apply.
                    try? await Task.sleep(for: .seconds(ArrangementPreview.flight + 0.1))
                    if session?.id == id { await commitPreview() }
                }
            }
        }
        session = current
        watchEscape()
        showPreview(morphing: false)
        Self.log("preview up in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return true
    }

    private func nextTemplate() {
        guard var current = session, let display = current.request.displays.first(where: { $0.id == current.focusedDisplay }) else { return }
        let count = LayoutTemplates.candidates(for: display).count
        current.templateIndex[display.id] = ((current.templateIndex[display.id] ?? 0) + 1) % count
        session = current
        showPreview(morphing: true)
    }

    /// The model's ranking, or the local one if the model has not answered within `seconds` (it keeps going and fills
    /// the cache for next time).
    private func rankingWithin(seconds: Double, for request: LayoutRequest) async -> WindowRanking {
        let model = Task { @MainActor [weak self] in await self?.ranking(for: request, allowModel: true) }
        let timeout = Task { try? await Task.sleep(for: .seconds(seconds)) }
        return await withTaskGroup(of: WindowRanking?.self) { group in
            group.addTask { await model.value }
            group.addTask { await timeout.value; return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            timeout.cancel()
            if let first { return first }
            Self.log("model slower than \(seconds) s, ranked locally")
            return LocalRanker.rank(request)
        }
    }

    private func template(at index: Int?, for display: DisplayInfo) -> LayoutTemplate {
        let templates = LayoutTemplates.candidates(for: display)
        return templates[(index ?? 0) % templates.count]
    }

    /// The plan the session would apply right now: the active display's template filled from the ranking. Only that
    /// display is arranged; windows on the others stay where they are (the ranking still saw all of them).
    private func plan(of current: Session, ranking: WindowRanking) -> (choices: [DisplayChoice], plan: LayoutPlan) {
        let request = current.request.restricted(to: current.focusedDisplay)
        let choices = request.displays.map { display in
            LayoutTemplates.fill(template(at: current.templateIndex[display.id], for: display), on: display, ranking: ranking, request: request)
        }
        let plan = LayoutTemplates.plan(from: TemplatePlan(summary: summary(of: choices, request: request), notes: history.notes, displays: choices), for: request)
        // Frames come from the composer (exact tiling); still clamp and cover anything the design left out.
        return (choices, PlanValidator.completed(PlanValidator.sanitized(plan, for: request), for: request))
    }

    /// The preview shows the template, not the apps: while the model ranks nobody knows yet which app goes where.
    /// Once the ranking is in, slots that will stay empty fold away so the map matches what will be applied.
    private func showPreview(morphing: Bool) {
        guard let current = session else { return }
        var slots: [ArrangementPreview.Slot] = []
        for display in current.request.displays where display.id == current.focusedDisplay {
            let template = template(at: current.templateIndex[display.id], for: display)
            var frames = LayoutTemplates.slotFrames(of: template, in: display.visibleFrame).map { (id: $0.slot.id, awareness: $0.slot.awareness, rect: $0.rect) }
            if let ranking = current.ranking {
                let (choices, plan) = plan(of: current, ranking: ranking)
                if let choice = choices.first(where: { $0.id == display.id }) {
                    let rectOf = Dictionary(plan.placements.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
                    frames = frames.compactMap { slot in
                        choice.slots.first { $0.slot == slot.id }.flatMap { rectOf[$0.window] }.map { (slot.id, slot.awareness, $0) }
                    }
                }
            }
            slots += frames.map { .init(key: "\(display.id)/\($0.id)", rect: $0.rect, role: $0.id == "main" ? .main : $0.awareness ? .awareness : .tile) }
        }
        let caption: ArrangementPreview.Caption
        if let display = current.request.displays.first(where: { $0.id == current.focusedDisplay }) {
            let templates = LayoutTemplates.candidates(for: display)
            let index = (current.templateIndex[display.id] ?? 0) % templates.count
            caption = .init(text: templates[index].title, index: index, count: templates.count)
        } else {
            caption = .init(text: "", index: 0, count: 0)
        }
        let active = current.request.displays.first { $0.id == current.focusedDisplay }?.visibleFrame
        preview.present(slots: slots, caption: caption, waiting: current.ranking == nil, near: active)
    }

    /// The blocks of a plan, keyed by window, so a window's block can be followed from one plan to the next.
    private func windowBlocks(_ plan: LayoutPlan, choice: DisplayChoice) -> [ArrangementPreview.Slot] {
        guard let template = LayoutTemplates.template(id: choice.template) else { return [] }
        let rectOf = Dictionary(plan.placements.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
        return template.slotsByNearness.compactMap { slot in
            guard let window = choice.slots.first(where: { $0.slot == slot.id })?.window, let rect = rectOf[window] else { return nil }
            return .init(key: "w\(window)", rect: rect, role: slot.id == "main" ? .main : slot.awareness ? .awareness : .tile)
        }
    }

    /// Applies the previewed arrangement: waits for the model if it is still ranking, moves the windows under the
    /// preview, and remembers the template chosen.
    private func commitPreview() async {
        // What the preview shows is what gets applied, at once: a model answer still on its way only fills the cache
        // for next time.
        guard let current = session else { return }
        guard let ranking = current.ranking else {
            // Still ranking: keep the preview (and the glow) up and apply when the answer lands.
            session?.released = true
            return
        }
        stopWatchingEscape()
        session = nil
        let (choices, safe) = plan(of: current, ranking: ranking)
        let request = current.request
        preview.commit { [weak self] done in
            self?.apply(safe, to: current.snapshot, whenVisible: done)
        }
        dumpLastArrangement(request: request, ranking: ranking, final: safe, rejected: current.snapshot.rejected, apps: current.snapshot.apps)
        remember(choices, windows: request.windows)
        if let display = request.displays.first(where: { $0.id == current.focusedDisplay }) {
            let templates = LayoutTemplates.candidates(for: display)
            history.templateChoice[LayoutTemplates.sizeClass(of: display)] = templates[(current.templateIndex[display.id] ?? 0) % templates.count].id
        }
        let elapsed = Int(Date().timeIntervalSince(current.started) * 1000)
        let source = ranking.source + (current.calledModel ? "" : " cached")
        history.record(ArrangementRecord(date: current.started, planner: source, summary: safe.summary, windowCount: safe.placements.count, durationMs: elapsed))
        saveHistory()
        update("\(safe.summary) (\(source), \(elapsed) ms)", planner: source)
        onBusyChange?(false, "")
        watchForCorrections(after: safe, snapshot: current.snapshot)
    }

    /// Esc while the preview is up: nothing moves.
    public func cancelPreview() {
        guard session != nil else { return }
        session?.pendingRanking?.cancel()
        session = nil
        stopWatchingEscape()
        preview.cancel()
        onBusyChange?(false, "")
    }


    /// Same as letting go of the modifiers (for the developer trigger).
    public func releaseModifiers() {
        Task { await commitPreview() }
    }

    private func watchEscape() {
        stopWatchingEscape()
        let onKey: (NSEvent) -> Bool = { [weak self] event in
            guard event.keyCode == 53 else { return false }
            Task { @MainActor in self?.cancelPreview() }
            return true
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = onKey($0) }) { escapeMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { onKey($0) ? nil : $0 }) { escapeMonitors.append(local) }
    }

    private func stopWatchingEscape() {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors = []
    }

    /// The template last chosen for this size of display, or the first one.
    private func template(for display: DisplayInfo) -> LayoutTemplate {
        let templates = LayoutTemplates.candidates(for: display)
        let remembered = history.templateChoice[LayoutTemplates.sizeClass(of: display)]
        return templates.first { $0.id == remembered } ?? templates[0]
    }

    /// "Two on the right: Claude in main, 2 beside, 3 hidden", for the HUD and the history.
    private func summary(of choices: [DisplayChoice], request: LayoutRequest) -> String {
        let appOf = Dictionary(request.windows.map { ($0.id, $0.app) }, uniquingKeysWith: { a, _ in a })
        return choices.filter { !$0.slots.isEmpty || !$0.stack.isEmpty }.map { choice in
            let title = LayoutTemplates.template(id: choice.template)?.title ?? choice.template
            let main = choice.slots.first { $0.slot == "main" }.flatMap { appOf[$0.window] } ?? "–"
            let beside = max(choice.slots.count - 1, 0)
            let hidden = choice.stack.count
            return L("\(title): \(main) in main, \(beside) beside, \(hidden) hidden", "\(title)：\(main) 主位，旁边 \(beside) 个，后台 \(hidden) 个")
        }.joined(separator: " | ")
    }

    private func hasFreshRanking(for signature: String) -> Bool {
        guard let cached = cachedRanking else { return false }
        return cached.signature == signature && Date().timeIntervalSince(cached.date) < Self.cacheLifetime
    }

    private func cachedOrLocalRanking(for request: LayoutRequest) -> WindowRanking {
        if let cached = cachedRanking, hasFreshRanking(for: request.signature) {
            return cached.ranking.translated(from: cached.windows, to: request.windows).covering(request)
        }
        return LocalRanker.rank(request)
    }

    private func ranking(for request: LayoutRequest, allowModel: Bool) async -> WindowRanking {
        if hasFreshRanking(for: request.signature) || !allowModel {
            return cachedOrLocalRanking(for: request)
        }
        if let ranker = activeRanker {
            do {
                let started = Date()
                let ranking = try await ranker.rank(request).covering(request)
                Self.log("\(ranker.name) ranked \(request.windows.count) windows in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                cachedRanking = (request.signature, ranking, request.windows, Date())
                return ranking
            } catch is CancellationError {
                return LocalRanker.rank(request)
            } catch let error as URLError where error.code == .cancelled {
                return LocalRanker.rank(request)
            } catch {
                Self.log("\(ranker.name) failed, ranking locally: \(error)")
            }
        }
        return LocalRanker.rank(request)
    }

    /// One window to move, carried into the parallel move tasks.
    private struct MoveJob: Sendable {
        var window: ManagedWindow
        var pid: pid_t
        var target: CGRect
        var app: String
        var bundleID: String
    }

    private struct Moved: Sendable {
        var job: MoveJob
        var before: CGRect
    }

    /// Moves the windows: each app's windows in parallel with the other apps' (Accessibility calls are per app, and one
    /// slow app such as a terminal snapping to its character grid must not hold up the rest). Visible windows first;
    /// `whenVisible` runs as soon as they are in place, then the hidden background windows follow.
    private func apply(_ plan: LayoutPlan, to snapshot: WindowEnumerator.Snapshot, frontID: Int? = nil, whenVisible: (@MainActor () -> Void)? = nil) {
        let entriesByID = Dictionary(snapshot.entries.map { ($0.info.id, $0) }, uniquingKeysWith: { first, _ in first })
        suppressObservationUntil = Date().addingTimeInterval(3)
        let jobs = plan.placements.compactMap { placement -> (job: MoveJob, hidden: Bool)? in
            guard let entry = entriesByID[placement.id] else { return nil }
            return (MoveJob(window: entry.window, pid: entry.pid, target: placement.rect, app: entry.info.app, bundleID: entry.info.bundleID), placement.group == "behind")
        }
        Task { @MainActor [weak self] in
            let started = Date()
            let visible = await Self.moveInParallel(jobs.filter { !$0.hidden }.map(\.job))
            let visibleMs = Int(Date().timeIntervalSince(started) * 1000)
            whenVisible?()
            let hidden = await Self.moveInParallel(jobs.filter(\.hidden).map(\.job))
            guard let self else { return }
            let moved = visible + hidden
            if !moved.isEmpty {
                windowController.pushUndo(moved.map { ($0.job.window, $0.before) })
            }
            Self.log("apply: moved \(moved.count) of \(plan.placements.count), visible in \(visibleMs) ms, all in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            suppressObservationUntil = Date().addingTimeInterval(2)
            settle(plan, entriesByID: entriesByID, displays: snapshot.displays)
            let front = frontID ?? snapshot.windows.first { $0.isFocused }?.id
            restack(plan, entriesByID: entriesByID, frontID: front)
        }
    }

    /// Each app's jobs run in order on their own task; the apps run side by side.
    private nonisolated static func moveInParallel(_ jobs: [MoveJob]) async -> [Moved] {
        let byApp = Dictionary(grouping: jobs, by: \.pid)
        return await withTaskGroup(of: [Moved].self) { group in
            for appJobs in byApp.values {
                group.addTask { appJobs.compactMap(move) }
            }
            var all: [Moved] = []
            for await moved in group { all += moved }
            return all
        }
    }

    private nonisolated static func move(_ job: MoveJob) -> Moved? {
        guard let before = job.window.frame, before.integral != job.target.integral else { return nil }
        // No correction right after: an app that resizes asynchronously still reports its old size here, and moving
        // it "back inside" would fight its own resize. The settle passes check later.
        job.window.setFrame(job.target)
        return Moved(job: job, before: before)
    }

    /// Some apps resize asynchronously (Sublime Text) and drop a size change that arrives while the previous one is
    /// still in flight, so a window can end up moved but not resized. Check shortly after and set it again, twice at most.
    private func settle(_ plan: LayoutPlan, entriesByID: [Int: WindowEnumerator.Entry], displays: [DisplayInfo]) {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            // Asynchronous apps get time: two passes just ask again, the last one accepts a window that will not shrink.
            let waits = [250, 300, 500]
            for pass in waits.indices {
                try? await Task.sleep(for: .milliseconds(waits[pass]))
                guard !Task.isCancelled else { return }
                var retried = 0
                for placement in plan.placements {
                    guard let entry = entriesByID[placement.id], let actual = entry.window.frame else { continue }
                    let window = entry.window
                    var target = placement.rect
                    // Still bigger than planned after being told again: the app will not get narrower, so keep the
                    // window inside the display at its own size. (An app that resizes asynchronously, like Sublime
                    // Text or iTerm, reports its old size for a moment; the first pass simply asks again.) Nothing is
                    // learned from this: a size read mid-resize looks the same, and remembering it once would keep the
                    // app out of every narrow slot.
                    if pass == waits.count - 1, actual.width > target.width + 2 || actual.height > target.height + 2,
                       let display = displays.first(where: { $0.visibleFrame.contains(CGPoint(x: target.midX, y: target.midY)) })?.visibleFrame {
                        target.size = CGSize(width: max(target.width, actual.width), height: max(target.height, actual.height))
                        target.origin.x = max(display.minX, min(target.minX, display.maxX - target.width))
                        target.origin.y = max(display.minY, min(target.minY, display.maxY - target.height))
                    }
                    let moved = abs(actual.minX - target.minX) > 4 || abs(actual.minY - target.minY) > 4
                    let resized = abs(actual.width - target.width) > 4 || abs(actual.height - target.height) > 4
                    guard moved || resized else { continue }
                    suppressObservationUntil = Date().addingTimeInterval(2)
                    // Correct only the part that is wrong: sending both again can make an app drop one of them again.
                    if resized && moved { window.setFrame(target) } else if resized { window.setSize(target.size) } else { window.setPosition(target.origin) }
                    retried += 1
                }
                if retried == 0 { return }
                Self.log("settle: set \(retried) window(s) again")
            }
        }
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
        guard Date() >= suppressObservationUntil, !suggestion.isVisible else { return }
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

    /// Everything about the last arrangement, for debugging: what was seen, how the windows were ranked, what was applied.
    private func dumpLastArrangement(request: LayoutRequest, ranking: WindowRanking, final: LayoutPlan, rejected: [String], apps: [String]) {
        struct Dump: Codable {
            var request: LayoutRequest
            var ranking: WindowRanking
            var appliedPlan: LayoutPlan
            var rejectedWindows: [String]
            var apps: [String]
        }
        // Window titles and the focus history: written only by developer builds.
        #if DEBUG || DEV_HOOKS
        let dump = Dump(request: request, ranking: ranking, appliedPlan: final, rejectedWindows: rejected, apps: apps)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = historyURL.deletingLastPathComponent().appendingPathComponent("last-arrangement.json")
        try? LocalFiles.write(encoder.encode(dump), to: url)
        #endif
    }

    /// Appends one line to status.log next to the history file; `log show` does not reliably surface NSLog for this app.
    public static func log(_ message: String) {
        let url = defaultHistoryURL.deletingLastPathComponent().appendingPathComponent("status.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        LocalFiles.append(Data(line.utf8), to: url)
    }

    /// Forget the cached ranking so the next arrangement asks the model again.
    public func invalidateCache() {
        cachedRanking = nil
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
    /// focused one came from. Always local and instant, never asks the model: with nothing arranged on that display
    /// yet, its template is filled from the local ranking with the focused window in main.
    public func promoteFocused() {
        let now = Date()
        let snapshot = enumerator.snapshot(lastActive: lastActive, windowFocus: windowFocus, now: now)
        guard let focused = snapshot.windows.first(where: { $0.isFocused }) else {
            update(L("No focused window", "没有焦点窗口"), planner: nil)
            return
        }
        let request = makeRequest(from: snapshot, now: now).restricted(to: focused.displayID)
        let previous: DisplayChoice
        if let last = previousChoices(for: snapshot.windows).first(where: { $0.id == focused.displayID }), last.slots.contains(where: { $0.slot == "main" }) {
            previous = last
        } else {
            guard let display = request.displays.first else { return }
            let templates = LayoutTemplates.candidates(for: display)
            let ranking = cachedOrLocalRanking(for: request)
            let needed = ranking.windows.filter { $0.role == .task }.count
            let index = LayoutTemplates.startingTemplate(in: templates, remembered: history.templateChoice[LayoutTemplates.sizeClass(of: display)], needed: needed)
            // Laid out as the windows are now: every block flies from where its window is.
            let filled = LayoutTemplates.fill(templates[index], on: display, ranking: ranking, request: request)
            let plan = PlanValidator.sanitized(LayoutTemplates.plan(from: TemplatePlan(summary: "", notes: "", displays: [filled]), for: request), for: request)
            let currentFrames = Dictionary(request.windows.map { ($0.id, $0.frame.cgRect) }, uniquingKeysWith: { a, _ in a })
            let blocks = windowBlocks(plan, choice: filled)
            let before = blocks.compactMap { block in Int(block.key.dropFirst()).flatMap { currentFrames[$0] }.map { ArrangementPreview.Slot(key: block.key, rect: $0, role: .tile) } }
            preview.flash(from: before, to: blocks, caption: .init(text: L("Bring to Main", "移到主位"), index: 0, count: 0)) { [weak self] done in
                self?.apply(plan, to: snapshot, frontID: focused.id, whenVisible: done)
            }
            remember([filled], windows: request.windows)
            update(L("Brought \(focused.app) to main (\(filled.template))", "已把 \(focused.app) 移到主位（\(filled.template)）"), planner: "local")
            return
        }

        let choice = LayoutTemplates.fitted(LayoutTemplates.promoted(previous, focusedID: focused.id), for: request)
        let plan = LayoutTemplates.design(from: TemplatePlan(summary: L("Brought \(focused.app) to main", "已把 \(focused.app) 移到主位"), notes: history.notes, displays: [choice]), for: request)
        var composed = LayoutComposer.plan(from: plan, for: request)
        composed.choices = [choice]
        let safe = PlanValidator.sanitized(composed, for: request)
        // The block of the window flies into main and the old main's block flies out to its new place.
        let before = LayoutTemplates.plan(from: TemplatePlan(summary: "", notes: "", displays: [previous]), for: request)
        preview.flash(from: windowBlocks(before, choice: previous), to: windowBlocks(safe, choice: choice),
                      caption: .init(text: L("Bring to Main", "移到主位"), index: 0, count: 0)) { [weak self] done in
            self?.apply(safe, to: snapshot, frontID: focused.id, whenVisible: done)
        }
        remember(safe.choices, windows: request.windows)
        update(L("Brought \(focused.app) to main (\(choice.template))", "已把 \(focused.app) 移到主位（\(choice.template)）"), planner: "local")
    }

    // MARK: - Presets

    public var presets: [LayoutPreset] { history.presets }
    /// Called when presets are added or removed, so the menu can list them.
    public var onPresetsChange: (() -> Void)?

    /// True when there is an applied template layout to save (after Smart Arrange, Bring to Main, or restoring a preset).
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
            update(L("Nothing to save yet: arrange first (\(WindowAction.smartArrange.shortcutDescription))", "还没有可保存的布局：先按 \(WindowAction.smartArrange.shortcutDescription) 排列"), planner: nil)
            onBusyChange?(false, L("Arrange first (\(WindowAction.smartArrange.shortcutDescription)), then save the layout", "先按 \(WindowAction.smartArrange.shortcutDescription) 排列，再保存布局"))
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
        cachedRanking = nil
        saveHistory()
    }

    public func setAppStyle(_ style: ArrangementStyle?, for bundleID: String) {
        history.appStyles[bundleID] = style
        cachedRanking = nil
        saveHistory()
    }

    public func clearCorrections() {
        history.corrections.removeAll()
        cachedRanking = nil
        saveHistory()
    }

    /// Forgets what was learned; saved presets are the user's own and stay.
    public func resetLearning() {
        activitySaveTask?.cancel()
        var fresh = LayoutHistory()
        fresh.presets = history.presets
        history = fresh
        focusTimeline = []
        windowFocus = [:]
        lastActive = [:]
        cachedRanking = nil
        lastRequest = nil
        saveHistory()
        try? FileManager.default.removeItem(at: historyURL.deletingLastPathComponent().appendingPathComponent("last-arrangement.json"))
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
