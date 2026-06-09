import AppKit
import Carbon.HIToolbox
import XCTest
@testable import notchi

final class NotchPanelTests: XCTestCase {
    func testMiniaturizeShortcutMatchesCommandMAndCommandOptionM() throws {
        XCTAssertTrue(NotchPanel.isMiniaturizeShortcut(try keyEvent(keyCode: kVK_ANSI_M, modifiers: [.command])))
        XCTAssertTrue(NotchPanel.isMiniaturizeShortcut(try keyEvent(keyCode: kVK_ANSI_M, modifiers: [.command, .option])))
    }

    func testMiniaturizeShortcutIgnoresOtherKeyCombinations() throws {
        XCTAssertFalse(NotchPanel.isMiniaturizeShortcut(try keyEvent(keyCode: kVK_ANSI_M, modifiers: [])))
        XCTAssertFalse(NotchPanel.isMiniaturizeShortcut(try keyEvent(keyCode: kVK_ANSI_M, modifiers: [.option])))
        XCTAssertFalse(NotchPanel.isMiniaturizeShortcut(try keyEvent(keyCode: kVK_ANSI_M, modifiers: [.command, .shift])))
        XCTAssertFalse(NotchPanel.isMiniaturizeShortcut(try keyEvent(keyCode: kVK_ANSI_N, modifiers: [.command, .option])))
    }

    private func keyEvent(keyCode: Int, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
    }
}
