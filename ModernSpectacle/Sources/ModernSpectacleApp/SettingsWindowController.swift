import AppKit
import ModernSpectacleCore
import ModernSpectacleServices

/// Plain AppKit settings window. Built on demand and released on close so it costs nothing while hidden.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let accessibilityButton = NSButton(title: "Open Accessibility Prompt", target: nil, action: nil)
    private let loginToggle = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private let loginError = NSTextField(wrappingLabelWithString: "")
    private let keyStatus = NSTextField(labelWithString: "")
    private let keyCheck = NSTextField(wrappingLabelWithString: "")
    private let secureKeyField = NSSecureTextField()
    private let plainKeyField = NSTextField()
    private let showKeyToggle = NSButton(checkboxWithTitle: "Show", target: nil, action: nil)
    private let saveKeyButton = NSButton(title: "Save", target: nil, action: nil)
    private let testKeyButton = NSButton(title: "Test", target: nil, action: nil)
    private let removeKeyButton = NSButton(title: "Remove", target: nil, action: nil)
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
        window.title = "Modern Spectacle Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        window.center()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        let trusted = model.accessibilityTrusted
        accessibilityStatus.stringValue = trusted ? "Granted" : "Required"
        accessibilityStatus.textColor = trusted ? .secondaryLabelColor : .systemRed
        accessibilityButton.isEnabled = !trusted

        loginToggle.state = model.loginItems.isEnabled ? .on : .off
        loginError.stringValue = model.loginItems.lastError ?? ""
        loginError.isHidden = model.loginItems.lastError == nil

        keyStatus.stringValue = model.hasAPIKey ? "Stored in Keychain" : "Not set"
        keyStatus.textColor = model.hasAPIKey ? .secondaryLabelColor : .systemRed
        keyCheck.stringValue = model.apiKeyStatus
        let ok = model.apiKeyStatus.hasPrefix("Valid")
        keyCheck.textColor = ok ? .systemGreen : (model.hasAPIKey ? .systemRed : .secondaryLabelColor)
        removeKeyButton.isEnabled = model.hasAPIKey
        testKeyButton.isEnabled = model.hasAPIKey
        saveKeyButton.isEnabled = !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty

        arrangeStatus.stringValue = model.arrangeStatus
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        stack.addArrangedSubview(header("Permissions"))
        stack.addArrangedSubview(row("Accessibility", trailing: accessibilityStatus))
        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibility)
        stack.addArrangedSubview(accessibilityButton)

        stack.addArrangedSubview(header("Startup"))
        loginToggle.target = self
        loginToggle.action = #selector(toggleLogin)
        stack.addArrangedSubview(loginToggle)
        loginError.textColor = .systemRed
        loginError.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(loginError)

        stack.addArrangedSubview(header("Smart Arrange"))
        stack.addArrangedSubview(row("Claude API key (claude-haiku-5-5)", trailing: keyStatus))
        for field in [secureKeyField, plainKeyField] as [NSTextField] {
            field.placeholderString = "Paste key (starts with sk-ant-), then Save"
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
        let keyRow = NSStackView(views: [secureKeyField, plainKeyField, showKeyToggle, saveKeyButton])
        keyRow.orientation = .horizontal
        stack.addArrangedSubview(keyRow)
        let profileButton = NSButton(title: "Layout Profile…", target: self, action: #selector(openProfile))
        let keyButtons = NSStackView(views: [testKeyButton, removeKeyButton, profileButton])
        keyButtons.orientation = .horizontal
        stack.addArrangedSubview(keyButtons)
        keyCheck.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keyCheck.preferredMaxLayoutWidth = 460
        stack.addArrangedSubview(keyCheck)
        let hint = NSTextField(wrappingLabelWithString: "Smart Arrange and the tiling suggestions need a key; the manual shortcuts work without one. Plans are pre-computed when the window set changes, so ⌃⌥⌘A applies instantly.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        stack.addArrangedSubview(row("Last arrangement", trailing: arrangeStatus))
        arrangeStatus.textColor = .secondaryLabelColor
        arrangeStatus.maximumNumberOfLines = 3
        arrangeStatus.preferredMaxLayoutWidth = 320

        stack.addArrangedSubview(header("Shortcuts"))
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.columnSpacing = 24
        grid.rowSpacing = 4
        for action in WindowAction.allCases {
            let shortcut = NSTextField(labelWithString: action.defaultShortcutDescription)
            shortcut.textColor = .secondaryLabelColor
            grid.addRow(with: [NSTextField(labelWithString: action.title), shortcut])
        }
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
