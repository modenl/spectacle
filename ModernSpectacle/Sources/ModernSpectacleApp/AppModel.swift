import AppKit
import ModernSpectacleCore
import ModernSpectacleServices

@MainActor
final class AppModel {
    private(set) var accessibilityTrusted: Bool = AccessibilityPermission.isTrusted
    private(set) var shortcutsEnabled = true
    private(set) var arrangeStatus = L("Idle", "空闲")

    /// Called after any state above changes so the UI can re-read it.
    var onChange: (() -> Void)?
    /// Called when the shortcuts change, so the menu can follow.
    var onMenuChange: (() -> Void)?
    /// True while Smart Arrange is waiting for the model; the menu bar icon reflects it.
    var onBusyChange: ((Bool) -> Void)?
    /// Called after the UI language changes, so menus and windows rebuild their text.
    var onLanguageChange: (() -> Void)?
    private let notice = SuggestionPanel()
    private let hud = ProgressHUD()

    let loginItems = LoginItemController()
    let updater = Updater()
    private let hotKeys = HotKeyCenter()
    private let windowController = WindowController()
    private let smartArranger: SmartArranger
    private var settings: SettingsWindowController?
    private var profile: ProfileWindowController?
    var arranger: SmartArranger { smartArranger }
    private var permissionObserver: NSObjectProtocol?
    private var triggerObserver: NSObjectProtocol?
    private var commandObserver: NSObjectProtocol?

