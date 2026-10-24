import Carbon.HIToolbox
import Foundation
import SnipboCore
import os

@MainActor
final class HotkeyService {
    /// The result of asking Carbon to register a chord. Split behind a closure
    /// so the committed harness can force a registration failure without
    /// depending on which chords the current system rejects.
    typealias Registrar = (Hotkey, EventHotKeyID) -> (status: OSStatus, ref: EventHotKeyRef?)
    typealias Unregistrar = (EventHotKeyRef) -> Void

    /// Routes a fired chord to its mode. The single-hotkey initializer wraps a
    /// no-argument handler under id 1.
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private let registrar: Registrar
    private let unregistrar: Unregistrar
    private var eventHandlerInstalled = false
    private let logger = Logger(subsystem: "local.snipbo.app", category: "Hotkey")

    init(handler: @escaping @MainActor () -> Void) {
        self.registrar = Self.registerWithCarbon
        self.unregistrar = Self.unregisterWithCarbon
        installEventHandler()
        handlers[1] = handler
    }

    /// Per-mode handler keyed by the same id passed to `register(_:id:)`.
    init(handlers: [UInt32: @MainActor () -> Void]) {
        self.registrar = Self.registerWithCarbon
        self.unregistrar = Self.unregisterWithCarbon
        installEventHandler()
        self.handlers = handlers
    }

    /// Test seam: lets the harness inject a failing registrar and, optionally,
    /// pretend the Carbon event handler did not install.
    init(
        handler: @escaping @MainActor () -> Void,
        registrar: @escaping Registrar,
        unregistrar: @escaping Unregistrar,
        eventHandlerInstallSucceeded: Bool? = nil
    ) {
        self.registrar = registrar
        self.unregistrar = unregistrar
        installEventHandler()
        self.handlers[1] = handler
        if let eventHandlerInstallSucceeded {
            self.eventHandlerInstalled = eventHandlerInstallSucceeded
        }
    }

    /// True while any chord is registered. Used by the harness to verify that
    /// a failed registration leaves no stale reference behind.
    var isRegistered: Bool {
        !registrations.isEmpty
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated {
                    service.dispatch(hotKeyID.id)
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

    private func dispatch(_ id: UInt32) {
        handlers[id]?()
    }

    /// Registers `hotkey` under `id`, replacing any previous registration for
    /// that id.
    ///
    /// Returns false when the Carbon event handler is missing or the chord was
    /// rejected. On failure no reference is kept for `id`, so the caller can
    /// decide whether to restore the previous chord.
    @discardableResult
    func register(_ hotkey: Hotkey, id: UInt32 = 1) -> Bool {
        guard eventHandlerInstalled else {
            logger.error(
                "Cannot register \(hotkey.displayString, privacy: .public): the event handler is not installed"
            )
            return false
        }
        unregister(id: id)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C534854), id: id)
        let (status, ref) = registrar(hotkey, hotKeyID)
        guard status == noErr, let ref else {
            if let ref {
                // A registrar that reports failure but still hands back a
                // reference must not leak it.
                unregistrar(ref)
            }
            registrations[id] = nil
            logger.error(
                "RegisterEventHotKey failed for \(hotkey.displayString, privacy: .public): OSStatus \(status, privacy: .public)"
            )
            return false
        }
        registrations[id] = ref
        logger.info("Registered global hotkey \(hotkey.displayString, privacy: .public)")
        return true
    }

    func unregister(id: UInt32 = 1) {
        if let ref = registrations.removeValue(forKey: id) {
            unregistrar(ref)
        }
    }

    /// Tears down everything installed in `init`: the hotkey registrations and
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
        registrations.removeAll()
        handlers.removeAll()
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
