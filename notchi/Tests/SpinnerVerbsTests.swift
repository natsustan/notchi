import XCTest
@testable import notchi

final class SpinnerVerbsTests: XCTestCase {
    func testSpinnerVerbsIncludeExpandedReferenceListAndClanking() {
        XCTAssertGreaterThanOrEqual(SpinnerVerbs.all.count, 100)
        XCTAssertTrue(SpinnerVerbs.all.contains("Clanking"))
        XCTAssertFalse(SpinnerVerbs.all.contains("Clauding"))
        XCTAssertFalse(SpinnerVerbs.all.contains("Codexing"))
    }

    func testProviderVerbsAreProviderSpecific() {
        XCTAssertEqual(SpinnerVerbs.providerVerb(for: .claude), "Clauding")
        XCTAssertEqual(SpinnerVerbs.providerVerb(for: .codex), "Codexing")
    }

    func testNextWorkingVerbDoesNotRepeatCurrentVerbWhenAlternativesExist() {
        let next = SpinnerVerbs.nextWorkingVerb(after: "Clanking")

        XCTAssertNotEqual(next, "Clanking")
        XCTAssertTrue(SpinnerVerbs.all.contains(next))
    }

    func testNextWorkingVerbFallsBackToSharedPoolAfterProviderWord() {
        let nextClaude = SpinnerVerbs.nextWorkingVerb(after: "Clauding")
        XCTAssertNotEqual(nextClaude, "Clauding")
        XCTAssertTrue(SpinnerVerbs.all.contains(nextClaude))

        let nextCodex = SpinnerVerbs.nextWorkingVerb(after: "Codexing")
        XCTAssertNotEqual(nextCodex, "Codexing")
        XCTAssertTrue(SpinnerVerbs.all.contains(nextCodex))
    }
}
