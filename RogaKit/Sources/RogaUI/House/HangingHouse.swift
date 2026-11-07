import SwiftUI

/// The house hanging by a thread tied to its chimney, with its legs spread,
/// which drops through the Fetch button while a fetch runs (decision 57). It
/// holds still on the way down, so it's one pose rather than a `HouseMotion`.
/// Everything is in the coordinates of the mark, as in `HouseRig`.
nonisolated enum HangingHouse {
    /// Where the thread is tied, on top of the chimney, as the mark draws it.
    static let chimneyTop = CGPoint(x: 772, y: 178)
    /// How far the body turns from the mark, in degrees. The chimney is off to
    /// one side, so hanging from it tips the roof back until the middle of the
    /// house is under the thread.
    static let lean: Double = -30
    /// How far each leg spreads from straight down, in degrees.
    static let spread: Double = 34
    static let legLength: CGFloat = 230
    /// How far the knee bends forward and the hock bends back, which is only
    /// enough to keep them a chicken's legs.
    static let bend: CGFloat = 6
    /// How far the toes fan out from the middle one, in degrees, and how long
    /// the middle one is.
    static let toeFan: Double = 40
    static let toeLength: CGFloat = 78
    /// The thread rises this far above the chimney and fades out on the way, so
    /// that it seems to go on up out of sight.
    static let threadLength: CGFloat = 300
    static let threadWidth: CGFloat = 32

    static let pose: HousePose = {
        let body = HouseBody(lean: lean)
        return HousePose(
            body: body,
            rearLeg: leg(from: body.place(HouseRig.rearHip), outward: -1),
            frontLeg: leg(from: body.place(HouseRig.frontHip), outward: 1)
        )
    }()

    /// Where the thread is tied, once the body has turned.
    static var knot: CGPoint {
        pose.body.place(chimneyTop)
    }

    /// The thread, from above the house down into the top of its chimney, where
    /// the body covers its end.
    static var thread: CGRect {
        CGRect(x: knot.x - threadWidth / 2, y: knot.y - threadLength, width: threadWidth, height: threadLength + threadWidth)
    }

    /// What the house covers, from its chimney to its toes, with its legs drawn
    /// this much thicker. It leaves out the thread.
    static func frame(thickness: CGFloat) -> CGRect {
        let body = HouseOutline.body.applying(pose.body.transform).cgPath.boundingBoxOfPath
        return [pose.rearLeg, pose.frontLeg].reduce(body) { frame, leg in
            let joints = [leg.hip, leg.knee, leg.hock, leg.ankle].map { around($0, width: HouseRig.legWidth * thickness) }
            let toes = leg.toes.map { around($0, width: HouseRig.toeWidth * thickness) }
            return (joints + toes).reduce(frame) { $0.union($1) }
        }
    }

    /// A leg hanging from `hip`, spread toward the back of the house when
    /// `outward` is -1 and toward the front when it's 1, with its toes fanned
    /// out around the way it points.
    private static func leg(from hip: CGPoint, outward: Double) -> HouseLeg {
        // In degrees, where 0 is forward and 90 is down, as for `HouseFoot`.
        let pointing = 90 - outward * spread
        let angle = pointing * .pi / 180
        let along = CGVector(dx: cos(angle), dy: sin(angle))
        // Square to the leg, toward the front of the house.
        let forward = CGVector(dx: sin(angle), dy: -cos(angle))
        func point(_ share: CGFloat, aside: CGFloat) -> CGPoint {
            CGPoint(
                x: hip.x + along.dx * legLength * share + forward.dx * aside,
                y: hip.y + along.dy * legLength * share + forward.dy * aside
            )
        }
        let ankle = point(1, aside: 0)
        // The toe nearest the other leg, the middle one, and the outer one.
        let toes: [(turn: Double, length: CGFloat)] = [(-toeFan, toeLength), (0, toeLength * 1.1), (toeFan, toeLength * 0.8)]
        let foot = HouseFoot(ankle: ankle, toes: toes.map { toe in
            let angle = (pointing - toe.turn * outward) * .pi / 180
            return CGPoint(x: ankle.x + toe.length * cos(angle), y: ankle.y + toe.length * sin(angle))
        })
        return HouseLeg(hip: hip, knee: point(0.36, aside: bend), hock: point(0.7, aside: -bend * 0.85), foot: foot)
    }

    private static func around(_ point: CGPoint, width: CGFloat) -> CGRect {
        CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width)
    }
}

/// The hanging house, `height` points from its chimney to its toes, with the
/// thread rising out of the chimney in the color of the icons around it. The
/// thread takes no room, so the view lines up by the house alone, and it's
/// placed so that the thread runs down the view's middle.
struct HangingHouseFigure: View {
    let height: CGFloat
    var color = Palette.action

    var body: some View {
        let thickness = HouseFigure.thickness(forHeight: height)
        let house = HangingHouse.frame(thickness: thickness)
        let drawn = house.union(HangingHouse.thread)
        let scale = height / house.height
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -drawn.minX, y: -drawn.minY)
            Self.drawThread(in: context)
            HouseFigure.draw(HangingHouse.pose, color: color, thickness: thickness, in: context)
        }
        .frame(width: drawn.width * scale, height: drawn.height * scale)
        .padding(.top, (drawn.minY - house.minY) * scale)
        .offset(x: (drawn.midX - HangingHouse.knot.x) * scale)
        .accessibilityHidden(true)
    }

    /// Solid where it meets the chimney, and gone by its top end.
    private static func drawThread(in context: GraphicsContext) {
        let thread = HangingHouse.thread
        var context = context
        context.clipToLayer { mask in
            mask.fill(
                Path(thread),
                with: .linearGradient(
                    Gradient(stops: [.init(color: .black, location: 0.4), .init(color: .clear, location: 1)]),
                    startPoint: CGPoint(x: thread.midX, y: thread.maxY),
                    endPoint: CGPoint(x: thread.midX, y: thread.minY)
                )
            )
        }
        context.fill(Path(roundedRect: thread, cornerRadius: thread.width / 2), with: .foreground)
    }
}
