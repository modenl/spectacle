import AppKit
import ModernSpectacleCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        installStatusItem()
        model.refreshPermissions()
        model.onMenuChange = { [weak self] in self?.rebuildMenu() }
        model.arranger.onPresetsChange = { [weak self] in self?.rebuildMenu() }
        model.onLanguageChange = { [weak self] in self?.rebuildMenu() }
        model.onBusyChange = { [weak self] busy in
            guard let button = self?.statusItem?.button else { return }
            button.image = NSImage(
                systemSymbolName: busy ? "sparkles" : "rectangle.3.group",
                accessibilityDescription: busy ? "Arranging" : "Modern Spectacle"
            )
            button.image?.isTemplate = true
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    /// An accessory app has no visible menu bar, but text fields still need an Edit menu for ⌘V / ⌘C / ⌘A to work.
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: L("Edit", "编辑"))
        edit.addItem(withTitle: L("Undo", "撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Redo", "重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut", "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy", "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste", "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All", "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Modern Spectacle")
            button.image?.isTemplate = true
            button.toolTip = "Modern Spectacle"
        }

        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "Modern Spectacle")
        menu.autoenablesItems = false

        if !model.accessibilityTrusted {
            menu.addItem(menuItem(L("Grant Accessibility Access", "授予辅助功能权限")) { [weak self] in
                self?.model.requestAccessibilityAccess()
                self?.rebuildMenu()
            })
            menu.addItem(.separator())
        }

        menu.addItem(menuItem(L("About Modern Spectacle", "关于 Modern Spectacle")) {
            NSApp.orderFrontStandardAboutPanel(nil)
        })

        menu.addItem(menuItem(L("Check for Updates...", "检查更新...")) { [weak self] in
            self?.model.updater.checkNow()
        })

        menu.addItem(menuItem(L("Modern Spectacle in the Store", "在商店中查看 Modern Spectacle")) {
            NSWorkspace.shared.open(Updater.storePageURL)
        })

        menu.addItem(menuItem(L("Settings...", "设置...")) { [weak self] in
            self?.showSettings()
        })

        menu.addItem(menuItem(L("Layout Profile...", "布局档案...")) { [weak self] in
            self?.model.showProfile()
        })

        menu.addItem(.separator())

        addActionItems([.smartArrange, .promoteFocused], to: menu)
        addPresetItems(to: menu)
        menu.addItem(.separator())
        addActionItems([.center, .maximize], to: menu)
        menu.addItem(.separator())
        addActionItems([.leftHalf, .rightHalf, .topHalf, .bottomHalf], to: menu)
        menu.addItem(.separator())
        addActionItems([.upperLeft, .lowerLeft, .upperRight, .lowerRight], to: menu)
        menu.addItem(.separator())
        addActionItems([.nextDisplay, .previousDisplay, .nextThird, .previousThird], to: menu)
        menu.addItem(.separator())
        addActionItems([.larger, .smaller, .undo, .redo], to: menu)

        menu.addItem(.separator())

        let shortcutsItem = menuItem(model.shortcutsEnabled ? L("Disable Shortcuts", "停用快捷键") : L("Enable Shortcuts", "启用快捷键")) { [weak self] in
            guard let self else { return }
            model.setShortcutsEnabled(!model.shortcutsEnabled)
            rebuildMenu()
        }
        shortcutsItem.state = model.shortcutsEnabled ? .off : .on
        menu.addItem(shortcutsItem)

        menu.addItem(.separator())

        menu.addItem(menuItem(L("Quit Modern Spectacle", "退出 Modern Spectacle")) {
            NSApp.terminate(nil)
        })

        return menu
    }

    private func addActionItems(_ actions: [WindowAction], to menu: NSMenu) {
        for action in actions {
            let item = menuItem(action.title) { [weak self] in
                self?.model.perform(action)
            }
            item.keyEquivalent = action.keyEquivalent
            item.keyEquivalentModifierMask = action.keyEquivalentModifierMask
            item.toolTip = action.shortcutDescription
            item.isEnabled = model.shortcutsEnabled || action.isHistoryAction
            menu.addItem(item)
        }
    }

    private func addPresetItems(to menu: NSMenu) {
        // Always enabled: whether there is a layout to save changes with every arrangement, and the menu is not rebuilt
        // then. Saving with nothing arranged says so in the HUD.
        let save = menuItem(L("Save Layout...", "保存布局...")) { [weak self] in self?.model.promptToSavePreset() }
        save.toolTip = L("Save the current arrangement under a name", "给当前的排列起个名字保存")
        menu.addItem(save)

        let presets = model.presets
        let restore = NSMenuItem(title: L("Restore Layout", "恢复布局"), action: nil, keyEquivalent: "")
        let restoreMenu = NSMenu(title: L("Restore Layout", "恢复布局"))
        let delete = NSMenuItem(title: L("Delete Layout", "删除布局"), action: nil, keyEquivalent: "")
        let deleteMenu = NSMenu(title: L("Delete Layout", "删除布局"))
        for (index, preset) in presets.enumerated() {
            let item = menuItem(preset.name) { [weak self] in self?.model.restorePreset(at: index) }
            item.keyEquivalent = "\(index + 1)"
            item.keyEquivalentModifierMask = [.control, .option, .command]
            item.isEnabled = model.shortcutsEnabled
            restoreMenu.addItem(item)
            deleteMenu.addItem(menuItem(preset.name) { [weak self] in self?.model.deletePreset(named: preset.name) })
        }
        restoreMenu.autoenablesItems = false
        restore.submenu = restoreMenu
        restore.isEnabled = !presets.isEmpty
        menu.addItem(restore)
        delete.submenu = deleteMenu
        delete.isEnabled = !presets.isEmpty
        menu.addItem(delete)
    }

    private func menuItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        CallbackMenuItem(title: title, callback: action)
    }

    private func rebuildMenu() {
        model.refreshPermissions()
        statusItem?.menu = buildMenu()
    }

    private func showSettings() {
        model.showSettings()
    }
}

private final class CallbackMenuItem: NSMenuItem {
    private let callback: () -> Void

    init(title: String, callback: @escaping () -> Void) {
        self.callback = callback
        super.init(title: title, action: #selector(performCallback), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performCallback() {
        callback()
    }
}

private extension WindowAction {
    /// The menu shows the shortcut in effect, which the user may have changed.
    var keyEquivalent: String {
        guard let binding = ShortcutStore.binding(for: self) else { return "" }
        switch binding.keyCode {
        case 123: return "\u{F702}"
        case 124: return "\u{F703}"
        case 126: return "\u{F700}"
        case 125: return "\u{F701}"
        case 36: return "\r"
        case 49: return " "
        default:
            guard let name = KeyNames.name(of: binding.keyCode), name.count == 1 else { return "" }
            return name.lowercased()
        }
    }

    var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        guard let modifiers = ShortcutStore.binding(for: self)?.carbonModifiers else { return [] }
        var mask: NSEvent.ModifierFlags = []
        if modifiers & CarbonModifiers.control != 0 { mask.insert(.control) }
        if modifiers & CarbonModifiers.option != 0 { mask.insert(.option) }
        if modifiers & CarbonModifiers.shift != 0 { mask.insert(.shift) }
        if modifiers & CarbonModifiers.command != 0 { mask.insert(.command) }
        return mask
    }
}
