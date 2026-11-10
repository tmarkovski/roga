import IconUI
import SwiftUI

/// A window for looking at the house's animations up close: each one large, with
/// its joints if you want them, and at the sizes it runs at. It starts at the
/// speed the app plays it at but keeps its own after that, so that slowing an
/// animation down to look at it doesn't slow down the app.
public struct HouseAnimationDemo: View {
    /// The sizes the small versions are drawn at, in points.
    private static let sizes: [CGFloat] = [18, 22, 28]

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var isPlaying = true
    @State private var speed: Double
    @State private var showsJoints = false
    @State private var clocks: [HouseAnimation: HouseClock]

    public init() {
        _speed = State(initialValue: HouseAnimationView.playingSpeed(UserDefaults.standard.houseAnimationSpeed))
        _clocks = State(initialValue: Dictionary(uniqueKeysWithValues: HouseAnimation.allCases.map { animation in
            let motion = animation.motion
            return (animation, HouseClock(startDate: .now, startTime: motion.startPhase * motion.duration))
        }))
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isPlaying)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    controls(at: timeline.date)
                    stages(at: timeline.date)
                    sizes(at: timeline.date)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            if reducesMotion {
                setPlaying(false)
            }
        }
    }

    // MARK: Controls

    private func controls(at date: Date) -> some View {
        HStack(spacing: 20) {
            Button {
                setPlaying(!isPlaying)
            } label: {
                Label(isPlaying ? "Pause" : "Play", icon: isPlaying ? .pause : .play)
                    .frame(width: 64, alignment: .leading)
            }
            .keyboardShortcut(.space, modifiers: [])

            HStack(spacing: 8) {
                Text("Speed")
                Slider(value: speedBinding, in: HouseAnimationView.speeds, step: 0.25)
                    .labelsHidden()
                    .frame(width: 160)
                Text("\(speed.formatted())×")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("Frame")
                Slider(value: frameBinding(at: date), in: 0 ... 1)
                    .labelsHidden()
            }

            Toggle("Show the Joints", isOn: $showsJoints)
                .fixedSize()
        }
    }

    /// How fast time passes in the animations right now.
    private var runningSpeed: Double {
        isPlaying ? speed : 0
    }

    private func setPlaying(_ playing: Bool) {
        settleClocks()
        isPlaying = playing
    }

    /// Call this before `runningSpeed` changes, so that the animations carry on
    /// from the same pose.
    private func settleClocks() {
        let now = Date.now
        for animation in clocks.keys {
            clocks[animation]?.rebase(at: now, speed: runningSpeed)
        }
    }

    private var speedBinding: Binding<Double> {
        Binding {
            speed
        } set: { newSpeed in
            settleClocks()
            speed = newSpeed
        }
    }

    /// How far through its cycle each animation is. They have different lengths,
    /// so while they play the slider follows the longest, and moving it puts all
    /// of them at the same point in their own cycles.
    private func frameBinding(at date: Date) -> Binding<Double> {
        Binding {
            let longest = HouseAnimation.allCases.max { $0.motion.duration < $1.motion.duration } ?? .heave
            return longest.motion.cycle(at: time(of: longest, at: date)).phase
        } set: { phase in
            isPlaying = false
            let now = Date.now
            for animation in HouseAnimation.allCases {
                let duration = animation.motion.duration
                clocks[animation] = HouseClock(startDate: now, startTime: min(phase, 0.999) * duration)
            }
        }
    }

    private func time(of animation: HouseAnimation, at date: Date) -> TimeInterval {
        clocks[animation]?.time(at: date, speed: runningSpeed) ?? 0
    }

    private func pose(of animation: HouseAnimation, at date: Date) -> HousePose {
        animation.motion.pose(at: time(of: animation, at: date))
    }

    // MARK: The animations

    private func stages(at date: Date) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: HouseAnimation.allCases.count), spacing: 12) {
            ForEach(HouseAnimation.allCases) { animation in
                VStack(alignment: .leading, spacing: 4) {
                    Text(animation.title)
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    HouseStage(pose: pose(of: animation, at: date), showsJoints: showsJoints)
                        .accessibilityLabel(animation.title)
                }
                .background(Palette.surface, in: .rect(cornerRadius: 10))
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.separator))
            }
        }
    }

    private func sizes(at date: Date) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
            GridRow {
                Text("At the sizes it runs at")
                    .font(.headline)
                ForEach(Self.sizes, id: \.self) { size in
                    Text("\(size.formatted()) pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(HouseAnimation.allCases) { animation in
                GridRow(alignment: .center) {
                    Text(animation.title)
                        .foregroundStyle(.secondary)
                    ForEach(Self.sizes, id: \.self) { size in
                        HouseFigure(pose: pose(of: animation, at: date))
                            .frame(width: size * HouseRig.frame.width / HouseRig.frame.height, height: size)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }
}

/// One animation drawn large, on a floor that moves with the feet, and with its
/// joints on top if they're wanted.
private struct HouseStage: View {
    /// The house's own frame, with room below it for the floor.
    private static let frame = CGRect(x: 278, y: 128, width: 640, height: 600)
    private static let floorPattern: [CGFloat] = [46, 110]

    let pose: HousePose
    let showsJoints: Bool

    var body: some View {
        Canvas { context, size in
            let frame = Self.frame
            let scale = min(size.width / frame.width, size.height / frame.height)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -frame.minX, y: -frame.minY)

            drawFloor(in: context)
            var figure = context
            figure.opacity = showsJoints ? 0.55 : 1
            HouseFigure.draw(pose, color: Palette.action, thickness: 1, in: figure)
            if showsJoints {
                drawJoints(of: pose.rearLeg, in: context)
                drawJoints(of: pose.frontLeg, in: context)
            }
        }
        .aspectRatio(Self.frame.width / Self.frame.height, contentMode: .fit)
    }

    private func drawFloor(in context: GraphicsContext) {
        let frame = Self.frame
        var line = Path()
        line.move(to: CGPoint(x: frame.minX, y: HouseRig.floor + 2))
        line.addLine(to: CGPoint(x: frame.maxX, y: HouseRig.floor + 2))
        context.stroke(line, with: .color(.secondary), lineWidth: 3)

        // Marks on the floor, so that it can be seen to move. A pattern starts
        // further along when its phase grows, which moves it to the left.
        var marks = Path()
        marks.move(to: CGPoint(x: frame.minX, y: HouseRig.floor + 22))
        marks.addLine(to: CGPoint(x: frame.maxX, y: HouseRig.floor + 22))
        let period = Self.floorPattern.reduce(0, +)
        let phase = (-pose.floorTravel).truncatingRemainder(dividingBy: period)
        context.stroke(
            marks,
            with: .color(.secondary),
            style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: Self.floorPattern, dashPhase: phase < 0 ? phase + period : phase)
        )
    }

    private func drawJoints(of leg: HouseLeg, in context: GraphicsContext) {
        var bones = Path()
        bones.addLines([leg.hip, leg.knee, leg.hock, leg.ankle])
        for toe in leg.toes {
            bones.move(to: leg.ankle)
            bones.addLine(to: toe)
        }
        context.stroke(bones, with: .color(.primary), lineWidth: 4)

        for joint in [leg.hip, leg.knee, leg.hock, leg.ankle] {
            let circle = Path(ellipseIn: CGRect(x: joint.x - 10, y: joint.y - 10, width: 20, height: 20))
            context.fill(circle, with: .color(Palette.surface))
            context.stroke(circle, with: .color(.primary), lineWidth: 4)
        }
    }
}
