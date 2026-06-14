import SwiftUI

struct SessionSpriteView: View {
    let state: NotchiState
    let isPrimarySprite: Bool
    var mirrorSeed: String = "session-sprite"
    var animationStartDate: Date = SpriteAnimationPhase.sharedLoopAnchor
    var repeatsAnimation = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stateMirrorKey: String?
    @State private var stateMirrored = false

    private var bobAmplitude: CGFloat {
        guard !reduceMotion, state.bobAmplitude > 0 else { return 0 }
        return isPrimarySprite ? state.bobAmplitude : state.bobAmplitude * 0.67
    }

    private var trembleAmplitude: CGFloat {
        guard !reduceMotion, state.emotion == .sob else { return 0 }
        return Self.sobTrembleAmplitude
    }

    private static let sobTrembleAmplitude: CGFloat = 0.2

    var body: some View {
        TimelineView(.animation(minimumInterval: state.motionFrameInterval, paused: bobAmplitude == 0 && trembleAmplitude == 0)) { timeline in
            let presentation = spriteSheetPresentation(at: timeline.date)
            SpriteSheetView(
                spriteSheet: presentation.spriteSheetName,
                frameCount: state.frameCount,
                columns: state.columns,
                fps: state.animationFPS,
                isAnimating: true,
                animationStartDate: effectiveAnimationStartDate,
                repeatsAnimation: repeatsAnimation,
                isMirrored: presentation.renderMirrored
            )
            .frame(width: 32, height: 32)
            .offset(
                x: trembleOffset(at: timeline.date, amplitude: trembleAmplitude),
                y: bobOffset(at: timeline.date, duration: state.bobDuration, amplitude: bobAmplitude)
            )
        }
        .onAppear(perform: updateStateMirroring)
        .onChange(of: mirrorKey) { _, _ in updateStateMirroring() }
    }

    private func spriteSheetPresentation(at date: Date) -> SpriteSheetPresentation {
        state.spriteSheetPresentation(isMirrored: isMirrored(at: date))
    }

    private var mirrorKey: String {
        "\(mirrorSeed)|\(state.spriteSheetName)"
    }

    private var effectiveAnimationStartDate: Date {
        guard repeatsAnimation, animationStartDate == SpriteAnimationPhase.sharedLoopAnchor else {
            return animationStartDate
        }

        return SpriteAnimationPhase.variedLoopAnchor(for: mirrorSeed, spriteSheet: state.spriteSheetName)
    }

    private func isMirrored(at date: Date) -> Bool {
        SpriteMirrorPolicy.isMirrored(
            state: state,
            seed: mirrorSeed,
            date: date,
            stateMirrored: stateMirrored
        )
    }

    private func updateStateMirroring() {
        guard stateMirrorKey != mirrorKey else { return }
        stateMirrorKey = mirrorKey
        stateMirrored = SpriteMirrorPolicy.initialMirroring(seed: mirrorKey)
    }
}
