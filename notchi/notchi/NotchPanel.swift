import AppKit
import Carbon.HIToolbox

/// A borderless, transparent panel positioned at the MacBook notch area
final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        level = .mainMenu + 3
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        isOpaque = false
        backgroundColor = .clear
        acceptsMouseMovedEvents = true
        hasShadow = false
        isMovable = false
        isExcludedFromWindowsMenu = true

        // Hit testing is handled by NotchHitTestView (the content view wrapper)
        // which selectively passes through events based on notch/panel rect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func miniaturize(_ sender: Any?) {}

    override func performMiniaturize(_ sender: Any?) {}

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            NotificationCenter.default.post(name: .notchiShouldCollapse, object: nil)
            return
        }

        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty,
           let character = event.charactersIgnoringModifiers?.first,
           let optionNumber = Int(String(character)),
           optionNumber > 0 {
            NotificationCenter.default.post(
                name: .notchiQuestionOptionShortcut,
                object: optionNumber
            )
            return
        }

        super.keyDown(with: event)
    }

    nonisolated static func isMiniaturizeShortcut(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_ANSI_M) else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return modifiers == [.command] || modifiers == [.command, .option]
    }
}
