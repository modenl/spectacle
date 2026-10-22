import AppKit
import ModernSpectacleCore
import ModernSpectacleServices

/// Plain AppKit settings window. Built on demand and released on close so it costs nothing while hidden.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let accessibilityButton = NSButton(title: "", target: nil, action: nil)
    private let loginToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let updatesToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelStatus = NSTextField(labelWithString: "")
    private let loginError = NSTextField(wrappingLabelWithString: "")
    private let arrangeStatus = NSTextField(wrappingLabelWithString: "")
    private var shortcutButtons: [WindowAction: NSButton] = [:]
    private let shortcutMessage = NSTextField(wrappingLabelWithString: "")
    private var recording: WindowAction?
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureControls()
        rebuild()
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Lays the window out again with the current language.
    func rebuild() {
        stopRecording()
        window?.title = L("Modern Spectacle Settings", "Modern Spectacle 设置")
        accessibilityButton.title = L("Open Accessibility Prompt", "打开辅助功能授权")
        loginToggle.title = L("Launch at Login", "登录时启动")
        updatesToggle.title = L("Check for updates automatically (once a day)", "自动检查更新（每天一次）")
        languagePopup.removeAllItems()
        for language in AppLanguage.allCases {
            languagePopup.addItem(withTitle: language.title)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: Localization.language) ?? 0)
        let content = buildContent()
        window?.contentView = scrolling(content)
        // As tall as the content, but never taller than the screen: the shortcut list alone is longer than a laptop's.
        let screenHeight = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let height = min(content.fittingSize.height, screenHeight - 40)
        window?.setContentSize(NSSize(width: max(content.fittingSize.width, 560), height: height))
        window?.contentMinSize = NSSize(width: 560, height: 300)
        refresh()
    }

    /// The settings in a vertical scroll view, starting at the top.
    private func scrolling(_ content: NSView) -> NSView {
        let document = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    func refresh() {
        let trusted = model.accessibilityTrusted
        accessibilityStatus.stringValue = trusted ? L("Granted", "已授权") : L("Required", "需要授权")
        accessibilityStatus.textColor = trusted ? .secondaryLabelColor : .systemRed
        accessibilityButton.isEnabled = !trusted

        loginToggle.state = model.loginItems.isEnabled ? .on : .off
        loginError.stringValue = model.loginItems.lastError ?? ""
        loginError.isHidden = model.loginItems.lastError == nil

        switch AppleRanker.status {
        case .available:
            modelStatus.stringValue = L("Apple Intelligence: on this Mac, nothing leaves it", "Apple Intelligence：在本机运行，数据不离开这台 Mac")
            modelStatus.textColor = .systemGreen
        case .notReady:
            modelStatus.stringValue = L("Apple Intelligence: model still downloading", "Apple Intelligence：模型还在下载")
            modelStatus.textColor = .systemOrange
        case .notEnabled:
            modelStatus.stringValue = L("Apple Intelligence is off", "Apple Intelligence 未开启")
            modelStatus.textColor = .systemOrange
        case .unsupported:
            modelStatus.stringValue = L("Apple Intelligence is not available on this Mac", "这台 Mac 不支持 Apple Intelligence")
            modelStatus.textColor = .secondaryLabelColor
        }
        arrangeStatus.stringValue = model.arrangeStatus
        updatesToggle.state = model.updates.automaticChecks ? .on : .off
        for (action, button) in shortcutButtons where action != recording {
            button.title = action.shortcutDescription
        }
    }

    /// Targets and actions: set once, not on every rebuild.
    private func configureControls() {
        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibility)
        loginToggle.target = self
        loginToggle.action = #selector(toggleLogin)
        updatesToggle.target = self
        updatesToggle.action = #selector(toggleUpdates)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        shortcutMessage.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shortcutMessage.preferredMaxLayoutWidth = 480
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        stack.addArrangedSubview(header(L("Permissions", "权限")))
        stack.addArrangedSubview(row(L("Accessibility", "辅助功能"), trailing: accessibilityStatus))
        stack.addArrangedSubview(accessibilityButton)

        stack.addArrangedSubview(header(L("General", "通用")))
        stack.addArrangedSubview(row(L("Language", "语言"), trailing: languagePopup))
        stack.addArrangedSubview(loginToggle)
        loginError.textColor = .systemRed
        loginError.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(loginError)
        #if !APP_STORE
        let checkNow = NSButton(title: L("Check Now", "立即检查"), target: self, action: #selector(checkForUpdates))
        let updatesRow = NSStackView(views: [updatesToggle, checkNow])
        updatesRow.orientation = .horizontal
        stack.addArrangedSubview(updatesRow)
        #endif
        stack.addArrangedSubview(small(L("Version \(UpdateChecker.currentVersion)", "版本 \(UpdateChecker.currentVersion)")))

        stack.addArrangedSubview(header(L("Smart Arrange", "智能排列")))
        let intelligenceButton = NSButton(title: L("Open Settings", "打开设置"), target: self, action: #selector(openAppleIntelligence))
        let modelRow = NSStackView(views: [modelStatus, intelligenceButton])
        modelRow.orientation = .horizontal
        stack.addArrangedSubview(modelRow)
        stack.addArrangedSubview(small(L(
            "Apple's on-device model decides which windows matter now; templates and sizes are computed on this Mac. Without it, windows are ranked by focus and recency.",
            "由 Apple 本机模型判断哪些窗口当前重要，模版和尺寸都在本机计算。模型不可用时，按焦点和最近使用排序。"
        )))
        let profileButton = NSButton(title: L("Layout Profile…", "布局档案…"), target: self, action: #selector(openProfile))
        stack.addArrangedSubview(profileButton)
        stack.addArrangedSubview(row(L("Last arrangement", "上次排列"), trailing: arrangeStatus))
        arrangeStatus.textColor = .secondaryLabelColor
        arrangeStatus.maximumNumberOfLines = 3
        arrangeStatus.preferredMaxLayoutWidth = 360

        stack.addArrangedSubview(header(L("Shortcuts", "快捷键")))
        stack.addArrangedSubview(small(L(
            "Click a shortcut, then press the new combination. Esc cancels, Delete removes it. Press Smart Arrange again while still holding the modifiers to switch template.",
            "点一下快捷键，再按新的组合。Esc 取消，Delete 删除。按住修饰键再按一次智能排列，可切换模版。"
        )))
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = 24
        grid.rowSpacing = 2
        shortcutButtons = [:]
        for (index, action) in WindowAction.allCases.enumerated() {
            let button = NSButton(title: action.shortcutDescription, target: self, action: #selector(recordShortcut(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            shortcutButtons[action] = button
            grid.addRow(with: [NSTextField(labelWithString: action.title), button])
        }
        let presetShortcut = NSTextField(labelWithString: "⌃⌥⌘1…9")
        presetShortcut.textColor = .secondaryLabelColor
        grid.addRow(with: [NSTextField(labelWithString: L("Restore Saved Layout", "恢复保存的布局")), presetShortcut])
        stack.addArrangedSubview(grid)
        stack.addArrangedSubview(shortcutMessage)
        stack.addArrangedSubview(NSButton(title: L("Restore Default Shortcuts", "恢复默认快捷键"), target: self, action: #selector(resetShortcuts)))

        for view in stack.arrangedSubviews {
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20).isActive = true
            view.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor, constant: -20).isActive = true
        }
        return stack
    }

    private func header(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        return label
    }

    private func small(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 500
        return label
    }

    private func row(_ title: String, trailing: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        let row = NSStackView(views: [label, trailing])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    // MARK: - Recording shortcuts

    @objc private func recordShortcut(_ sender: NSButton) {
        let action = WindowAction.allCases[sender.tag]
        stopRecording()
        recording = action
        sender.title = L("Press keys…", "请按快捷键…")
        shortcutMessage.stringValue = ""
        model.beginShortcutRecording()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, recording != nil else { return event }
            handleRecorded(event)
            return nil
        }
    }

    private func handleRecorded(_ event: NSEvent) {
        guard let action = recording else { return }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let keyCode = UInt32(event.keyCode)
        if flags.isEmpty, keyCode == 53 { // Esc
            stopRecording()
            return
        }
        if flags.isEmpty, keyCode == 51 || keyCode == 117 { // Delete removes the shortcut
            ShortcutStore.set(keyCode: nil, modifiers: 0, for: action)
            finishRecording(message: L("Removed the shortcut for \(action.title).", "已删除「\(action.title)」的快捷键。"))
            return
        }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= CarbonModifiers.control }
        if flags.contains(.option) { modifiers |= CarbonModifiers.option }
        if flags.contains(.shift) { modifiers |= CarbonModifiers.shift }
        if flags.contains(.command) { modifiers |= CarbonModifiers.command }
        switch ShortcutStore.problem(keyCode: keyCode, modifiers: modifiers, for: action, in: ShortcutStore.bindings()) {
        case .needsModifier:
            showProblem(L("Use at least one of ⌃ ⌥ ⌘ (or a function key).", "至少要带 ⌃ ⌥ ⌘ 中的一个（功能键除外）。"))
        case .reservedForLayouts:
            showProblem(L("⌃⌥⌘ with a digit restores saved layouts.", "⌃⌥⌘ 加数字用于恢复保存的布局。"))
        case let .usedBy(other):
            showProblem(L("Already used by \(other.title).", "已被「\(other.title)」使用。"))
        case nil:
            ShortcutStore.set(keyCode: keyCode, modifiers: modifiers, for: action)
            finishRecording(message: L("\(action.title): \(action.shortcutDescription)", "\(action.title)：\(action.shortcutDescription)"))
        }
    }

    /// Keeps recording, so the user can simply try another combination.
    private func showProblem(_ text: String) {
        shortcutMessage.stringValue = text
        shortcutMessage.textColor = .systemRed
    }

    private func finishRecording(message: String) {
        stopRecording()
        shortcutMessage.stringValue = message
        shortcutMessage.textColor = .secondaryLabelColor
        model.shortcutsDidChange()
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let action = recording {
            shortcutButtons[action]?.title = action.shortcutDescription
            recording = nil
            model.endShortcutRecording()
        }
    }

    @objc private func resetShortcuts() {
        stopRecording()
        ShortcutStore.resetAll()
        shortcutMessage.stringValue = L("Default shortcuts restored.", "已恢复默认快捷键。")
        shortcutMessage.textColor = .secondaryLabelColor
        model.shortcutsDidChange()
    }

    // MARK: - Actions

    @objc private func requestAccessibility() {
        model.requestAccessibilityAccess()
        refresh()
    }

    @objc private func toggleLogin() {
        model.loginItems.setEnabled(loginToggle.state == .on)
        refresh()
    }

    @objc private func toggleUpdates() {
        model.updates.automaticChecks = updatesToggle.state == .on
    }

    @objc private func checkForUpdates() {
        model.checkForUpdatesNow()
    }

    @objc private func languageChanged() {
        guard let raw = languagePopup.selectedItem?.representedObject as? String, let language = AppLanguage(rawValue: raw) else { return }
        model.setLanguage(language)
    }

    @objc private func openAppleIntelligence() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    @objc private func openProfile() {
        model.showProfile()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
        model.settingsDidClose()
    }
}

/// Lays out from the top, so a scroll view shows the beginning of its content first.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
