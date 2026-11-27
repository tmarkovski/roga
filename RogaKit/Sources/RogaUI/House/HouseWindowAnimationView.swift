import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import ThemeUI

/// A standalone window animation for a busy state. The caller supplies any
/// accessible status text alongside it.
public struct HouseWindowAnimationView: View {
    private let animation: HouseWindowAnimation
    private let size: CGFloat
    private let rotation: Angle

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var startedAt = Date.now

    /// - Parameters:
    ///   - size: The side of the square drawing area, including space for motion.
    ///   - rotation: The overall clockwise tilt. Use `.zero` for an upright
    ///     window. This applies to the whole animation as well as the panes.
    public init(
        animation: HouseWindowAnimation,
        size: CGFloat = 24,
        rotation: Angle = HouseWindowAnimation.logoRotation
    ) {
        self.animation = animation
        self.size = size
        self.rotation = rotation
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: size < 28 ? 1.0 / 30 : 1.0 / 60, paused: reducesMotion)) { timeline in
            let time = reducesMotion ? animation.stillTime : timeline.date.timeIntervalSince(startedAt)
            HouseWindowFigure(animation: animation, time: time, rotation: rotation)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A single frame of the animation, drawn in the coordinates of the Roga mark.
struct HouseWindowFigure: View {
    static let frame = CGRect(x: 526, y: 256, width: 224, height: 224)

    let animation: HouseWindowAnimation
    let time: TimeInterval
    let rotation: Angle

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = HouseWindowColors(dark: colorScheme == .dark)
        Canvas { context, size in
            let placement = Self.placement(in: size, rotation: rotation)
            let scale = min(size.width, size.height) / Self.frame.width

            for pane in HouseOutline.Pane.allCases {
                let path = pane.path
                let bounds = path.boundingRect
                let pose = animation.pose(of: pane, at: time)
                let transform = pose.transform(around: CGPoint(x: bounds.midX, y: bounds.midY))
                var paneContext = context
                if pose.glow > 0 {
                    paneContext.addFilter(.shadow(color: colors.halo, radius: pose.glow * scale))
                }
                paneContext.fill(path.applying(transform.concatenating(placement)), with: .color(colors.fill(warmth: pose.warmth)))
            }

            if let beam = Self.beam(of: animation, at: time) {
                context.fill(
                    HouseOutline.window.applying(placement),
                    with: .linearGradient(
                        colors.beam,
                        startPoint: beam.start.applying(placement),
                        endPoint: beam.end.applying(placement)
                    )
                )
            }
        }
    }

    /// Where the band of light starts and ends, in the mark's coordinates, for
    /// an animation that has one.
    static func beam(of animation: HouseWindowAnimation, at time: TimeInterval) -> (start: CGPoint, end: CGPoint)? {
        guard let travel = animation.beamTravel(at: time) else { return nil }
        let axis = Angle.degrees(32).radians
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let start = travel - 140
        let beamStart = CGPoint(x: center.x + cos(axis) * start, y: center.y + sin(axis) * start)
        let beamEnd = CGPoint(x: beamStart.x + cos(axis) * 76, y: beamStart.y + sin(axis) * 76)
        return (beamStart, beamEnd)
    }

    static func placement(in size: CGSize, rotation: Angle) -> CGAffineTransform {
        let scale = min(size.width, size.height) / frame.width
        return CGAffineTransform(translationX: -frame.midX, y: -frame.midY)
            .concatenating(CGAffineTransform(rotationAngle: rotation.radians - HouseWindowAnimation.logoRotation.radians))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
    }
}

/// The colors of the panes, their glow and the band of light, in each
/// appearance.
struct HouseWindowColors {
    let idle: Color
    let warm: Color
    let lit: Color
    let halo: Color

    init(dark: Bool) {
        idle = Color(nsColor: .srgb(dark ? 0xBC461D : 0xD54802))
        warm = Color(nsColor: .srgb(dark ? 0xEE752F : 0xE56C2D))
        lit = Color(nsColor: .srgb(dark ? 0xFFDC9D : 0xFFC477))
        halo = Color(nsColor: .srgb(dark ? 0xFFBF65 : 0xFFAE53, alpha: 0.7))
    }

    func fill(warmth: Double) -> Color {
        if warmth <= 0.5 { return idle.mix(with: warm, by: 2 * warmth) }
        return warm.mix(with: lit, by: 2 * warmth - 1)
    }

    var beam: Gradient {
        Gradient(stops: [
            .init(color: warm.opacity(0), location: 0),
            .init(color: warm, location: 0.32),
            .init(color: lit, location: 0.56),
            .init(color: warm, location: 0.79),
            .init(color: warm.opacity(0), location: 1),
        ])
    }
}

#if DEBUG
#Preview("Window Animations") {
    HouseWindowAnimationPreview()
}

private struct HouseWindowAnimationPreview: View {
    @State private var rotation = HouseWindowAnimation.logoRotation.degrees

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Slider(value: $rotation, in: -25 ... 25, step: 1) { Text("Rotation") }
                Text("\(rotation.formatted(.number.precision(.fractionLength(0))))°")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 16) {
                ForEach(HouseWindowAnimation.allCases) { animation in
                    VStack(spacing: 4) {
                        HouseWindowAnimationView(animation: animation, size: 118, rotation: .degrees(rotation))
                        Text(animation.title)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 470)
    }
}
#endif
