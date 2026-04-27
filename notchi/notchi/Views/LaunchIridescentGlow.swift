import SwiftUI

enum LaunchIridescentGlowTiming {
    static let fadeInDuration = 1.0
    static let holdDuration = 4.0
    static let fadeOutDuration = 1.5
    static let totalDuration = fadeInDuration + holdDuration + fadeOutDuration
    static let reducedMotionDuration = 0.0

    private static let peakOpacity = 1.0
    private static let fadeInEnd = fadeInDuration / totalDuration
    private static let holdEnd = (fadeInDuration + holdDuration) / totalDuration

    static func duration(reduceMotion: Bool) -> Double {
        reduceMotion ? reducedMotionDuration : totalDuration
    }

    static func opacity(for progress: Double) -> Double {
        let progress = clamp(progress)

        if progress <= fadeInEnd {
            return peakOpacity * easeOut(progress / fadeInEnd)
        }

        if progress <= holdEnd {
            return peakOpacity
        }

        let fadeProgress = (progress - holdEnd) / (1 - holdEnd)
        return peakOpacity * (1 - smoothStep(fadeProgress))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func easeOut(_ value: Double) -> Double {
        let inverse = 1 - clamp(value)
        return 1 - (inverse * inverse)
    }

    private static func smoothStep(_ value: Double) -> Double {
        let value = clamp(value)
        return value * value * (3 - (2 * value))
    }
}

enum LaunchIridescentGlowMotion {
    static let baseColorCycleDuration = 6.0
    static let highlightSweepDuration = 3.8
    static let breathDuration = 4.5
    static let breathOpacityRange = 0.08

    static func shimmerOffset(for phase: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        return -0.36 + (normalizedPhase(phase) * 0.72)
    }

    static func breathOpacity(for phase: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 1 }
        return 1 - breathOpacityRange + (smoothStep(clamp(phase)) * breathOpacityRange)
    }

    private static func normalizedPhase(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func smoothStep(_ value: Double) -> Double {
        value * value * (3 - (2 * value))
    }
}

struct LaunchIridescentGlow: View, Animatable {
    static let bleed: CGFloat = 28

    @State private var colorRotation: Double = 0
    @State private var shimmerPhase: Double = 0
    @State private var breathPhase: Double = 0

    var progress: Double
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let systemNotchPath: CGPath?
    let reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private var opacity: Double {
        LaunchIridescentGlowTiming.opacity(for: progress)
    }

    private var shimmerOffset: Double {
        LaunchIridescentGlowMotion.shimmerOffset(
            for: shimmerPhase,
            reduceMotion: reduceMotion
        )
    }

    private var breathOpacity: Double {
        LaunchIridescentGlowMotion.breathOpacity(
            for: breathPhase,
            reduceMotion: reduceMotion
        )
    }

    private var flowRotation: Double {
        reduceMotion ? 0 : colorRotation
    }

    private var iridescentGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: LaunchIridescentGlowPalette.angularStops),
            center: .center,
            startAngle: .degrees(flowRotation * 360),
            endAngle: .degrees(flowRotation * 360 + 360)
        )
    }

    private var shimmerGradient: LinearGradient {
        LinearGradient(
            colors: LaunchIridescentGlowPalette.linearColors,
            startPoint: UnitPoint(x: -0.2 + shimmerOffset, y: 0.5),
            endPoint: UnitPoint(x: 1.2 + shimmerOffset, y: 0.5)
        )
    }

    var body: some View {
        ZStack {
            notchOutline
                .stroke(
                    iridescentGradient,
                    style: StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round)
                )
                .blur(radius: 12)
                .opacity(0.54)

            notchOutline
                .stroke(
                    iridescentGradient,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
                )
                .blur(radius: 4)
                .opacity(0.86)

            notchOutline
                .stroke(
                    shimmerGradient,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                )
                .blur(radius: 2)
                .opacity(0.56)

            notchOutline
                .stroke(
                    Color.white.opacity(0.58),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
                .blur(radius: 0.4)
                .opacity(0.84)
        }
        .mask {
            notchExteriorMask
                .fill(style: FillStyle(eoFill: true))
        }
        .opacity(opacity * breathOpacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: startColorFlow)
    }

    private var notchOutline: NotchGlowOutlineShape {
        NotchGlowOutlineShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            systemNotchShape: systemNotchShape,
            bleed: Self.bleed
        )
    }

    private var notchExteriorMask: NotchGlowExteriorMask {
        NotchGlowExteriorMask(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            systemNotchShape: systemNotchShape,
            bleed: Self.bleed
        )
    }

    private var systemNotchShape: SystemNotchShape? {
        systemNotchPath.map { SystemNotchShape(cgPath: $0) }
    }

    private func startColorFlow() {
        guard !reduceMotion else {
            colorRotation = 0
            shimmerPhase = 0
            breathPhase = 0
            return
        }

        colorRotation = 0
        shimmerPhase = 0
        breathPhase = 0

        withAnimation(.linear(duration: LaunchIridescentGlowMotion.baseColorCycleDuration).repeatForever(autoreverses: false)) {
            colorRotation = 1
        }

        withAnimation(.linear(duration: LaunchIridescentGlowMotion.highlightSweepDuration).repeatForever(autoreverses: false)) {
            shimmerPhase = 1
        }

        withAnimation(.easeInOut(duration: LaunchIridescentGlowMotion.breathDuration).repeatForever(autoreverses: true)) {
            breathPhase = 1
        }
    }
}

private enum LaunchIridescentGlowPalette {
    static let angularStops: [Gradient.Stop] = [
        Gradient.Stop(color: Color(red: 0.74, green: 0.51, blue: 1.0), location: 0.00),
        Gradient.Stop(color: Color(red: 1.0, green: 0.68, blue: 0.92), location: 0.18),
        Gradient.Stop(color: Color(red: 1.0, green: 0.78, blue: 0.58), location: 0.34),
        Gradient.Stop(color: Color(red: 0.45, green: 0.88, blue: 1.0), location: 0.52),
        Gradient.Stop(color: Color(red: 0.57, green: 0.63, blue: 1.0), location: 0.70),
        Gradient.Stop(color: Color(red: 0.94, green: 0.64, blue: 1.0), location: 0.86),
        Gradient.Stop(color: Color(red: 0.74, green: 0.51, blue: 1.0), location: 1.00),
    ]

    static let linearColors = [
        Color(red: 1.0, green: 0.70, blue: 0.95),
        Color(red: 0.58, green: 0.88, blue: 1.0),
        Color(red: 0.78, green: 0.58, blue: 1.0),
        Color(red: 1.0, green: 0.80, blue: 0.56),
        Color(red: 0.92, green: 0.64, blue: 1.0),
    ]
}

private struct NotchGlowOutlineShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    var systemNotchShape: SystemNotchShape?
    var bleed: CGFloat

    func path(in rect: CGRect) -> Path {
        let outlineRect = rect.insetBy(
            dx: bleed,
            dy: bleed
        )

        if let systemNotchShape {
            return systemNotchShape.path(in: outlineRect)
        }

        return NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
        .path(in: outlineRect)
    }
}

private struct NotchGlowExteriorMask: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    var systemNotchShape: SystemNotchShape?
    var bleed: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addPath(
            NotchGlowOutlineShape(
                topCornerRadius: topCornerRadius,
                bottomCornerRadius: bottomCornerRadius,
                systemNotchShape: systemNotchShape,
                bleed: bleed
            )
            .path(in: rect)
        )
        return path
    }
}
