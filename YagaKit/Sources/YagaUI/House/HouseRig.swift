import CoreGraphics
import Foundation

/// What the house is made of, so that it can move: a body that stays rigid, and
/// two legs with joints. Everything is in the coordinates of
/// docs/design/branding/yaga-mark.svg, where y grows downward, and the house
/// faces right.
///
/// To add an animation, write a `HouseMotion` that builds a `HousePose` for any
/// moment from `HouseBody`, `HouseFoot` and `HouseLeg`, and add a case for it to
/// `HouseAnimation`.
nonisolated enum HouseRig {
    /// The point the body turns around.
    static let pivot = CGPoint(x: 620, y: 500)
    /// Where the feet stand.
    static let floor: CGFloat = 690
    /// Where the legs join the body, before it moves. They're inside the
    /// outline, so the joints don't show.
    static let rearHip = CGPoint(x: 560, y: 462)
    static let frontHip = CGPoint(x: 680, y: 470)

    static let legWidth: CGFloat = 44
    static let toeWidth: CGFloat = 30

    /// The part of these coordinates that a view shows. Every pose of every
    /// animation fits inside it, which a test checks.
    static let frame = CGRect(x: 278, y: 128, width: 640, height: 570)
}

/// Where the body is. It's rigid, so one rotation and one offset place all of it.
nonisolated struct HouseBody: Equatable, Sendable {
    /// How far it's turned around `HouseRig.pivot` from how the mark draws it, in
    /// degrees. The mark already leans 12 degrees forward, and more than that
    /// is positive.
    var lean: Double = 0
    var offset = CGVector.zero

    /// Where a point on the body, given as the mark draws it, ends up.
    func place(_ point: CGPoint) -> CGPoint {
        point.applying(transform)
    }

    var transform: CGAffineTransform {
        let pivot = HouseRig.pivot
        return CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
            .concatenating(CGAffineTransform(rotationAngle: lean * .pi / 180))
            .concatenating(CGAffineTransform(translationX: pivot.x + offset.dx, y: pivot.y + offset.dy))
    }
}

/// A foot on or above the floor: an ankle and three toes.
nonisolated struct HouseFoot: Equatable, Sendable {
    /// A toe, as the direction it points in degrees, where 0 is forward and 90
    /// is down, and its length.
    private struct Toe {
        var angle: Double
        var length: Double
    }

    /// Two toes forward and one back, for standing on.
    private static let spread = [Toe(angle: -14, length: 80), Toe(angle: 22, length: 92), Toe(angle: 148, length: 56)]
    /// All three hanging down, for a foot in the air.
    private static let curled = [Toe(angle: 58, length: 62), Toe(angle: 96, length: 66), Toe(angle: 150, length: 56)]

    var ankle: CGPoint
    var toes: [CGPoint]
    /// How far the toes have curled, from 0 to 1.
    var curl: Double

    /// A foot with its ankle above `x`, whose lowest toe is `lift` off the floor.
    /// A positive `pitch`, in degrees, raises the heel and a negative one
    /// raises the toes. `curl` runs from spread toes at 0 to curled ones at 1.
    init(x: CGFloat, lift: CGFloat = 0, pitch: Double, curl: Double = 0) {
        let toes = zip(Self.spread, Self.curled).map { spread, curled in
            Toe(
                angle: Tween.mix(spread.angle, curled.angle, curl) + pitch * (1 - curl * 0.5),
                length: Tween.mix(spread.length, curled.length, curl)
            )
        }
        let lowest = toes.map { $0.length * sin($0.angle * .pi / 180) }.max() ?? 0
        let ankle = CGPoint(x: x, y: HouseRig.floor - HouseRig.toeWidth / 2 - lowest - lift)
        self.ankle = ankle
        self.curl = curl
        self.toes = toes.map {
            let angle = $0.angle * .pi / 180
            return CGPoint(x: ankle.x + $0.length * cos(angle), y: ankle.y + $0.length * sin(angle))
        }
    }

    init(ankle: CGPoint, toes: [CGPoint]) {
        self.ankle = ankle
        self.toes = toes
        self.curl = 0
    }
}

