import ApplicationServices
import AppKit
import CoreGraphics

public enum AccessibilityPermission {
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    public static func requestTrustPrompt() {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// System Settings → Privacy & Security → Accessibility, where the user turns the switch on.
    public static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Sendable: an AXUIElement is an immutable reference to another app's element, and Accessibility calls for different
/// apps may run concurrently (arranging moves each app's windows in parallel).
public struct ManagedWindow: Equatable, @unchecked Sendable {
    private let element: AXUIElement

    public init(element: AXUIElement) {
        self.element = element
    }

    public static func == (lhs: ManagedWindow, rhs: ManagedWindow) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    public var frame: CGRect? {
        guard
            let position = value(for: kAXPositionAttribute, type: .cgPoint),
            let size = value(for: kAXSizeAttribute, type: .cgSize)
        else {
            return nil
        }

        var point = CGPoint.zero
        var windowSize = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &windowSize)
        return CGRect(origin: point, size: windowSize)
    }

    public var isStandardMovableWindow: Bool {
        let role = stringValue(for: kAXRoleAttribute)
        let subrole = stringValue(for: kAXSubroleAttribute)
        return role != kAXSheetRole && subrole != kAXSystemDialogSubrole
    }

    /// True for ordinary app windows. Some apps report no subrole at all, and Electron apps (Codex, ChatGPT) label real
    /// windows as dialogs, so a resizable "dialog" of reasonable size counts as a window too.
    public var isStandardWindow: Bool {
        guard stringValue(for: kAXRoleAttribute) == kAXWindowRole else { return false }
        let subrole = stringValue(for: kAXSubroleAttribute)
        if subrole == nil || subrole == kAXStandardWindowSubrole || subrole == "AXUnknown" { return true }
        // A real dialog has only a close button; an app window mislabelled as a dialog still has minimize and zoom.
        if subrole == kAXDialogSubrole, hasWindowButtons, let frame, frame.width >= 300, frame.height >= 200 { return true }
        return false
    }

    public var hasWindowButtons: Bool {
        var minimize: CFTypeRef?
        var zoom: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXMinimizeButtonAttribute as CFString, &minimize) == .success
            && AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &zoom) == .success
    }

    public var debugDescription: String {
        let size = frame.map { "\(Int($0.width))x\(Int($0.height))" } ?? "no frame"
        return "\(roleDescription) \(size) resizable=\(isResizable) buttons=\(hasWindowButtons) minimized=\(isMinimized)"
    }

    public var isResizable: Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    public var title: String {
        stringValue(for: kAXTitleAttribute) ?? ""
    }

    public var roleDescription: String {
        "\(stringValue(for: kAXRoleAttribute) ?? "nil")/\(stringValue(for: kAXSubroleAttribute) ?? "nil")"
    }

    public var isMinimized: Bool {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &rawValue) == .success else {
            return false
        }
        return (rawValue as? Bool) ?? false
    }

    /// With the current frame known, each window is resized at most once: a resize is what costs time, because apps
    /// lay out their content again (iTerm reflows its whole scrollback). A window that only moves is not resized at all;
    /// one that shrinks is resized before it moves, so it never sticks out past the screen edge on the way. Without it,
    /// size is set before and after the position, for apps that clamp the size while moving.
    public func setFrame(_ frame: CGRect, from current: CGRect? = nil) {
        var origin = frame.origin
        var size = frame.size
        guard
            let position = AXValueCreate(.cgPoint, &origin),
            let dimensions = AXValueCreate(.cgSize, &size)
        else {
            return
        }
        let setSize = { _ = AXUIElementSetAttributeValue(self.element, kAXSizeAttribute as CFString, dimensions) }
        let setPosition = { _ = AXUIElementSetAttributeValue(self.element, kAXPositionAttribute as CFString, position) }

        withoutEnhancedInterface {
            guard let current else {
                setSize(); setPosition(); setSize()
                return
            }
            let resize = abs(current.width - frame.width) > 0.5 || abs(current.height - frame.height) > 0.5
            let move = abs(current.minX - frame.minX) > 0.5 || abs(current.minY - frame.minY) > 0.5
            let shrinking = frame.width <= current.width && frame.height <= current.height
            switch (resize, move) {
            case (false, false): break
            case (false, true): setPosition()
            case (true, false): setSize()
            case (true, true): if shrinking { setSize(); setPosition() } else { setPosition(); setSize() }
            }
        }
    }

    /// Only the size, or only the position: for correcting the one part an app did not take.
    public func setSize(_ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        withoutEnhancedInterface { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
    }

    public func setPosition(_ origin: CGPoint) {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        withoutEnhancedInterface { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
    }

    /// An app with AXEnhancedUserInterface on (set by VoiceOver or another assistive app) animates every frame change
    /// and drops the changes that arrive meanwhile: a move followed by a resize ends up as just one of the two. Turn it
    /// off for the move and back on afterwards, as Rectangle does.
    private func withoutEnhancedInterface(_ body: () -> Void) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return body() }
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        let enhanced = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &raw) == .success && (raw as? Bool) == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        body()
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    /// This window on top of everything: raised within its app, made the app's main window, and the app made frontmost.
    /// Only this window comes forward, not the app's other windows.
    public func bringToFront(pid: pid_t) {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private func value(for attribute: String, type: AXValueType) -> AXValue? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard
            error == .success,
            let value = rawValue,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == type else {
            return nil
        }
        return axValue
    }

    private func stringValue(for attribute: String) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        return rawValue as? String
    }
}

