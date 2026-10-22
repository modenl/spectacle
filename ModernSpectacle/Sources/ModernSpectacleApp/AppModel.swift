import AppKit
import ModernSpectacleCore
import ModernSpectacleServices

@MainActor
final class AppModel {
    private(set) var accessibilityTrusted: Bool = AccessibilityPermission.isTrusted
    private(set) var shortcutsEnabled = true
    private(set) var arrangeStatus = L("Idle", "空闲")
    private(set) var hasAPIKey = KeychainStore.hasAPIKey
    /// Human-readable state of the stored key: shape and whether the API accepts it.
    private(set) var apiKeyStatus = KeychainStore.hasAPIKey ? L("Stored, not checked yet", "已保存，尚未检查") : L("Not set", "未设置")
    /// True once the API accepted the stored key.
    private(set) var apiKeyValid = false

    /// Called after any state above changes so the UI can re-read it.
    var onChange: (() -> Void)?
    /// Called when the API key is added or removed, so the menu can enable or disable Smart Arrange.
    var onAPIKeyChange: (() -> Void)?
    /// True while Smart Arrange is waiting for the model; the menu bar icon reflects it.
    var onBusyChange: ((Bool) -> Void)?
    /// Called after the UI language changes, so menus and windows rebuild their text.
    var onLanguageChange: (() -> Void)?
    private let notice = SuggestionPanel()
    private let hud = ProgressHUD()

