import CoreGraphics
import Foundation

/// A way for the house to move, which repeats.
nonisolated protocol HouseMotion: Sendable {
    /// How long one cycle takes at normal speed, in seconds.
    var duration: TimeInterval { get }
    /// Where a run starts, as a fraction of a cycle.
    var startPhase: Double { get }
    /// Where the house stands for someone who asked for less motion, as a
    /// fraction of a cycle. It should still show what the house is doing.
    var stillPhase: Double { get }
    /// The pose this many seconds in, at normal speed.
    func pose(at time: TimeInterval) -> HousePose
}

nonisolated extension HouseMotion {
    /// How many whole cycles have gone by, and how far through the next one
    /// this moment is, from 0 up to 1.
    func cycle(at time: TimeInterval) -> (count: Double, phase: Double) {
        let cycles = time / duration
        let count = cycles.rounded(.down)
        return (count, cycles - count)
    }
}

/// Every animation the house has.
nonisolated enum HouseAnimation: CaseIterable, Identifiable, Sendable {
    case push
    case tugOfWar
    case heave
    case waddle

    var id: Self { self }

    var title: String {
        switch self {
        case .push: "Push"
        case .tugOfWar: "Tug of War"
        case .heave: "Heave"
        case .waddle: "Waddle"
        }
    }

    var motion: any HouseMotion {
        switch self {
        case .push: StrideMotion.push
        case .tugOfWar: StrideMotion.tugOfWar
        case .heave: HeaveMotion()
        case .waddle: WaddleMotion()
        }
    }
}

/// Walking on the spot with the feet taking turns. Each foot slides along the
/// floor while it's down, then lifts and steps back to where it started. Pushing
/// and the tug of war are this motion with different numbers.
nonisolated struct StrideMotion: HouseMotion {
    struct Leg: Sendable {
        var hip: CGPoint
        /// Where the ankle lands and where it lifts off, measured along the
        /// floor from the hip.
        var touchdown: CGFloat
        var liftoff: CGFloat
        /// How far from the hip the foot has to be for the leg to go straight.
        var length: CGFloat
        /// How far ahead of the cycle this leg runs, as a fraction of it.
        var phase: Double
    }

    var duration: TimeInterval = 1.25
    var startPhase = 0.0
    var stillPhase = 0.3
    /// The share of its cycle that a foot spends on the floor.
    var timeDown = 0.66
    var lean: Double
    var offset: CGVector
    var rear: Leg
    var front: Leg
    var stepHeight: CGFloat
    /// The foot's pitch when it lands, when it lifts off, and in the middle of a
    /// step.
    var pitchLanding: Double
    var pitchLeaving: Double
    var pitchInAir: Double
    /// How the body rocks with each step: along the floor, up and down, and in
    /// its lean.
    var rock: (dx: CGFloat, dy: CGFloat, lean: Double)

    /// Leaning forward with both legs behind the body.
    static let push = StrideMotion(
        lean: 15,
        offset: CGVector(dx: -10, dy: 6),
        rear: Leg(hip: HouseRig.rearHip, touchdown: -112, liftoff: -204, length: 276, phase: 0),
        front: Leg(hip: HouseRig.frontHip, touchdown: -30, liftoff: -122, length: 190, phase: 0.5),
        stepHeight: 26,
        pitchLanding: -2,
        pitchLeaving: 30,
        pitchInAir: 42,
        rock: (dx: 7, dy: 4, lean: 1.5)
    )

    /// Leaning back with both legs in front of the body, heels dug in.
    static let tugOfWar = StrideMotion(
        lean: -33,
        offset: CGVector(dx: -50, dy: 6),
        rear: Leg(hip: HouseRig.rearHip, touchdown: 50, liftoff: 142, length: 185, phase: 0),
        front: Leg(hip: HouseRig.frontHip, touchdown: 110, liftoff: 202, length: 268, phase: 0.5),
        stepHeight: 28,
        pitchLanding: -24,
        pitchLeaving: -42,
        pitchInAir: 6,
        rock: (dx: -8, dy: 4, lean: -1.8)
    )

    func pose(at time: TimeInterval) -> HousePose {
        let phase = cycle(at: time).phase
        let steps = 2 * .pi * 2 * phase
        let wave = sin(steps + 0.5)
        let dip = cos(steps)
        let body = HouseBody(
            lean: lean + rock.lean * wave,
            offset: CGVector(dx: offset.dx + rock.dx * wave, dy: offset.dy + rock.dy * dip)
        )
        // Feet are placed from where the body would be if it didn't rock, so
        // that its rocking doesn't drag them along the floor.
        let steady = HouseBody(lean: lean, offset: offset)
        func leg(_ leg: Leg) -> HouseLeg {
            let foot = self.foot(leg, hipX: steady.place(leg.hip).x, phase: (phase + leg.phase).truncatingRemainder(dividingBy: 1))
            return HouseLeg(hip: body.place(leg.hip), foot: foot, length: leg.length, fold: 0.14 + 0.16 * foot.curl)
        }
        let speed = (rear.liftoff - rear.touchdown) / (timeDown * duration)
        return HousePose(body: body, rearLeg: leg(rear), frontLeg: leg(front), floorTravel: speed * time)
    }

    private func foot(_ leg: Leg, hipX: CGFloat, phase: Double) -> HouseFoot {
        if phase < timeDown {
            let amount = phase / timeDown
            return HouseFoot(
                x: hipX + Tween.mix(leg.touchdown, leg.liftoff, amount),
                pitch: Tween.mix(pitchLanding, pitchLeaving, amount * amount)
            )
        }
        let amount = (phase - timeDown) / (1 - timeDown)
        return HouseFoot(
            x: hipX + Tween.mix(leg.liftoff, leg.touchdown, Tween.smooth(amount)),
            lift: stepHeight * Tween.arc(amount),
            pitch: Tween.through(pitchLeaving, pitchInAir, pitchLanding, amount),
            curl: Tween.arc(amount)
        )
    }
}

