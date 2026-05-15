import XCTest
@testable import notchi

final class NotificationSoundTests: XCTestCase {
    func testBuiltInDisplayOrderKeepsNoneFirstThenSortsSoundsByName() {
        XCTAssertEqual(NotificationSound.displayOrder.first, NotificationSound.none)
        XCTAssertEqual(NotificationSound.displayOrder.dropFirst().map(\.displayName), [
            "Basso",
            "Blow",
            "Bottle",
            "Frog",
            "Funk",
            "Glass",
            "Hero",
            "Morse",
            "Ping",
            "Pop",
            "Purr",
            "Sosumi",
            "Submarine",
            "Tink"
        ])
    }

    func testDeletingSelectedCustomSoundFallsBackToDefaultSound() {
        let id = UUID()

        XCTAssertEqual(
            NotificationSoundSelection.custom(id).fallbackIfDeletingCustomSound(id: id),
            .defaultValue
        )
    }

    func testDeletingDifferentCustomSoundLeavesSelectionUnchanged() {
        let selectedID = UUID()
        let deletedID = UUID()
        let selection = NotificationSoundSelection.custom(selectedID)

        XCTAssertEqual(selection.fallbackIfDeletingCustomSound(id: deletedID), selection)
    }
}
