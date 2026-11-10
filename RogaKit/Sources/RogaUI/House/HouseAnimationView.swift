import AppKit
import SwiftUI

extension UserDefaults {
    static let houseAnimationSpeedKey = "houseAnimationSpeed"

    /// How fast the house moves, as a multiple of normal speed. This reads the
    /// value the way `@AppStorage` does, so that the two can't disagree.
    var houseAnimationSpeed: Double {
        object(forKey: Self.houseAnimationSpeedKey) == nil ? 1 : double(forKey: Self.houseAnimationSpeedKey)
    }
}

extension BranchModel.Action {
    /// How the house moves while git does this (decision 21), or nil for a fetch,
    /// which shows only its words (decision 26). Only pushing and pulling have a
    /// direction to show.
    var houseAnimation: HouseAnimation? {
        switch self {
        case .pushing, .forcePushing, .deletingFromRemote: .push
        case .pulling: .heave
        case .undoing, .aborting, .continuingRebase: .waddle
        case .fetching, .committing, .reverting, .merging, .fastForwarding, .rebasing, .cherryPicking: nil
        }
    }

    /// How long the house takes to play once at the speed it plays at. With no
    /// house, or for someone who asked for less motion and sees a still pose,
    /// there's nothing to wait for.
    var timeToPlayHouse: Duration {
        guard let houseAnimation, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return .zero }
        return houseAnimation.timeToPlay(atSpeed: HouseAnimationView.playingSpeed(UserDefaults.standard.houseAnimationSpeed))
    }
}

/// One of the house's animations, running for as long as the view is on screen,
/// at the speed in Settings. It stands still for someone who asked for less
/// motion.
struct HouseAnimationView: View {
    /// The speeds Settings offers, as multiples of normal speed.
    static let speeds = 0.25 ... 3.0

    /// Whether Settings offers the speed, under Motion on its Appearance page,
    /// with the house's animations to look at above it. It doesn't for now,
    /// so the house plays at normal speed whatever was saved, and a saved
    /// speed stays in the defaults for when it's offered again.
    static let offersSpeed = false

    let animation: HouseAnimation
    let height: CGFloat
    let color: Color

    @AppStorage(UserDefaults.houseAnimationSpeedKey) private var speed = 1.0
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var clock: HouseClock

    init(animation: HouseAnimation, height: CGFloat = 18, color: Color = Palette.action) {
        self.animation = animation
        self.height = height
        self.color = color
        let motion = animation.motion
        _clock = State(initialValue: HouseClock(startDate: .now, startTime: motion.startPhase * motion.duration))
    }

    var body: some View {
        let motion = animation.motion
        TimelineView(.animation(minimumInterval: 1 / framesPerSecond, paused: reducesMotion)) { timeline in
            let time = reducesMotion
                ? motion.stillPhase * motion.duration
                : clock.time(at: timeline.date, speed: Self.playingSpeed(speed))
            HouseFigure(pose: motion.pose(at: time), color: color)
        }
        .frame(width: height * HouseRig.frame.width / HouseRig.frame.height, height: height)
        .accessibilityHidden(true)
        .onChange(of: Self.playingSpeed(speed)) { oldSpeed, _ in
            clock.rebase(at: .now, speed: oldSpeed)
        }
    }

    /// At the size of the title row, most frames at 60 a second would barely
    /// change a pixel, and drawing half as many costs about a third less.
    private var framesPerSecond: Double {
        height < 28 ? 30 : 60
    }

    /// A stored speed, in case something else wrote a value Settings wouldn't.
    static func clamped(_ speed: Double) -> Double {
        min(max(speed, speeds.lowerBound), speeds.upperBound)
    }

    /// The speed the house plays at, from the stored one: that one while
    /// Settings offers it, and normal speed while it doesn't.
    static func playingSpeed(_ stored: Double) -> Double {
        offersSpeed ? clamped(stored) : 1
    }
}

/// Turns the time on the wall into time in an animation, so that changing the
/// speed carries on from the same pose rather than jumping to another.
nonisolated struct HouseClock: Equatable {
    private(set) var startDate: Date
    private(set) var startTime: TimeInterval

    init(startDate: Date, startTime: TimeInterval) {
        self.startDate = startDate
        self.startTime = startTime
    }

    func time(at date: Date, speed: Double) -> TimeInterval {
        startTime + date.timeIntervalSince(startDate) * speed
    }

    /// Call this with the old speed before the speed changes.
    mutating func rebase(at date: Date, speed: Double) {
        startTime = time(at: date, speed: speed)
        startDate = date
    }
}

/// The house in one pose.
struct HouseFigure: View {
    let pose: HousePose
    var color = Palette.action

    var body: some View {
        Canvas { context, size in
            let frame = HouseRig.frame
            let scale = min(size.width / frame.width, size.height / frame.height)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -frame.minX, y: -frame.minY)

            Self.draw(pose, color: color, thickness: Self.thickness(forHeight: size.height), in: context)
        }
    }

    /// Draws a pose in the coordinates of the mark.
    static func draw(_ pose: HousePose, color: Color, thickness: CGFloat, in context: GraphicsContext) {
        draw(pose.rearLeg, in: context, with: .color(color.mix(with: .black, by: 0.3)), thickness: thickness)
        draw(pose.frontLeg, in: context, with: .color(color), thickness: thickness)
        context.fill(
            HouseOutline.body.applying(pose.body.transform),
            with: .color(color),
            style: FillStyle(eoFill: true)
        )
    }

    /// How much thicker to draw the legs. At the size of the title row they'd
    /// otherwise be about a point wide and disappear.
    static func thickness(forHeight height: CGFloat) -> CGFloat {
        height < 28 ? 1.32 : 1
    }

    private static func draw(_ leg: HouseLeg, in context: GraphicsContext, with shading: GraphicsContext.Shading, thickness: CGFloat) {
        var bones = Path()
        bones.addLines([leg.hip, leg.knee, leg.hock, leg.ankle])
        context.stroke(bones, with: shading, style: StrokeStyle(lineWidth: HouseRig.legWidth * thickness, lineCap: .round, lineJoin: .round))

        var toes = Path()
        for toe in leg.toes {
            toes.move(to: leg.ankle)
            toes.addLine(to: toe)
        }
        context.stroke(toes, with: shading, style: StrokeStyle(lineWidth: HouseRig.toeWidth * thickness, lineCap: .round, lineJoin: .round))
    }
}
