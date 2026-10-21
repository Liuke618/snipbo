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

    /// Tears down everything installed in `init`: the hotkey registration and
    /// the Carbon event handler.
    ///
    /// The installed handler holds an unretained pointer to `self`, so it must
    /// not outlive this service. `HotkeyService` is owned for the lifetime of
    /// the application, and `AppDelegate.applicationWillTerminate` calls this
    /// method before the process exits. There is deliberately no `deinit`:
    /// `@MainActor` classes get nonisolated deinitializers under Swift 6, so
    /// the isolated teardown below cannot be expressed there; the explicit
    /// shutdown is the contract for the app-lifetime owner.
    func shutdown() {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }
}
