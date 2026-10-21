import Foundation
import ModernSpectacleCore
import ModernSpectacleServices

@MainActor
final class AppModel: ObservableObject {
    @Published var accessibilityTrusted: Bool = AccessibilityPermission.isTrusted
    @Published var shortcutsEnabled = true

    let loginItems = LoginItemController()
    private let hotKeys = HotKeyCenter()
    private let windowController = WindowController()
    private var permissionRefreshTimer: Timer?

    init() {
        hotKeys.registerDefaultShortcuts { [weak self] action in
            self?.perform(action)
        }

        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissions()
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            permissionRefreshTimer?.invalidate()
        }
    }

    func refreshPermissions() {
        accessibilityTrusted = AccessibilityPermission.isTrusted
    }

    func requestAccessibilityAccess() {
        AccessibilityPermission.requestTrustPrompt()
        refreshPermissions()
    }

    func perform(_ action: WindowAction) {
        guard shortcutsEnabled || action.isHistoryAction else {
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
    }

}
