import Carbon.HIToolbox
import Foundation
import LightShotCore
import os

@MainActor
final class HotkeyService {
    /// The result of asking Carbon to register a chord. Split behind a closure
    /// so the committed harness can force a registration failure without
    /// depending on which chords the current system rejects.
    typealias Registrar = (Hotkey, EventHotKeyID) -> (status: OSStatus, ref: EventHotKeyRef?)
    typealias Unregistrar = (EventHotKeyRef) -> Void

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let handler: @MainActor () -> Void
    private let registrar: Registrar
    private let unregistrar: Unregistrar
    private var eventHandlerInstalled = false
    private let logger = Logger(subsystem: "local.lightshot.app", category: "Hotkey")

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        self.registrar = Self.registerWithCarbon
        self.unregistrar = Self.unregisterWithCarbon
        installEventHandler()
    }

    /// Test seam: lets the harness inject a failing registrar and, optionally,
    /// pretend the Carbon event handler did not install.
    init(
        handler: @escaping @MainActor () -> Void,
        registrar: @escaping Registrar,
        unregistrar: @escaping Unregistrar,
        eventHandlerInstallSucceeded: Bool? = nil
    ) {
        self.handler = handler
        self.registrar = registrar
        self.unregistrar = unregistrar
        installEventHandler()
        if let eventHandlerInstallSucceeded {
            self.eventHandlerInstalled = eventHandlerInstallSucceeded
        }
    }

    /// True while a chord is registered. Used by the harness to verify that a
    /// failed registration leaves no stale reference behind.
    var isRegistered: Bool {
        hotKeyRef != nil
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
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
            &handlerRef
        )
        eventHandlerRef = handlerRef
        eventHandlerInstalled = status == noErr && handlerRef != nil
        if !eventHandlerInstalled {
            logger.error(
                "InstallEventHandler failed: OSStatus \(status, privacy: .public)"
            )
        }
    }

    /// Registers `hotkey`, replacing any previous registration.
    ///
    /// Returns false when the Carbon event handler is missing or the chord was
    /// rejected. On failure `hotKeyRef` is left nil, so the caller can decide
    /// whether to restore the previous chord.
    @discardableResult
    func register(_ hotkey: Hotkey) -> Bool {
        guard eventHandlerInstalled else {
            logger.error(
                "Cannot register \(hotkey.displayString, privacy: .public): the event handler is not installed"
            )
            return false
        }
        unregister()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C534854), id: 1)
        let (status, ref) = registrar(hotkey, hotKeyID)
        guard status == noErr, let ref else {
            if let ref {
                // A registrar that reports failure but still hands back a
                // reference must not leak it.
                unregistrar(ref)
            }
            hotKeyRef = nil
            logger.error(
                "RegisterEventHotKey failed for \(hotkey.displayString, privacy: .public): OSStatus \(status, privacy: .public)"
            )
            return false
        }
        hotKeyRef = ref
        logger.info("Registered global hotkey \(hotkey.displayString, privacy: .public)")
        return true
    }

    func unregister() {
        if let hotKeyRef {
            unregistrar(hotKeyRef)
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
        eventHandlerInstalled = false
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private static func registerWithCarbon(
        _ hotkey: Hotkey,
        _ hotKeyID: EventHotKeyID
    ) -> (status: OSStatus, ref: EventHotKeyRef?) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers.rawValue,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        return (status, ref)
    }

    private static func unregisterWithCarbon(_ ref: EventHotKeyRef) {
        UnregisterEventHotKey(ref)
    }
}
