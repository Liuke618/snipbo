import Carbon.HIToolbox
import Foundation
import LightShotCore
import os

@MainActor
final class HotkeyService {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let handler: @MainActor () -> Void
    private let logger = Logger(subsystem: "local.lightshot.app", category: "Hotkey")

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated {
                    service.handler()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    func register(_ hotkey: Hotkey) {
        unregister()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C534854), id: 1)
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers.rawValue,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            logger.info("Registered global hotkey \(hotkey.displayString, privacy: .public)")
        } else {
            logger.error(
                "RegisterEventHotKey failed for \(hotkey.displayString, privacy: .public): OSStatus \(status, privacy: .public)"
            )
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