/// A chicken's leg: the knee bends forward, the hock bends back, and the foot
/// hangs off the ankle.
nonisolated struct HouseLeg: Equatable, Sendable {
    var hip: CGPoint
    var knee: CGPoint
    var hock: CGPoint
    var ankle: CGPoint
    var toes: [CGPoint]

    /// A leg from `hip` to `foot`. The leg folds into a zigzag when the foot is
    /// closer to the hip than `length`, and `fold` says how deep that zigzag is.
    /// It's straight when the foot is `length` away or further.
    init(hip: CGPoint, foot: HouseFoot, length: CGFloat, fold: CGFloat) {
        let ankle = foot.ankle
        let reach = CGVector(dx: ankle.x - hip.x, dy: ankle.y - hip.y)
        let distance = (reach.dx * reach.dx + reach.dy * reach.dy).squareRoot()
        let along = CGVector(dx: reach.dx / distance, dy: reach.dy / distance)
        let across = CGVector(dx: -along.dy, dy: along.dx)
        let depth = -fold * max(0, length * length - distance * distance).squareRoot()
        self.hip = hip
        self.knee = CGPoint(
            x: hip.x + along.dx * distance * 0.36 + across.dx * depth,
            y: hip.y + along.dy * distance * 0.36 + across.dy * depth
        )
        self.hock = CGPoint(
            x: hip.x + along.dx * distance * 0.7 - across.dx * depth * 0.85,
            y: hip.y + along.dy * distance * 0.7 - across.dy * depth * 0.85
        )
        self.ankle = ankle
        self.toes = foot.toes
    }

    /// A leg with its joints placed by hand.
    init(hip: CGPoint, knee: CGPoint, hock: CGPoint, foot: HouseFoot) {
        self.hip = hip
        self.knee = knee
        self.hock = hock
        self.ankle = foot.ankle
        self.toes = foot.toes
    }

    /// Every joint and toe tip.
    var points: [CGPoint] {
        [hip, knee, hock, ankle] + toes
    }

    func applying(_ transform: CGAffineTransform) -> HouseLeg {
        var leg = self
        leg.hip = hip.applying(transform)
        leg.knee = knee.applying(transform)
        leg.hock = hock.applying(transform)
        leg.ankle = ankle.applying(transform)
        leg.toes = toes.map { $0.applying(transform) }
        return leg
    }
}

/// The whole house at one moment.
nonisolated struct HousePose: Equatable, Sendable {
    var body: HouseBody
    /// The leg further back, which is drawn first and darker, so that the two
    /// stay apart where they overlap.
    var rearLeg: HouseLeg
    var frontLeg: HouseLeg
    /// How far the floor has moved under the house so far, where positive is to
    /// the right. A foot that's down moves with the floor, so it doesn't skate.
    var floorTravel: CGFloat = 0

    /// The stride the mark is drawn in, as joints, which is a starting point for
    /// an animation that starts from the logo.
    static let mark = HousePose(
        body: HouseBody(),
        rearLeg: HouseLeg(
            hip: CGPoint(x: 552, y: 470),
            knee: CGPoint(x: 495, y: 541),
            hock: CGPoint(x: 423, y: 497),
            foot: HouseFoot(
                ankle: CGPoint(x: 392, y: 548),
                toes: [CGPoint(x: 380, y: 605), CGPoint(x: 342, y: 572), CGPoint(x: 350, y: 520)]
            )
        ),
        frontLeg: HouseLeg(
            hip: CGPoint(x: 680, y: 480),
            knee: CGPoint(x: 706, y: 548),
            hock: CGPoint(x: 728, y: 590),
            foot: HouseFoot(
                ankle: CGPoint(x: 742, y: 632),
                toes: [CGPoint(x: 825, y: 607), CGPoint(x: 838, y: 668), CGPoint(x: 690, y: 668)]
            )
        )
    )

    /// This pose with the whole house moved as one piece, rather than joint by
    /// joint.
    func applying(_ transform: CGAffineTransform) -> HousePose {
        var pose = self
        let pivot = HouseRig.pivot
        let placed = body.place(pivot).applying(transform)
        pose.body.lean += atan2(transform.b, transform.a) * 180 / .pi
        pose.body.offset = CGVector(dx: placed.x - pivot.x, dy: placed.y - pivot.y)
        pose.rearLeg = rearLeg.applying(transform)
        pose.frontLeg = frontLeg.applying(transform)
        return pose
    }
}

/// How values get from one to another.
nonisolated enum Tween {
    /// `start` at 0, `end` at 1, and in a straight line between.
    static func mix(_ start: Double, _ end: Double, _ amount: Double) -> Double {
        start + (end - start) * amount
    }

    /// From 0 to 1, leaving and arriving gently.
    static func smooth(_ amount: Double) -> Double {
        amount * amount * (3 - 2 * amount)
    }

    /// Up to 1 and back to 0 again as `amount` goes from 0 to 1.
    static func arc(_ amount: Double) -> Double {
        sin(.pi * amount)
    }

    /// `start` at 0, `middle` at 0.5 and `end` at 1, leaving and arriving gently
    /// each time.
    static func through(_ start: Double, _ middle: Double, _ end: Double, _ amount: Double) -> Double {
        amount < 0.5
            ? mix(start, middle, smooth(amount * 2))
            : mix(middle, end, smooth(amount * 2 - 1))
    }
}
