import SwiftUI

struct GrassIslandView: View {
    let sessions: [SessionData]

    private let patchWidth: CGFloat = 80

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                HStack(spacing: 0) {
                    ForEach(0..<patchCount(for: geometry.size.width), id: \.self) { _ in
                        Image("GrassIsland")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: patchWidth, height: geometry.size.height)
                            .clipped()
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)

                if sessions.isEmpty {
                    GrassSpriteView(state: .idle, xPosition: 0.5, yOffset: -15, totalWidth: geometry.size.width)
                } else {
                    // Sorted far-to-near so closer sprites paint on top
                    ForEach(depthSortedSessions) { session in
                        GrassSpriteView(
                            state: session.state,
                            xPosition: session.spriteXPosition,
                            yOffset: session.spriteYOffset,
                            totalWidth: geometry.size.width
                        )
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .clipped()
    }

    private var depthSortedSessions: [SessionData] {
        sessions.sorted { $0.spriteYOffset < $1.spriteYOffset }
    }

    private func patchCount(for width: CGFloat) -> Int {
        Int(ceil(width / patchWidth)) + 1
    }
}

private struct GrassSpriteView: View {
    let state: NotchiState
    let xPosition: CGFloat
    let yOffset: CGFloat
    let totalWidth: CGFloat

    @State private var isSwayingRight = true
    @State private var isBobUp = true

    private let spriteSize: CGFloat = 64
    private let swayDuration: Double = 2.0
    private let bobAmplitude: CGFloat = 2

    // Must match SessionData's xPositionMin/xPositionRange contract
    private let usableWidthFraction: CGFloat = 0.8
    private let leftMarginFraction: CGFloat = 0.1

    var body: some View {
        SpriteSheetView(
            spriteSheet: state.spriteSheetName,
            frameCount: state.frameCount,
            columns: state.columns,
            fps: state.animationFPS,
            isAnimating: true
        )
        .frame(width: spriteSize, height: spriteSize)
        .rotationEffect(.degrees(isSwayingRight ? state.swayAmplitude : -state.swayAmplitude), anchor: .bottom)
        .offset(x: xOffset, y: yOffset + (isBobUp ? -bobAmplitude : bobAmplitude))
        .onAppear {
            startSwayAnimation()
            startBobAnimation()
        }
        .onChange(of: state) {
            startBobAnimation()
        }
    }

    private var xOffset: CGFloat {
        let usableWidth = totalWidth * usableWidthFraction
        let leftMargin = totalWidth * leftMarginFraction
        return leftMargin + (xPosition * usableWidth) - (totalWidth / 2)
    }

    private func startSwayAnimation() {
        withAnimation(.easeInOut(duration: swayDuration).repeatForever(autoreverses: true)) {
            isSwayingRight.toggle()
        }
    }

    private func startBobAnimation() {
        withAnimation(.easeInOut(duration: state.bobDuration).repeatForever(autoreverses: true)) {
            isBobUp.toggle()
        }
    }
}
