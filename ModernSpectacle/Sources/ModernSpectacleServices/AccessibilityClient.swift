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
}

public struct ManagedWindow: Equatable {
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

    public func setFrame(_ frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        guard
            let position = AXValueCreate(.cgPoint, &origin),
            let dimensions = AXValueCreate(.cgSize, &size)
        else {
            return
        }

        // Some apps clamp size during movement, so size is applied before and after position.
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dimensions)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dimensions)
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
}