public final class AccessibilityClient {
    public init() {}

    public func focusedWindow() -> ManagedWindow? {
        guard
            let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var rawWindow: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &rawWindow)
        guard
            error == .success,
            let windowElement = rawWindow,
            CFGetTypeID(windowElement) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return ManagedWindow(element: windowElement as! AXUIElement)
    }

    /// All windows of one app, front to back. Apps that do not answer within `timeout` seconds are skipped.
    public func windows(of pid: pid_t, timeout: Float = 0.25) -> [ManagedWindow] {
        windowsWithStatus(of: pid, timeout: timeout).windows
    }

    /// Windows plus a short note on how they were found, for the log. Electron and Chromium apps (Claude, Codex,
    /// Slack…) build their accessibility tree only after an assistive app asks for it with AXManualAccessibility, build
    /// it asynchronously, and may drop it again when idle; until then they answer with no windows. When an app has
    /// windows on screen but reports none, switch the attribute off and on (setting it while it is already on does
    /// nothing) and give the app up to 0.6 s to answer. Missing the frontmost window would leave it covering the layout.
    public func windowsWithStatus(of pid: pid_t, timeout: Float = 0.25) -> (windows: [ManagedWindow], note: String) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, timeout)
        let (first, error) = copyWindows(appElement)
        if !first.isEmpty || !Self.hasOnScreenWindows(pid) {
            return (first, error == .success ? "" : "ax error \(error.rawValue)")
        }
        // AXManualAccessibility only: AXEnhancedUserInterface would also expose the windows, but makes the app animate
        // frame changes and drop the ones that overlap.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        var (second, retryError) = copyWindows(appElement)
        var waited = 0
        while second.isEmpty, waited < 600 {
            usleep(100_000)
            waited += 100
            (second, retryError) = copyWindows(appElement)
        }
        return (second, "retried after enabling accessibility for \(waited) ms (first: ax \(error.rawValue), retry: ax \(retryError.rawValue))")
    }

    private func copyWindows(_ appElement: AXUIElement) -> ([ManagedWindow], AXError) {
        var rawWindows: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
        guard error == .success, let elements = rawWindows as? [AXUIElement] else { return ([], error) }
        return (elements.map { ManagedWindow(element: $0) }, error)
    }

    /// Normal-layer windows of this process that the window server shows on the current Space.
    static func hasOnScreenWindows(_ pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == pid
                && (info[kCGWindowLayer as String] as? Int) == 0
                && ((info[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) >= 100
        }
    }
}
