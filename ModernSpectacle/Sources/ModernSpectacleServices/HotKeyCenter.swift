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

    public func registerDefaultShortcuts(handler: @escaping ActionHandler) {
        self.handler = handler
        unregisterAll()

        let bindings = DefaultShortcutBindings.all(
            command: UInt32(cmdKey),
            option: UInt32(optionKey),
            control: UInt32(controlKey),
            shift: UInt32(shiftKey)
        )

        for binding in bindings {
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
        nextIdentifier += 1
        var hotKeyRef: EventHotKeyRef?
        let identifier = nextIdentifier
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)

        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            return
        }

        hotKeyRefs[identifier] = hotKeyRef
        actionsByIdentifier[identifier] = binding.action
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
