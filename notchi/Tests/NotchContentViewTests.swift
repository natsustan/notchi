import XCTest
@testable import notchi

final class NotchContentViewTests: XCTestCase {
    func testSameNonNothingContentsConflict() {
        XCTAssertTrue(NotchSlotContent.conflict(.ring, .ring))
        XCTAssertTrue(NotchSlotContent.conflict(.latest, .latest))
        XCTAssertTrue(NotchSlotContent.conflict(.claude, .claude))
        XCTAssertTrue(NotchSlotContent.conflict(.codex, .codex))
    }

    func testNothingNeverConflicts() {
        XCTAssertFalse(NotchSlotContent.conflict(.nothing, .nothing))
        XCTAssertFalse(NotchSlotContent.conflict(.nothing, .claude))
        XCTAssertFalse(NotchSlotContent.conflict(.latest, .nothing))
    }

    func testLatestSessionConflictsWithAnySprite() {
        XCTAssertTrue(NotchSlotContent.conflict(.latest, .claude))
        XCTAssertTrue(NotchSlotContent.conflict(.codex, .latest))
    }

    func testTwoDistinctProvidersDoNotConflict() {
        XCTAssertFalse(NotchSlotContent.conflict(.claude, .codex))
    }

    func testUsageRingDoesNotConflictWithASprite() {
        XCTAssertFalse(NotchSlotContent.conflict(.ring, .claude))
        XCTAssertFalse(NotchSlotContent.conflict(.ring, .latest))
    }

    func testGrassIslandRendersOnlyForExpandedActivityView() {
        XCTAssertTrue(
            NotchContentView.shouldRenderGrassIsland(
                isExpanded: true,
                showingPanelSettings: false
            )
        )
    }

    func testGrassIslandStaysRenderedDuringCollapseHandoff() {
        XCTAssertTrue(
            NotchContentView.shouldRenderGrassIsland(
                isExpanded: false,
                showingPanelSettings: false,
                keepsGrassIslandRenderedForHandoff: true
            )
        )
    }

    func testGrassIslandDoesNotRenderWhenCollapsedWithoutHandoffOrShowingSettings() {
        XCTAssertFalse(
            NotchContentView.shouldRenderGrassIsland(
                isExpanded: false,
                showingPanelSettings: false
            )
        )
        XCTAssertFalse(
            NotchContentView.shouldRenderGrassIsland(
                isExpanded: true,
                showingPanelSettings: true
            )
        )
    }
}
