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
    /// How the house moves while git does this (decision 21). Only pushing and
    /// pulling have a direction to show.
    var houseAnimation: HouseAnimation {
        switch self {
        case .pushing, .forcePushing: .push
        case .pulling: .heave
        case .fetching, .undoingPull: .waddle
        }
    }

    /// How long the house takes to play once at the speed in Settings. Someone
    /// who asked for less motion sees a still pose, so there's nothing to wait
    /// for.
    var timeToPlayHouse: Duration {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return .zero }
        return houseAnimation.timeToPlay(atSpeed: HouseAnimationView.clamped(UserDefaults.standard.houseAnimationSpeed))
    }
}

/// One of the house's animations, running for as long as the view is on screen,
/// at the speed in Settings. It stands still for someone who asked for less
/// motion.
struct HouseAnimationView: View {
    /// The speeds Settings offers, as multiples of normal speed.
    static let speeds = 0.25 ... 3.0

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
                : clock.time(at: timeline.date, speed: Self.clamped(speed))
            HouseFigure(pose: motion.pose(at: time), color: color)
        }
        .frame(width: height * HouseRig.frame.width / HouseRig.frame.height, height: height)
        .accessibilityHidden(true)
        .onChange(of: Self.clamped(speed)) { oldSpeed, _ in
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

/// The setting for how fast the house moves, with every animation running above
/// it, so that the change shows while the slider moves.
struct HouseAnimationSettings: View {
    @AppStorage(UserDefaults.houseAnimationSpeedKey) private var speed = 1.0

    var body: some View {
        Section {
            HStack(spacing: 0) {
                ForEach(HouseAnimation.allCases) { animation in
                    VStack(spacing: 4) {
                        HouseAnimationView(animation: animation, height: 44)
                        Text(animation.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 2)
            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: $speed, in: HouseAnimationView.speeds, step: 0.25)
                        .labelsHidden()
                    Text("\(speed.formatted())×")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            } label: {
                Text("Animation speed")
                Text("How fast the house moves while git runs.")
            }
        }
    }
}
