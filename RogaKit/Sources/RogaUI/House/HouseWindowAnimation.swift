import CoreGraphics
import Foundation
import SwiftUI

/// A looping busy animation made from the four panes of the Roga mark.
public nonisolated enum HouseWindowAnimation: CaseIterable, Identifiable, Sendable {
    case windowChase
    case shutterFlip
    case sashShift
    case lanternSweep
    case doubleTap
    case stackAndDeal

    public static let logoRotation = Angle.degrees(11)

    public var id: Self { self }

    public var title: String {
        switch self {
        case .windowChase: "Window Chase"
        case .shutterFlip: "Shutter Flip"
        case .sashShift: "Sash Shift"
        case .lanternSweep: "Lantern Sweep"
        case .doubleTap: "Double Tap"
        case .stackAndDeal: "Stack and Deal"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .windowChase: 1.60
        case .shutterFlip: 1.90
        case .sashShift, .doubleTap: 2.20
        case .lanternSweep: 2.80
        case .stackAndDeal: 2.45
        }
    }

    /// A readable, stationary frame for Reduce Motion.
    var stillTime: TimeInterval {
        switch self {
        case .windowChase: 0.042
        case .shutterFlip: 0.151
        case .sashShift: 0.55
        case .lanternSweep: 0.13
        case .doubleTap: 0
        case .stackAndDeal: 1.90
        }
    }

    struct PanePose: Equatable, Sendable {
        var offset = CGPoint.zero
        var turn = 0.0
        var scale = 1.0
        var shutterWidth = 1.0
        /// 0 is the resting orange, 0.5 is warm orange, and 1 is lit.
        var warmth = 0.0
        var glow = 0.0

        func transform(around center: CGPoint) -> CGAffineTransform {
            let tilt = HouseWindowAnimation.logoRotation.radians
            return CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(rotationAngle: -tilt))
                .concatenating(CGAffineTransform(scaleX: scale * shutterWidth, y: scale))
                .concatenating(CGAffineTransform(rotationAngle: tilt + turn * .pi / 180))
                .concatenating(CGAffineTransform(translationX: center.x + offset.x, y: center.y + offset.y))
        }

        func mixed(with end: Self, by amount: Double) -> Self {
            Self(
                offset: Tween.mix(offset, end.offset, amount),
                turn: Tween.mix(turn, end.turn, amount),
                scale: Tween.mix(scale, end.scale, amount),
                shutterWidth: Tween.mix(shutterWidth, end.shutterWidth, amount),
                warmth: Tween.mix(warmth, end.warmth, amount),
                glow: Tween.mix(glow, end.glow, amount)
            )
        }
    }

    func pose(of pane: HouseOutline.Pane, at time: TimeInterval) -> PanePose {
        let tracks: [Track]? = switch self {
        case .windowChase: Self.chase
        case .shutterFlip: Self.shutter
        case .sashShift: Self.sash
        case .lanternSweep: nil
        case .doubleTap: Self.tap
        case .stackAndDeal: Self.stack
        }
        guard let tracks else { return PanePose() }
        let track = tracks[pane.rawValue]
        let phase = Self.phase(at: time + track.lead, duration: duration)
        return track.pose(at: phase)
    }

    /// How far the band of light has traveled, in the mark's coordinates.
    func beamTravel(at time: TimeInterval) -> Double? {
        guard self == .lanternSweep else { return nil }
        let phase = Self.phase(at: time + 0.64, duration: duration)
        switch phase {
        case 0.09 ..< 0.46: return 204 * UnitCurve.easeInOut.value(at: (phase - 0.09) / 0.37)
        case 0.46 ..< 0.55: return 204
        case 0.55 ..< 0.92: return 204 * (1 - UnitCurve.easeInOut.value(at: (phase - 0.55) / 0.37))
        default: return 0
        }
    }

    private static func phase(at time: TimeInterval, duration: TimeInterval) -> Double {
        let cycles = time / duration
        return cycles - cycles.rounded(.down)
    }

    private struct Track: Sendable {
        var lead: TimeInterval
        var curve: UnitCurve = .easeInOut
        var keyframes: [(phase: Double, pose: PanePose)]

        func pose(at phase: Double) -> PanePose {
            var start = keyframes[0]
            for end in keyframes.dropFirst() {
                if phase < end.phase {
                    let progress = (phase - start.phase) / (end.phase - start.phase)
                    return start.pose.mixed(with: end.pose, by: curve.value(at: progress))
                }
                start = end
            }
            return start.pose
        }
    }

    private static let rest = PanePose()

    // Pane tracks are in clockwise order from the top left.
    private static let chase = [0.23, 1.43, 1.03, 0.63].map { lead in
        Track(lead: lead, keyframes: [
            (0, rest), (0.17, PanePose(warmth: 1, glow: 15)),
            (0.33, PanePose(warmth: 0.5, glow: 6)), (0.56, rest), (1, rest),
        ])
    }

    private static let shutter = [0.40, 0.24, 1.19, 1.35].map { lead in
        Track(lead: lead, keyframes: [
            (0, rest), (0.15, PanePose(shutterWidth: 0.10, warmth: 0.5)),
            (0.29, PanePose(warmth: 1, glow: 11)), (0.58, rest), (1, rest),
        ])
    }

    private static let sash = HouseOutline.Pane.allCases.map { pane in
        let upper = pane == .topLeft || pane == .topRight
        let left = pane == .topLeft || pane == .bottomLeft
        let row = PanePose(offset: upper ? CGPoint(x: -27, y: -5) : CGPoint(x: 27, y: 5))
        let column = PanePose(offset: left ? CGPoint(x: 4, y: -24) : CGPoint(x: -4, y: 24))
        let aligned = PanePose(warmth: 0.5)
        return Track(
            lead: 0.31,
            curve: .bezier(startControlPoint: UnitPoint(x: 0.44, y: 0.06), endControlPoint: UnitPoint(x: 0.25, y: 1)),
            keyframes: [
                (0, rest), (0.17, row), (0.24, row), (0.38, aligned), (0.44, aligned),
                (0.61, column), (0.68, column), (0.83, aligned), (0.89, aligned), (1, rest),
            ]
        )
    }

    private static let tap = [0.22, 1.32, 0.22, 1.32].map { lead in
        Track(lead: lead, keyframes: [
            (0, rest), (0.10, PanePose(offset: CGPoint(x: 0, y: -7), scale: 1.12, warmth: 1, glow: 9)),
            (0.17, rest), (0.23, PanePose(offset: CGPoint(x: 0, y: -4), scale: 1.08, warmth: 0.5, glow: 5)),
            (0.30, rest), (1, rest),
        ])
    }

    private static let stack = [
        stackTrack(x: 20, y: 31, turn: 24, warmth: 0, lead: 0.30),
        stackTrack(x: -43, y: 20, turn: 29, warmth: 0.5, lead: 0.38),
        stackTrack(x: -23, y: -35, turn: 36, warmth: 0.71, lead: 0.46),
        stackTrack(x: 40, y: -14, turn: 41, warmth: 1, glow: 7, lead: 0.54),
    ]

    private static func stackTrack(
        x: Double, y: Double, turn: Double, warmth: Double, glow: Double = 0, lead: TimeInterval
    ) -> Track {
        let stacked = PanePose(offset: CGPoint(x: x, y: y), turn: turn, scale: 0.82, warmth: warmth, glow: glow)
        let dealt = PanePose(offset: CGPoint(x: x * -0.12, y: y * -0.12), turn: -4, warmth: 0.5)
        return Track(
            lead: lead,
            curve: .bezier(startControlPoint: UnitPoint(x: 0.49, y: 0.02), endControlPoint: UnitPoint(x: 0.25, y: 1)),
            keyframes: [(0, rest), (0.14, rest), (0.43, stacked), (0.56, stacked), (0.76, dealt), (0.85, rest), (1, rest)]
        )
    }
}
