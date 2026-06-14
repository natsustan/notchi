import XCTest
@testable import notchi

final class NotificationSoundTests: XCTestCase {
    func testBuiltInDisplayOrderKeepsNoneFirstThenSortsSoundsByName() {
        let order = NotificationSound.displayOrder

        XCTAssertEqual(order.first, NotificationSound.none)
        XCTAssertEqual(order.count, NotificationSound.allCases.count)
        XCTAssertEqual(Set(order), Set(NotificationSound.allCases))

        let names = order.dropFirst().map(\.displayName)
        XCTAssertEqual(
            names,
            names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        )
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
