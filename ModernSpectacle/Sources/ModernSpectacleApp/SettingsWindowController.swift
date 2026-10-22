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
    private let loginError = NSTextField(wrappingLabelWithString: "")
    private let keyStatus = NSTextField(labelWithString: "")
    private let keyCheck = NSTextField(wrappingLabelWithString: "")
    private let secureKeyField = NSSecureTextField()
    private let plainKeyField = NSTextField()
    private let showKeyToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let saveKeyButton = NSButton(title: "", target: nil, action: nil)
    private let testKeyButton = NSButton(title: "", target: nil, action: nil)
    private let removeKeyButton = NSButton(title: "", target: nil, action: nil)
    private var keyDraft: String {
        showKeyToggle.state == .on ? plainKeyField.stringValue : secureKeyField.stringValue
    }
    private let arrangeStatus = NSTextField(wrappingLabelWithString: "")

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
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

    /// Lays the window out again with the current language.
    func rebuild() {
        window?.title = L("Modern Spectacle Settings", "Modern Spectacle 设置")
        accessibilityButton.title = L("Open Accessibility Prompt", "打开辅助功能授权")
        loginToggle.title = L("Launch at Login", "登录时启动")
        updatesToggle.title = L("Check for updates automatically (once a day)", "自动检查更新（每天一次）")
        showKeyToggle.title = L("Show", "显示")
        saveKeyButton.title = L("Save", "保存")
        testKeyButton.title = L("Test", "测试")
        removeKeyButton.title = L("Remove", "删除")
        for field in [secureKeyField, plainKeyField] as [NSTextField] {
            field.placeholderString = L("Paste key (starts with sk-ant-), then Save", "粘贴 Key（以 sk-ant- 开头），然后保存")
        }
        languagePopup.removeAllItems()
        for language in AppLanguage.allCases {
            languagePopup.addItem(withTitle: language.title)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: Localization.language) ?? 0)
        window?.contentView = buildContent()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        let trusted = model.accessibilityTrusted
        accessibilityStatus.stringValue = trusted ? L("Granted", "已授权") : L("Required", "需要授权")
        accessibilityStatus.textColor = trusted ? .secondaryLabelColor : .systemRed
        accessibilityButton.isEnabled = !trusted

        loginToggle.state = model.loginItems.isEnabled ? .on : .off
        loginError.stringValue = model.loginItems.lastError ?? ""
        loginError.isHidden = model.loginItems.lastError == nil

        keyStatus.stringValue = model.hasAPIKey ? L("Stored in Keychain", "已存入钥匙串") : L("Not set", "未设置")
        keyStatus.textColor = model.hasAPIKey ? .secondaryLabelColor : .systemRed
        keyCheck.stringValue = model.apiKeyStatus
        let ok = model.apiKeyValid
        keyCheck.textColor = ok ? .systemGreen : (model.hasAPIKey ? .systemRed : .secondaryLabelColor)
        removeKeyButton.isEnabled = model.hasAPIKey
        testKeyButton.isEnabled = model.hasAPIKey
        saveKeyButton.isEnabled = !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty

        arrangeStatus.stringValue = model.arrangeStatus
        updatesToggle.state = model.updates.automaticChecks ? .on : .off
    }

    /// Targets, observers and fixed sizes: set once, not on every rebuild.
    private func configureControls() {
        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibility)
        loginToggle.target = self
        loginToggle.action = #selector(toggleLogin)
        updatesToggle.target = self
        updatesToggle.action = #selector(toggleUpdates)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        for field in [secureKeyField, plainKeyField] as [NSTextField] {
            field.target = self
            field.action = #selector(saveKey)
            // One scrolling line: a 100+ character key must not wrap and grow the window.
            field.usesSingleLineMode = true
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            field.lineBreakMode = .byClipping
            field.widthAnchor.constraint(equalToConstant: 340).isActive = true
            NotificationCenter.default.addObserver(self, selector: #selector(keyFieldChanged), name: NSControl.textDidChangeNotification, object: field)
        }
        plainKeyField.isHidden = true
        showKeyToggle.target = self
        showKeyToggle.action = #selector(toggleShowKey)
        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveKey)
        testKeyButton.target = self
        testKeyButton.action = #selector(testKey)
        removeKeyButton.target = self
        removeKeyButton.action = #selector(removeKey)
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
        let checkNow = NSButton(title: L("Check Now", "立即检查"), target: self, action: #selector(checkForUpdates))
        let updatesRow = NSStackView(views: [updatesToggle, checkNow])
        updatesRow.orientation = .horizontal
        stack.addArrangedSubview(updatesRow)
        let version = NSTextField(labelWithString: L("Version \(UpdateChecker.currentVersion)", "版本 \(UpdateChecker.currentVersion)"))
        version.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        version.textColor = .secondaryLabelColor
        stack.addArrangedSubview(version)

        stack.addArrangedSubview(header(L("Smart Arrange", "智能排列")))
        stack.addArrangedSubview(row(L("Claude API key (claude-haiku-5-5)", "Claude API Key（claude-haiku-5-5）"), trailing: keyStatus))
        let keyRow = NSStackView(views: [secureKeyField, plainKeyField, showKeyToggle, saveKeyButton])
        keyRow.orientation = .horizontal
        stack.addArrangedSubview(keyRow)
        let profileButton = NSButton(title: L("Layout Profile…", "布局档案…"), target: self, action: #selector(openProfile))
        let keyButtons = NSStackView(views: [testKeyButton, removeKeyButton, profileButton])
        keyButtons.orientation = .horizontal
        stack.addArrangedSubview(keyButtons)
        keyCheck.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keyCheck.preferredMaxLayoutWidth = 460
        stack.addArrangedSubview(keyCheck)
        let hint = NSTextField(wrappingLabelWithString: L(
            "Smart Arrange and the tiling suggestions need a key; the manual shortcuts work without one. Plans are pre-computed when the window set changes, so ⌃⌥⌘A applies instantly. Saved layouts (⌃⌥⌘1…9) work without a key.",
            "智能排列和平铺建议需要 Key，手动快捷键不需要。窗口变化时会提前算好方案，所以按 ⌃⌥⌘A 立即生效。保存的布局（⌃⌥⌘1…9）不需要 Key。"
        ))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        stack.addArrangedSubview(row(L("Last arrangement", "上次排列"), trailing: arrangeStatus))
        arrangeStatus.textColor = .secondaryLabelColor
        arrangeStatus.maximumNumberOfLines = 3
        arrangeStatus.preferredMaxLayoutWidth = 320

        stack.addArrangedSubview(header(L("Shortcuts", "快捷键")))
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = 24
        grid.rowSpacing = 4
        for action in WindowAction.allCases {
            let shortcut = NSTextField(labelWithString: action.defaultShortcutDescription)
            shortcut.textColor = .secondaryLabelColor
            grid.addRow(with: [NSTextField(labelWithString: action.title), shortcut])
        }
        let presetShortcut = NSTextField(labelWithString: "⌃⌥⌘1…9")
        presetShortcut.textColor = .secondaryLabelColor
        grid.addRow(with: [NSTextField(labelWithString: L("Restore Saved Layout", "恢复保存的布局")), presetShortcut])
        stack.addArrangedSubview(grid)

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

    private func row(_ title: String, trailing: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        let row = NSStackView(views: [label, trailing])
        row.orientation = .horizontal
        row.spacing = 12
        return row
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

    @objc private func keyFieldChanged() {
        saveKeyButton.isEnabled = !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @objc private func toggleShowKey() {
        let showing = showKeyToggle.state == .on
        if showing {
            plainKeyField.stringValue = secureKeyField.stringValue
        } else {
            secureKeyField.stringValue = plainKeyField.stringValue
        }
        plainKeyField.isHidden = !showing
        secureKeyField.isHidden = showing
        window?.makeFirstResponder(showing ? plainKeyField : secureKeyField)
    }

    @objc private func saveKey() {
        let key = keyDraft
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.saveAPIKey(key)
        secureKeyField.stringValue = ""
        plainKeyField.stringValue = ""
        refresh()
    }

    @objc private func openProfile() {
        model.showProfile()
    }

    @objc private func testKey() {
        model.checkAPIKey()
        refresh()
    }

    @objc private func removeKey() {
        model.saveAPIKey("")
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        model.settingsDidClose()
    }
}
