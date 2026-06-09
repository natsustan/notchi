import Carbon.HIToolbox
import Foundation
import os.log

private let globalShortcutLogger = Logger(subsystem: "com.ruban.notchi", category: "GlobalShortcutService")

@MainActor
final class GlobalShortcutService {
    static let shared = GlobalShortcutService()

    static var togglePanelShortcut: GlobalShortcut { AppSettings.panelToggleShortcut }
    nonisolated static let togglePanelHotKeyID = EventHotKeyID(signature: 0x4E544348, id: 1)

    private let togglePanel: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var settingsObserver: NSObjectProtocol?
    private var lastAttemptedShortcut: GlobalShortcut?
    private var isShortcutSuspended = false

    init(togglePanel: @escaping @MainActor () -> Void = { NotchPanelManager.shared.toggle() }) {
        self.togglePanel = togglePanel
    }

    func start() {
        guard eventHandlerRef == nil else {
            reloadShortcutIfNeeded()
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            eventHandlerRef = nil
            globalShortcutLogger.error("Failed to install global shortcut handler: \(handlerStatus)")
            return
        }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak service = self] in
                service?.reloadShortcutIfNeeded()
            }
        }

        registerCurrentShortcut()
    }

    func stop() {
        unregisterCurrentShortcut()
        lastAttemptedShortcut = nil
        isShortcutSuspended = false

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
    }

    func suspendShortcut() {
        isShortcutSuspended = true
        unregisterCurrentShortcut()
    }

    func reloadShortcut() {
        guard eventHandlerRef != nil else { return }
        isShortcutSuspended = false
        unregisterCurrentShortcut()
        registerCurrentShortcut()
    }

    private func reloadShortcutIfNeeded() {
        guard eventHandlerRef != nil, !isShortcutSuspended else { return }
        let shortcut = Self.togglePanelShortcut
        guard shortcut != lastAttemptedShortcut else { return }
        reloadShortcut()
    }

    private func registerCurrentShortcut() {
        let shortcut = Self.togglePanelShortcut
        lastAttemptedShortcut = shortcut
        var registeredHotKeyRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            Self.togglePanelHotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKeyRef
        )
        guard registerStatus == noErr else {
            globalShortcutLogger.error("Failed to register global shortcut: \(registerStatus)")
            return
        }

        hotKeyRef = registeredHotKeyRef
    }

    private func unregisterCurrentShortcut() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    func handleHotKey(signature: OSType, id: UInt32) {
        guard Self.isTogglePanelHotKey(signature: signature, id: id) else { return }
        togglePanel()
    }

    func handleHotKey(_ hotKeyID: EventHotKeyID) {
        handleHotKey(signature: hotKeyID.signature, id: hotKeyID.id)
    }

    nonisolated static func isTogglePanelHotKey(signature: OSType, id: UInt32) -> Bool {
        signature == togglePanelHotKeyID.signature &&
            id == togglePanelHotKeyID.id
    }

    private nonisolated static let hotKeyEventHandler: EventHandlerUPP = { _, eventRef, userData in
        guard let eventRef, let userData else { return noErr }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return status }

        let service = Unmanaged<GlobalShortcutService>.fromOpaque(userData).takeUnretainedValue()
        let capturedHotKeyID = hotKeyID
        Task { @MainActor in
            service.handleHotKey(capturedHotKeyID)
        }

        return noErr
    }
}