    let loginItems = LoginItemController()
    let updates = UpdateChecker()
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
        // The token must be kept, or the observer silently goes away.
        triggerObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("xyz.alvumo.ModernSpectacle.arrange"), object: nil, queue: .main
        ) { [weak self] note in
            let fresh = note.userInfo?["fresh"] != nil
            Task { @MainActor in
                if fresh { self?.smartArranger.invalidateCache() }
                self?.perform(.smartArrange)
            }
        }
        // `spectacle-cli trigger <command> [argument]` posts this: any WindowAction by name, restore <n>, save <name>,
        // delete <name>, check-updates. Lets every feature be exercised without pressing keys.
        commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("xyz.alvumo.ModernSpectacle.command"), object: nil, queue: .main
        ) { [weak self] note in
            let command = note.userInfo?["command"] as? String ?? ""
            let argument = note.userInfo?["argument"] as? String ?? ""
            Task { @MainActor in self?.runCommand(command, argument: argument) }
        }
    }

    private func runCommand(_ command: String, argument: String) {
        SmartArranger.log("command \(command) \(argument)")
        switch command {
        case "restore": restorePreset(at: (Int(argument) ?? 1) - 1)
        case "save": if requireAccessibility() { smartArranger.savePreset(named: argument) }
        case "delete": smartArranger.deletePreset(named: argument)
        case "check-updates": checkForUpdatesNow()
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
        notice.show(
            message: L(
                "Modern Spectacle needs Accessibility permission to move windows. Turn on Modern Spectacle in System Settings → Privacy & Security → Accessibility, then try again.",
                "Modern Spectacle 需要辅助功能权限才能移动窗口。请在 系统设置 → 隐私与安全性 → 辅助功能 里打开 Modern Spectacle，然后再试一次。"
            ),
            acceptTitle: L("Open Settings", "打开设置"),
            near: mainDisplayFrame,
            timeout: 30
        ) {
            AccessibilityPermission.requestTrustPrompt()
            AccessibilityPermission.openSettings()
        }
        return false
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
            guard hasAPIKey else {
                let frame = WindowEnumerator.currentDisplays().first?.visibleFrame ?? .zero
                notice.show(message: L("Smart Arrange needs a Claude API key.", "智能排列需要 Claude API Key。"), acceptTitle: L("Open Settings", "打开设置"), near: frame) { [weak self] in
                    self?.showSettings()
                }
                return
            }
            Task { await smartArranger.arrange() }
            return
        }
        windowController.perform(action)
    }

    private func registerShortcuts() {
        hotKeys.registerDefaultShortcuts(
            handler: { [weak self] action in self?.perform(action) },
            presetHandler: { [weak self] index in self?.restorePreset(at: index) }
        )
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
            hud.show(L("Arrange first (⌃⌥⌘A), then save the layout", "先按 ⌃⌥⌘A 排列，再保存布局"), near: frame, spinning: false, autoHideAfter: 3)
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

    // MARK: - Updates

    private var mainDisplayFrame: CGRect {
        WindowEnumerator.currentDisplays().first { $0.isMain }?.visibleFrame ?? WindowEnumerator.currentDisplays().first?.visibleFrame ?? .zero
    }

    /// At launch: once a day at most, silent unless there is something new.
    func checkForUpdatesIfDue() {
        guard updates.isCheckDue else { return }
        Task {
            if case let .available(release) = await updates.check(userInitiated: false) {
                showUpdate(release)
            }
        }
    }

    /// From the menu or Settings: always says what it found.
    func checkForUpdatesNow() {
        hud.show(L("Checking for updates…", "正在检查更新…"), near: mainDisplayFrame)
        Task {
            let result = await updates.check(userInitiated: true)
            switch result {
            case let .available(release):
                hud.hide()
                showUpdate(release)
            case let .upToDate(version):
                hud.show(L("ModernSpectacle \(version) is up to date", "ModernSpectacle \(version) 已是最新版本"), near: mainDisplayFrame, spinning: false, autoHideAfter: 3)
            case let .failed(detail):
                hud.show(L("Could not check for updates: \(detail)", "检查更新失败：\(detail)"), near: mainDisplayFrame, spinning: false, autoHideAfter: 4)
            }
        }
    }

    private func showUpdate(_ release: StoreRelease) {
        let notes = release.notes.count > 240 ? String(release.notes.prefix(240)) + "…" : release.notes
        let headline = L(
            "ModernSpectacle \(release.version) is available (you have \(UpdateChecker.currentVersion)).",
            "ModernSpectacle \(release.version) 已发布（当前 \(UpdateChecker.currentVersion)）。"
        )
        notice.show(
            message: notes.isEmpty ? headline : "\(headline)\n\n\(notes)",
            acceptTitle: L("Download", "下载"),
            dismissTitle: L("Later", "以后再说"),
            alternateTitle: L("Skip This Version", "跳过此版本"),
            near: mainDisplayFrame,
            timeout: 60,
            onAccept: { NSWorkspace.shared.open(release.download?.url ?? release.url) },
            onAlternate: { [weak self] in self?.updates.skip(release.version) }
        )
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

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainStore.set(trimmed, for: KeychainStore.apiKeyAccount)
        } catch {
            NSLog("Could not store API key: \(error)")
            apiKeyStatus = L("Could not save to Keychain (error \(error))", "无法保存到钥匙串（错误 \(error)）")
        }
        hasAPIKey = KeychainStore.hasAPIKey
        smartArranger.apiKeyDidChange()
        onChange?()
        onAPIKeyChange?()
        if hasAPIKey {
            checkAPIKey()
        } else {
            apiKeyStatus = L("Not set", "未设置")
            apiKeyValid = false
            onChange?()
        }
    }

    /// Describes the key's shape, then asks the API whether it is accepted. Never shows the key itself.
    func checkAPIKey() {
        guard let key = KeychainStore.string(for: KeychainStore.apiKeyAccount), !key.isEmpty else {
            apiKeyStatus = L("Not set", "未设置")
            apiKeyValid = false
            onChange?()
            return
        }
        let shape = L("\(key.prefix(7))… \(key.count) chars", "\(key.prefix(7))…，\(key.count) 个字符")
        if !key.hasPrefix("sk-ant-") {
            apiKeyStatus = L("Looks wrong: Anthropic keys start with sk-ant-api03- (got \(shape))", "格式不对：Anthropic 的 Key 以 sk-ant-api03- 开头（当前是 \(shape)）")
            onChange?()
            return
        }
        apiKeyStatus = L("Checking \(shape)…", "正在检查 \(shape)…")
        apiKeyValid = false
        onChange?()
        Task { [weak self] in
            let result = await ClaudePlanner.check(apiKey: key)
            guard let self else { return }
            switch result {
            case .valid: apiKeyStatus = L("Valid (\(shape))", "有效（\(shape)）"); apiKeyValid = true
            case let .invalid(detail): apiKeyStatus = L("Rejected by the API: \(detail)", "API 拒绝了这个 Key：\(detail)")
            case let .unreachable(detail): apiKeyStatus = L("Could not reach the API: \(detail)", "连不上 API：\(detail)")
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