    init() {
        smartArranger = SmartArranger(windowController: windowController)
        smartArranger.onStatusChange = { [weak self] status in
            self?.arrangeStatus = status.message
            self?.onChange?()
        }
        smartArranger.onBusyChange = { [weak self] busy, text in
            guard let self else { return }
            let frame = WindowEnumerator.currentDisplays().first { $0.isMain }?.visibleFrame
                ?? WindowEnumerator.currentDisplays().first?.visibleFrame ?? .zero
            if busy {
                hud.show(text, near: frame)
            } else if text.isEmpty {
                hud.hide()
            } else {
                // Done: show what happened for a moment, then go away.
                hud.show(text, near: frame, spinning: false, autoHideAfter: 3)
            }
            onBusyChange?(busy)
        }
        registerShortcuts()
        // Accessibility trust changes when the user flips the switch in System Settings; re-check when we come forward.
        permissionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        // A developer hook: `spectacle-cli trigger` posts this so arranging can be exercised without the hotkey.
        // The token must be kept, or the observer silently goes away. Any local process can post these and borrow
        // this app's Accessibility permission, so they exist only in debug builds and in `DEV_HOOKS=1 ./build-app.sh`.
        #if DEBUG || DEV_HOOKS
        triggerObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("xyz.alvumo.ModernSpectacle.arrange"), object: nil, queue: .main
        ) { [weak self] note in
            let fresh = note.userInfo?["fresh"] != nil
            Task { @MainActor in
                if fresh { self?.smartArranger.invalidateCache() }
                // The developer trigger presses no modifiers, so it arranges straight away.
                self?.smartArranger.cancelPreview()
                self?.perform(.smartArrange)
            }
        }
        // `spectacle-cli trigger <command> [argument]` posts this: any WindowAction by name, restore <n>, save <name>,
        // delete <name>, check-updates, check-updates-quietly, about, quit, show-notices. Lets every feature be exercised without pressing keys.
        commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("xyz.alvumo.ModernSpectacle.command"), object: nil, queue: .main
        ) { [weak self] note in
            let command = note.userInfo?["command"] as? String ?? ""
            let argument = note.userInfo?["argument"] as? String ?? ""
            Task { @MainActor in self?.runCommand(command, argument: argument) }
        }
        #endif
    }

    private func runCommand(_ command: String, argument: String) {
        SmartArranger.log("command \(command) \(argument)")
        switch command {
        case "restore": if let number = Int(argument), (1...9).contains(number) { restorePreset(at: number - 1) }
        case "save": if requireAccessibility() { smartArranger.savePreset(named: argument) }
        case "delete": smartArranger.deletePreset(named: argument)
        case "check-updates": updater.checkNow()
        case "check-updates-quietly": updater.checkInBackground()
        case "about": showAbout()
        case "quit": NSApp.terminate(nil) // a normal quit, so Sparkle installs a downloaded update
        // Shows the permission notice and the HUD with sample text, to check their layout.
        case "show-notices":
            hud.show(L("Checking for updates…", "正在检查更新…"), near: mainDisplayFrame, autoHideAfter: 10)
            showAccessibilityNotice()
        // Smart Arrange as if the modifiers stayed held: press shows or switches, release applies, cancel is Esc.
        case "press": if requireAccessibility() { smartArranger.smartArrangeKey(holding: true) }
        case "release": smartArranger.releaseModifiers()
        case "cancel": smartArranger.cancelPreview()
        case "forget": smartArranger.invalidateCache() // next press asks the model again
        default:
            if let action = WindowAction(rawValue: command) { perform(action) }
        }
    }

    /// Every window move needs Accessibility. Without it nothing can happen, so say so instead of failing silently,
    /// and open the place where it is switched on.
    @discardableResult
    func requireAccessibility() -> Bool {
        refreshPermissions()
        if accessibilityTrusted { return true }
        SmartArranger.log("blocked: no Accessibility permission")
        showAccessibilityNotice()
        return false
    }

    private func showAccessibilityNotice() {
        notice.show(
            message: L(
                "Modern Spectacle needs Accessibility permission to move windows. Turn on Modern Spectacle in System Settings → Privacy & Security → Accessibility, then try again. If it is already on, select it, remove it with −, and add it again: macOS keeps the permission for the copy it was given to.",
                "Modern Spectacle 需要辅助功能权限才能移动窗口。请在 系统设置 → 隐私与安全性 → 辅助功能 里打开 Modern Spectacle，然后再试一次。如果已经是打开的，选中它，点「−」删除后重新添加：macOS 只认当初授权的那份副本。"
            ),
            acceptTitle: L("Open Settings", "打开设置"),
            near: mainDisplayFrame,
            timeout: 30
        ) {
            AccessibilityPermission.requestTrustPrompt()
            AccessibilityPermission.openSettings()
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
        if !action.isHistoryAction, !requireAccessibility() {
            return
        }
        if action == .promoteFocused {
            smartArranger.promoteFocused()
            return
        }
        if action == .smartArrange {
            // Works without a key too: windows are then ranked locally by focus and recency.
            smartArranger.smartArrangeKey()
            return
        }
        windowController.perform(action)
    }

    private func registerShortcuts() {
        hotKeys.registerShortcuts(handler: { [weak self] action in self?.perform(action) })
    }

    // MARK: - Presets

    var presets: [LayoutPreset] { smartArranger.presets }
    var canSavePreset: Bool { smartArranger.canSavePreset }

    func restorePreset(at index: Int) {
        guard requireAccessibility() else { return }
        smartArranger.restorePreset(at: index)
    }

    func deletePreset(named name: String) {
        smartArranger.deletePreset(named: name)
    }

    /// Asks for a name and saves the layout that is applied now. Same name replaces that preset.
    func promptToSavePreset() {
        guard canSavePreset else {
            let frame = WindowEnumerator.currentDisplays().first { $0.isMain }?.visibleFrame ?? .zero
            hud.show(L("Arrange first (\(WindowAction.smartArrange.shortcutDescription)), then save the layout", "先按 \(WindowAction.smartArrange.shortcutDescription) 排列，再保存布局"), near: frame, spinning: false, autoHideAfter: 3)
            return
        }
        let alert = NSAlert()
        alert.messageText = L("Save Layout", "保存布局")
        alert.informativeText = L(
            "Saves which app sits in which place, so ⌃⌥⌘ and the layout's number puts the windows back. Using an existing name replaces it.",
            "记下每个应用放在哪个位置，之后按 ⌃⌥⌘ 加布局编号就能恢复。用已有的名字会覆盖原来的布局。"
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = L("Layout \(presets.count + 1)", "布局 \(presets.count + 1)")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save", "保存"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        smartArranger.savePreset(named: field.stringValue)
    }

    // MARK: - Language

    func setLanguage(_ language: AppLanguage) {
        guard language != Localization.language else { return }
        Localization.language = language
        smartArranger.invalidateCache() // cached summaries are in the old language
        settings?.rebuild()
        profile?.rebuild()
        onLanguageChange?()
    }

    // MARK: - Jev key

    /// What Settings shows about the stored key: its shape and whether TypeSafe accepts it, never the key.
    private(set) var jevKeyStatus = KeychainStore.jevKey?.isEmpty == false ? L("Stored in Keychain", "已存入钥匙串") : AppModel.noStoredKeyStatus

    private static var noStoredKeyStatus: String {
        JevRanker.hasBuiltInKey ? L("Using the key built into the app", "使用应用内置的 Key") : L("Not set: windows are ranked on this Mac", "未设置：在本机排序")
    }
    private(set) var jevKeyValid: Bool?

    /// An empty key removes it.
    func saveJevKey(_ key: String) {
        do {
            try KeychainStore.setJevKey(key)
        } catch {
            jevKeyStatus = L("Could not save to Keychain (\(error))", "无法存入钥匙串（\(error)）")
            jevKeyValid = false
            onChange?()
            return
        }
        smartArranger.invalidateCache()
        checkJevKey()
    }

    func checkJevKey() {
        guard let key = KeychainStore.jevKey, !key.isEmpty else {
            jevKeyStatus = Self.noStoredKeyStatus
            jevKeyValid = nil
            onChange?()
            return
        }
        let shape = L("\(key.prefix(6))…, \(key.count) characters", "\(key.prefix(6))…，\(key.count) 个字符")
        jevKeyStatus = L("Checking \(shape)…", "正在检查 \(shape)…")
        jevKeyValid = nil
        onChange?()
        Task { [weak self] in
            let result = await JevRanker.check(key: key)
            guard let self else { return }
            switch result {
            case .valid: (jevKeyStatus, jevKeyValid) = (L("Valid (\(shape))", "有效（\(shape)）"), true)
            case let .invalid(detail): (jevKeyStatus, jevKeyValid) = (L("Rejected: \(detail)", "被拒绝：\(detail)"), false)
            case let .unreachable(detail): (jevKeyStatus, jevKeyValid) = (L("Could not reach TypeSafe: \(detail)", "连不上 TypeSafe：\(detail)"), false)
            }
            onChange?()
        }
    }

    private var mainDisplayFrame: CGRect {
        WindowEnumerator.currentDisplays().first { $0.isMain }?.visibleFrame ?? WindowEnumerator.currentDisplays().first?.visibleFrame ?? .zero
    }

    func setShortcutsEnabled(_ enabled: Bool) {
        shortcutsEnabled = enabled
        if enabled {
            registerShortcuts()
        } else {
            hotKeys.unregisterAll()
        }
        onChange?()
    }

    // MARK: - Shortcuts

    /// While a new shortcut is being recorded, the global hotkeys must not fire (they would swallow the key press).
    func beginShortcutRecording() {
        hotKeys.unregisterAll()
    }

    func endShortcutRecording() {
        if shortcutsEnabled { registerShortcuts() }
    }

    /// Re-registers the hotkeys and refreshes the menu after the user changed a shortcut.
    func shortcutsDidChange() {
        if shortcutsEnabled { registerShortcuts() }
        onMenuChange?()
        onChange?()
    }

    /// A menu bar app is not active when its menu is used, and the About panel stays hidden until it is.
    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
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

    func showProfile() {
        if profile == nil {
            profile = ProfileWindowController(model: self)
        }
        NSApp.activate(ignoringOtherApps: true)
        profile?.showWindow(nil)
        profile?.window?.makeKeyAndOrderFront(nil)
    }

    func profileDidClose() {
        profile = nil
    }
}
