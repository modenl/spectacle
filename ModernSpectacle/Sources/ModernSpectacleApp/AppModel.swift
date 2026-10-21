import AppKit
import ModernSpectacleCore
import ModernSpectacleServices

@MainActor
final class AppModel {
    private(set) var accessibilityTrusted: Bool = AccessibilityPermission.isTrusted
    private(set) var shortcutsEnabled = true
    private(set) var arrangeStatus = "Idle"
    private(set) var hasAPIKey = KeychainStore.hasAPIKey
    /// Human-readable state of the stored key: shape and whether the API accepts it.
    private(set) var apiKeyStatus = KeychainStore.hasAPIKey ? "Stored, not checked yet" : "Not set"

    /// Called after any state above changes so the UI can re-read it.
    var onChange: (() -> Void)?
    /// Called when the API key is added or removed, so the menu can enable or disable Smart Arrange.
    var onAPIKeyChange: (() -> Void)?
    private let notice = SuggestionPanel()

    let loginItems = LoginItemController()
    private let hotKeys = HotKeyCenter()
    private let windowController = WindowController()
    private let smartArranger: SmartArranger
    private var settings: SettingsWindowController?
    private var permissionObserver: NSObjectProtocol?

    init() {
        smartArranger = SmartArranger(windowController: windowController)
        smartArranger.onStatusChange = { [weak self] status in
            self?.arrangeStatus = status.message
            self?.onChange?()
        }
        hotKeys.registerDefaultShortcuts { [weak self] action in
            self?.perform(action)
        }
        // Accessibility trust changes when the user flips the switch in System Settings; re-check when we come forward.
        permissionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        // A developer hook: `spectacle-cli trigger` posts this so arranging can be exercised without the hotkey.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("xyz.alvumo.ModernSpectacle.arrange"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.perform(.smartArrange) }
        }
    }

    func refreshPermissions() {
        let trusted = AccessibilityPermission.isTrusted
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            onChange?()
        }
    }

    func requestAccessibilityAccess() {
        AccessibilityPermission.requestTrustPrompt()
        refreshPermissions()
    }

    func perform(_ action: WindowAction) {
        guard shortcutsEnabled || action.isHistoryAction else {
            return
        }
        if action == .smartArrange {
            guard hasAPIKey else {
                let frame = WindowEnumerator.currentDisplays().first?.visibleFrame ?? .zero
                notice.show(message: "Smart Arrange needs a Claude API key.", acceptTitle: "Open Settings", near: frame) { [weak self] in
                    self?.showSettings()
                }
                return
            }
            Task { await smartArranger.arrange() }
            return
        }
        windowController.perform(action)
    }

    func setShortcutsEnabled(_ enabled: Bool) {
        shortcutsEnabled = enabled
        if enabled {
            hotKeys.registerDefaultShortcuts { [weak self] action in
                self?.perform(action)
            }
        } else {
            hotKeys.unregisterAll()
        }
        onChange?()
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainStore.set(trimmed, for: KeychainStore.apiKeyAccount)
        } catch {
            NSLog("Could not store API key: \(error)")
            apiKeyStatus = "Could not save to Keychain (error \(error))"
        }
        hasAPIKey = KeychainStore.hasAPIKey
        smartArranger.apiKeyDidChange()
        onChange?()
        onAPIKeyChange?()
        if hasAPIKey {
            checkAPIKey()
        } else {
            apiKeyStatus = "Not set"
            onChange?()
        }
    }

    /// Describes the key's shape, then asks the API whether it is accepted. Never shows the key itself.
    func checkAPIKey() {
        guard let key = KeychainStore.string(for: KeychainStore.apiKeyAccount), !key.isEmpty else {
            apiKeyStatus = "Not set"
            onChange?()
            return
        }
        let shape = "\(key.prefix(7))… \(key.count) chars"
        if !key.hasPrefix("sk-ant-") {
            apiKeyStatus = "Looks wrong: Anthropic keys start with sk-ant-api03- (got \(shape))"
            onChange?()
            return
        }
        apiKeyStatus = "Checking \(shape)…"
        onChange?()
        Task { [weak self] in
            let result = await ClaudePlanner.check(apiKey: key)
            guard let self else { return }
            switch result {
            case .valid: apiKeyStatus = "Valid (\(shape))"
            case let .invalid(detail): apiKeyStatus = "Rejected by the API: \(detail)"
            case let .unreachable(detail): apiKeyStatus = "Could not reach the API: \(detail)"
            }
            onChange?()
        }
    }

    func showSettings() {
        refreshPermissions()
        if settings == nil {
            let controller = SettingsWindowController(model: self)
            settings = controller
            onChange = { [weak controller] in controller?.refresh() }
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    func settingsDidClose() {
        settings = nil
        onChange = nil
    }
}
