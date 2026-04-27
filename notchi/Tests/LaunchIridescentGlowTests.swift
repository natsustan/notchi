import XCTest
@testable import notchi

final class LaunchIridescentGlowTests: XCTestCase {
    func testReducedMotionSkipsLaunchGlowDuration() {
        XCTAssertEqual(
            LaunchIridescentGlowTiming.duration(reduceMotion: true),
            0,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            LaunchIridescentGlowTiming.duration(reduceMotion: false),
            0
        )
    }

    func testLaunchGlowFadeOutUsesSingleSmoothCurve() {
        let fadeMidpoint = (
            LaunchIridescentGlowTiming.fadeInDuration
                + LaunchIridescentGlowTiming.holdDuration
                + (LaunchIridescentGlowTiming.fadeOutDuration / 2)
        ) / LaunchIridescentGlowTiming.totalDuration

        XCTAssertEqual(
            LaunchIridescentGlowTiming.opacity(for: fadeMidpoint),
            0.5,
            accuracy: 0.001
        )
    }

    func testOpacityFadesInHoldsThenFadesOut() {
        XCTAssertEqual(
            LaunchIridescentGlowTiming.opacity(for: 0),
            0,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            LaunchIridescentGlowTiming.opacity(for: 0.14),
            0.75
        )
        XCTAssertEqual(
            LaunchIridescentGlowTiming.opacity(for: 0.4),
            LaunchIridescentGlowTiming.opacity(for: 0.68),
            accuracy: 0.001
        )
        XCTAssertEqual(
            LaunchIridescentGlowTiming.opacity(for: 1),
            0,
            accuracy: 0.001
        )
    }

    func testOpacityClampsOutsideExpectedProgressRange() {
        XCTAssertEqual(
            LaunchIridescentGlowTiming.opacity(for: -0.4),
            LaunchIridescentGlowTiming.opacity(for: 0),
            accuracy: 0.001
        )
        XCTAssertEqual(
            LaunchIridescentGlowTiming.opacity(for: 1.4),
            LaunchIridescentGlowTiming.opacity(for: 1),
            accuracy: 0.001
        )
    }

    func testReducedMotionDisablesGradientMotion() {
        XCTAssertEqual(
            LaunchIridescentGlowMotion.shimmerOffset(for: 0.25, reduceMotion: true),
            0,
            accuracy: 0.001
        )
        XCTAssertNotEqual(
            LaunchIridescentGlowMotion.shimmerOffset(for: 0.25, reduceMotion: false),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LaunchIridescentGlowMotion.breathOpacity(for: 0.5, reduceMotion: true),
            1,
            accuracy: 0.001
        )
    }

    func testHighlightSweepWrapsSmoothly() {
        XCTAssertEqual(
            LaunchIridescentGlowMotion.shimmerOffset(for: 0, reduceMotion: false),
            LaunchIridescentGlowMotion.shimmerOffset(for: 1, reduceMotion: false),
            accuracy: 0.001
        )
        XCTAssertEqual(
            LaunchIridescentGlowMotion.shimmerOffset(for: 0.5, reduceMotion: false),
            0,
            accuracy: 0.001
        )
    }

    func testBreathOpacityStaysSubtle() {
        XCTAssertGreaterThan(
            LaunchIridescentGlowMotion.breathOpacity(for: 0, reduceMotion: false),
            0.9
        )
        XCTAssertLessThan(
            LaunchIridescentGlowMotion.breathOpacity(for: 0, reduceMotion: false),
            1
        )
        XCTAssertEqual(
            LaunchIridescentGlowMotion.breathOpacity(for: 1, reduceMotion: false),
            1,
            accuracy: 0.001
        )
    }
}
