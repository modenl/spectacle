import Carbon.HIToolbox
import Foundation
import ModernSpectacleCore

@MainActor
public final class HotKeyCenter {
    public typealias ActionHandler = @MainActor (WindowAction) -> Void

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var actionsByIdentifier: [UInt32: WindowAction] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var nextIdentifier: UInt32 = 0
    private var handler: ActionHandler?

    public init() {
        installEventHandler()
    }

    deinit {
        MainActor.assumeIsolated {
            unregisterAll()
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
            }
        }
    }

    /// Registers the shortcuts in effect (defaults plus the user's changes); call again after they change.
    public func registerShortcuts(handler: @escaping ActionHandler) {
        self.handler = handler
        unregisterAll()

        for binding in ShortcutStore.bindings() {
            register(binding)
        }
    }

    public func unregisterAll() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        actionsByIdentifier.removeAll()
    }

    private func register(_ binding: ShortcutBinding) {
        if let identifier = register(keyCode: binding.keyCode, modifiers: binding.carbonModifiers) {
            actionsByIdentifier[identifier] = binding.action
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32) -> UInt32? {
        nextIdentifier += 1
        var hotKeyRef: EventHotKeyRef?
        let identifier = nextIdentifier
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            return nil
        }

        hotKeyRefs[identifier] = hotKeyRef
        return identifier
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleEvent,
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
    }

    private nonisolated static let handleEvent: EventHandlerUPP = { _, event, userData in
        guard
            let event,
            let userData
        else {
            return noErr
        }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            return status
        }

        let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
            center.invoke(identifier: hotKeyID.id)
        }
        return noErr
    }

    private func invoke(identifier: UInt32) {
        guard let action = actionsByIdentifier[identifier] else {
            return
        }
        handler?(action)
    }

    private static let signature = OSType(
        UInt32(UInt8(ascii: "M")) << 24 |
            UInt32(UInt8(ascii: "S")) << 16 |
            UInt32(UInt8(ascii: "P")) << 8 |
            UInt32(UInt8(ascii: "C"))
    )
}
