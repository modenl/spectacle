import AppKit
import ApplicationServices

/// Reports when the user finishes moving or resizing windows of an app. Event-driven: one AXObserver per running app,
/// no polling. Moves we make ourselves are reported too; callers suppress those.
@MainActor
public final class WindowObserver {
    public struct Settled {
        public let pid: pid_t
        /// Titles of the windows that moved or resized since the last report.
        public let movedTitles: Set<String>
    }

    public var onSettled: ((Settled) -> Void)?
    /// A window of this app got keyboard focus (pid, window title).
    public var onFocusChanged: ((pid_t, String) -> Void)?
    public var settleDelay: TimeInterval = 0.7

    // The AX callback runs on the main run loop, so touching the main-actor owner from it is safe.
    private final class Box: @unchecked Sendable {
        let pid: pid_t
        weak var owner: WindowObserver?
        init(pid: pid_t, owner: WindowObserver) {
            self.pid = pid
            self.owner = owner
        }
    }

    private var observers: [pid_t: (observer: AXObserver, box: Unmanaged<Box>)] = [:]
    private var pending: [pid_t: (titles: Set<String>, task: Task<Void, Never>)] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []

    public init() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(app)
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.observe(app) }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in self?.stopObserving(pid) }
        })
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != ProcessInfo.processInfo.processIdentifier, observers[pid] == nil else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, WindowObserver.callback, &observer) == .success, let observer else { return }

        let box = Unmanaged.passRetained(Box(pid: pid, owner: self))
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        for name in [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, appElement, name as CFString, box.toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = (observer, box)
    }

    private func stopObserving(_ pid: pid_t) {
        guard let entry = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .defaultMode)
        entry.box.release()
        pending[pid]?.task.cancel()
        pending[pid] = nil
    }

    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let box = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
        let title = ManagedWindow(element: element).title
        let pid = box.pid
        let isFocus = (notification as String) == kAXFocusedWindowChangedNotification
        MainActor.assumeIsolated {
            let owner = box.owner
            if isFocus {
                owner?.onFocusChanged?(pid, title)
            } else {
                owner?.noteChange(pid: pid, title: title)
            }
        }
    }

    private func noteChange(pid: pid_t, title: String) {
        var titles = pending[pid]?.titles ?? []
        titles.insert(title)
        pending[pid]?.task.cancel()
        let delay = settleDelay
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let moved = pending.removeValue(forKey: pid)?.titles ?? []
            onSettled?(Settled(pid: pid, movedTitles: moved))
        }
        pending[pid] = (titles, task)
    }
}