/// Pulling the way sailors heave on a line. One foot steps back, then the other,
/// which brings the body forward over them. It winds up, then swings back with
/// both feet planted, and holds there.
nonisolated struct HeaveMotion: HouseMotion {
    struct Leg: Sendable {
        var hip: CGPoint
        /// Where the ankle stands before the heave and after it.
        var before: CGFloat
        var after: CGFloat
        /// How far from the hip the foot has to be for the leg to go straight.
        var length: CGFloat
        /// When this foot's step starts and ends, as fractions of a cycle. The
        /// two steps mustn't overlap.
        var step: ClosedRange<Double>
    }

    var duration: TimeInterval = 1.5
    /// A run starts with the feet together, so that even a quick pull gets to
    /// the heave.
    var startPhase = 0.42
    var stillPhase = 0.85
    /// When both steps are over, when the wind-up is over, and when the swing
    /// back is over.
    var stepsEnd = 0.42
    var windUpEnd = 0.49
    var heaveEnd = 0.773

    var forward = HouseBody(lean: 6, offset: CGVector(dx: 10, dy: 2))
    var woundUp = HouseBody(lean: 9, offset: CGVector(dx: 15, dy: 8))
    var back = HouseBody(lean: -33, offset: CGVector(dx: -50, dy: 6))

    var rear = Leg(hip: HouseRig.rearHip, before: 540, after: 630, length: 205, step: 0 ... 0.21)
    var front = Leg(hip: HouseRig.frontHip, before: 640, after: 730, length: 228, step: 0.21 ... 0.42)

    var stepHeight: CGFloat = 40
    /// How far the body rises with each step.
    var bob: CGFloat = 8
    var pitchPlanted = -2.0
    var pitchDugIn = -36.0
    var pitchInAir = 8.0

    func pose(at time: TimeInterval) -> HousePose {
        let (count, phase) = cycle(at: time)
        let heave: Double
        if phase < windUpEnd {
            heave = 0
        } else if phase < heaveEnd {
            // It starts hard and eases into the hold.
            heave = pow(Tween.smooth((phase - windUpEnd) / (heaveEnd - windUpEnd)), 0.6)
        } else {
            heave = 1
        }
        let body = self.body(phase: phase, heave: heave)
        func leg(_ leg: Leg) -> HouseLeg {
            let foot = self.foot(leg, phase: phase, heave: heave)
            return HouseLeg(hip: body.place(leg.hip), foot: foot, length: leg.length, fold: 0.14 + 0.16 * foot.curl)
        }
        // The feet are down for the whole heave and the floor moves with them.
        // It stays still during the steps, when one foot is always down.
        let span = rear.after - rear.before
        return HousePose(body: body, rearLeg: leg(rear), frontLeg: leg(front), floorTravel: (count + heave) * span)
    }

    private func body(phase: Double, heave: Double) -> HouseBody {
        if phase < stepsEnd {
            let amount = phase / stepsEnd
            var body = Self.blend(back, forward, Tween.smooth(amount))
            body.offset.dy -= bob * abs(sin(2 * .pi * amount))
            return body
        }
        if phase < windUpEnd {
            return Self.blend(forward, woundUp, Tween.smooth((phase - stepsEnd) / (windUpEnd - stepsEnd)))
        }
        if phase < heaveEnd {
            return Self.blend(woundUp, back, heave)
        }
        // It overshoots a little as it takes the strain.
        let amount = (phase - heaveEnd) / (1 - heaveEnd)
        var body = back
        body.lean -= 2.5 * Tween.arc(amount) * (1 - amount)
        return body
    }

    private func foot(_ leg: Leg, phase: Double, heave: Double) -> HouseFoot {
        if phase < leg.step.lowerBound {
            return HouseFoot(x: leg.after, pitch: pitchDugIn)
        }
        if phase < leg.step.upperBound {
            let amount = (phase - leg.step.lowerBound) / (leg.step.upperBound - leg.step.lowerBound)
            return HouseFoot(
                x: Tween.mix(leg.after, leg.before, Tween.smooth(amount)),
                lift: stepHeight * Tween.arc(amount),
                pitch: Tween.through(pitchDugIn, pitchInAir, pitchPlanted, amount),
                curl: Tween.arc(amount)
            )
        }
        return HouseFoot(x: Tween.mix(leg.before, leg.after, heave), pitch: Tween.mix(pitchPlanted, pitchDugIn, heave))
    }

    private static func blend(_ start: HouseBody, _ end: HouseBody, _ amount: Double) -> HouseBody {
        HouseBody(
            lean: Tween.mix(start.lean, end.lean, amount),
            offset: CGVector(
                dx: Tween.mix(start.offset.dx, end.offset.dx, amount),
                dy: Tween.mix(start.offset.dy, end.offset.dy, amount)
            )
        )
    }
}

/// The whole house rocking from side to side in the stride the mark is drawn in,
/// with no joints moving. It says something's happening without saying which way.
nonisolated struct WaddleMotion: HouseMotion {
    var duration: TimeInterval = 0.7
    var startPhase = 0.0
    var stillPhase = 0.25
    /// How far it rocks each way, in degrees, and how far it rises when it
    /// leans forward.
    var swing = 7.0
    var rise: CGFloat = 32
    /// The point on the floor it rocks around.
    var anchor = CGPoint(x: 592, y: 659)

    func pose(at time: TimeInterval) -> HousePose {
        let phase = cycle(at: time).phase
        let amount = Tween.smooth(phase < 0.5 ? phase * 2 : 2 - phase * 2)
        let rotation = CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(rotationAngle: Tween.mix(-swing, swing, amount) * .pi / 180))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y - rise * amount))
        return HousePose.mark.applying(rotation)
    }
}
