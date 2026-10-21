import AppKit
import ModernSpectacleCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        model.refreshPermissions()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
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
            menu.addItem(menuItem("Grant Accessibility Access") { [weak self] in
                self?.model.requestAccessibilityAccess()
                self?.rebuildMenu()
            })
            menu.addItem(.separator())
        }

        menu.addItem(menuItem("About Modern Spectacle") {
            NSApp.orderFrontStandardAboutPanel(nil)
        })

        menu.addItem(menuItem("Settings...") { [weak self] in
            self?.showSettings()
        })

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

        let shortcutsItem = menuItem(model.shortcutsEnabled ? "Disable Shortcuts" : "Enable Shortcuts") { [weak self] in
            guard let self else { return }
            model.setShortcutsEnabled(!model.shortcutsEnabled)
            rebuildMenu()
        }
        shortcutsItem.state = model.shortcutsEnabled ? .off : .on
        menu.addItem(shortcutsItem)

        menu.addItem(.separator())

        menu.addItem(menuItem("Quit Modern Spectacle") {
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
            item.toolTip = action.defaultShortcutDescription
            item.isEnabled = model.shortcutsEnabled || action.isHistoryAction
            menu.addItem(item)
        }
    }

    private func menuItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        CallbackMenuItem(title: title, callback: action)
    }

    private func rebuildMenu() {
        model.refreshPermissions()
        statusItem?.menu = buildMenu()
    }

    private func showSettings() {
        if settingsWindow == nil {
            let contentView = SettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 560)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Modern Spectacle Settings"
            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
    var keyEquivalent: String {
        switch self {
        case .center: "c"
        case .maximize: "f"
        case .leftHalf, .upperLeft, .lowerLeft, .previousDisplay, .previousThird, .smaller:
            "\u{F702}"
        case .rightHalf, .upperRight, .lowerRight, .nextDisplay, .nextThird, .larger:
            "\u{F703}"
        case .topHalf:
            "\u{F700}"
        case .bottomHalf:
            "\u{F701}"
        case .undo, .redo:
            "z"
        }
    }

    var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        switch self {
        case .center, .maximize, .leftHalf, .rightHalf, .topHalf, .bottomHalf, .undo:
            [.option, .command]
        case .upperLeft, .upperRight:
            [.control, .command]
        case .lowerLeft, .lowerRight:
            [.control, .shift, .command]
        case .nextDisplay, .previousDisplay:
            [.control, .option, .command]
        case .nextThird, .previousThird:
            [.control, .option]
        case .larger, .smaller:
            [.control, .option, .shift]
        case .redo:
            [.option, .shift, .command]
        }
    }
}
