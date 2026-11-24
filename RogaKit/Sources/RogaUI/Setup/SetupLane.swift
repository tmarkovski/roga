import HistoryUI
import SwiftUI

/// Setup's floor, drawn as one lane of a commit graph in history's style
/// (decision 69): a commit for each screen, from Welcome's Initial commit to
/// Ready's Open Roga, each with its screen's small title under it as its
/// subject. The house stands on the commit setup is at, which has history's
/// ring for `HEAD`. Commits that are done are solid, and those still to come
/// are hollow, past a faint stretch of the lane.
///
/// A step answered No is skipped rather than taken off the lane, so the six
/// commits never move: a bypass leaves the commit before it, runs on a lane of
/// its own above, and comes down into the next commit setup took, as a branch
/// goes around commits in history. The skipped commits stay hollow on a faint
/// stretch under it.
///
/// Every commit before `HEAD`, skipped or not, is a button that goes back to
/// its screen, as Back does. It's pinned along the bottom of the window, under
/// the screen, which scrolls above it when it's too tall.
struct SetupLane: View {
    let current: SetupModel.Step
    let skipped: Set<SetupModel.Step>
    /// Whether the commits behind `HEAD` can be clicked, which they can't
    /// while something runs that Back waits for too.
    var isEnabled = true
    let go: (SetupModel.Step) -> Void

    @State private var hovered: SetupModel.Step?
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    static let steps = SetupModel.Step.allCases
    /// How tall the house is on the lane.
    static let houseHeight: CGFloat = 46
    /// How far the lane is from the bottom of the window, which leaves room
    /// for the subjects under it.
    static let fromBottom: CGFloat = 44
    /// How much of the window the lane takes, with the house standing on it.
    static let height = houseHeight + fromBottom
    /// How far from each edge of the window the first and last commits are,
    /// to the house's side when it stands on them.
    private static let inset: CGFloat = 64
    /// How far above the lane a bypass runs, and how far along it takes to get
    /// up there and down again.
    static let bypassRise: CGFloat = 22
    private static let bypassTurn: CGFloat = 40

    /// Where the commit of `step` is across a window this wide, which is the
    /// middle of the house when it stands there.
    static func x(of step: SetupModel.Step, width: CGFloat) -> CGFloat {
        let index = CGFloat(steps.firstIndex(of: step) ?? 0)
        let house = SetupHouseSpot(foot: .zero, height: houseHeight).width
        let room = max(0, width - 2 * inset - house)
        return inset + room * index / CGFloat(steps.count - 1) + house / 2
    }

    /// How far along the lane `step` is, from 0 to 1.
    static func position(of step: SetupModel.Step) -> Double {
        Double(steps.firstIndex(of: step) ?? 0) / Double(steps.count - 1)
    }

    /// Where the house stands on the commit of `step`, in a window this size.
    static func spot(at step: SetupModel.Step, in size: CGSize) -> SetupHouseSpot {
        SetupHouseSpot(foot: CGPoint(x: x(of: step, width: size.width), y: size.height - fromBottom), height: houseHeight)
    }

    /// The commits a bypass joins: the last one taken before the skipped
    /// ones, and the next one taken after them.
    static func bypass(around skipped: Set<SetupModel.Step>) -> (from: SetupModel.Step, to: SetupModel.Step)? {
        let indices = skipped.compactMap { steps.firstIndex(of: $0) }
        guard let first = indices.min(), let last = indices.max(), first > 0, last + 1 < steps.count else { return nil }
        return (steps[first - 1], steps[last + 1])
    }

    /// A bypass across a lane at `y`, as history draws a branch: it leaves the
    /// first commit sideways, rises to a lane of its own, runs along it, and
    /// comes down into the second.
    static func bypassPath(from start: CGFloat, to end: CGFloat, y: CGFloat) -> Path {
        let top = y - bypassRise
        let turn = min(bypassTurn, (end - start) / 4)
        var path = Path()
        path.move(to: CGPoint(x: start, y: y))
        path.addCurve(to: CGPoint(x: start + 2 * turn, y: top), control1: CGPoint(x: start + turn, y: y), control2: CGPoint(x: start + turn, y: top))
        path.addLine(to: CGPoint(x: end - 2 * turn, y: top))
        path.addCurve(to: CGPoint(x: end, y: y), control1: CGPoint(x: end - turn, y: top), control2: CGPoint(x: end - turn, y: y))
        return path
    }

    private enum Kind {
        case done
        case head
        case skipped
        case ahead
    }

    /// The stretches of the lane, solid where setup went and faint where
    /// it hasn't or went around.
    private func segments(width: CGFloat, bypass: (from: SetupModel.Step, to: SetupModel.Step)?) -> [LaneSegment] {
        func x(_ step: SetupModel.Step) -> CGFloat { Self.x(of: step, width: width) }
        var segments: [LaneSegment] = []
        func add(_ from: SetupModel.Step, _ to: SetupModel.Step, faint: Bool) {
            if from < to { segments.append(LaneSegment(from: x(from), to: x(to), isFaint: faint)) }
        }
        let first = Self.steps[0]
        let last = Self.steps[Self.steps.count - 1]
        if let bypass {
            add(first, min(bypass.from, current), faint: false)
            add(bypass.from, bypass.to, faint: true)
            add(bypass.to, current, faint: false)
        } else {
            add(first, current, faint: false)
        }
        add(current, last, faint: true)
        return segments
    }

    private func look(of kind: Kind) -> LaneDot.Look {
        switch kind {
        case .done: .solid
        case .head: .head
        case .skipped, .ahead: .hollow
        }
    }

    private func kind(of step: SetupModel.Step) -> Kind {
        if step == current { return .head }
        if skipped.contains(step) { return .skipped }
        return step < current ? .done : .ahead
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let y = Self.houseHeight
            let lane = Color(nsColor: GitColors.lanes[0])
            let head = Color(nsColor: GitColors.current)
            let hover = Palette.buttonHover
            let surface = SetupColors.surface
            let bypass = Self.bypass(around: skipped)
            let segments = segments(width: width, bypass: bypass)
            let dots = Self.steps.map { step in
                LaneDot(x: Self.x(of: step, width: width), look: look(of: kind(of: step)), isHovered: hovered == step)
            }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for segment in segments {
                        var line = Path()
                        line.move(to: CGPoint(x: segment.from, y: y))
                        line.addLine(to: CGPoint(x: segment.to, y: y))
                        let style = segment.isFaint
                            ? StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 6])
                            : StrokeStyle(lineWidth: 2, lineCap: .round)
                        context.stroke(line, with: .color(segment.isFaint ? lane.opacity(0.3) : lane), style: style)
                    }
                    for dot in dots {
                        func circle(_ radius: CGFloat) -> Path {
                            Path(ellipseIn: CGRect(x: dot.x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                        }
                        if dot.isHovered {
                            context.fill(circle(11), with: .color(hover))
                        }
                        switch dot.look {
                        case .solid:
                            context.fill(circle(dot.isHovered ? 5.5 : 4), with: .color(lane))
                        case .head:
                            context.stroke(circle(8), with: .color(head), lineWidth: 2)
                            context.fill(circle(4), with: .color(lane))
                        case .hollow:
                            context.fill(circle(3.5), with: .color(surface))
                            context.stroke(circle(3.5), with: .color(lane.opacity(0.45)), lineWidth: 1.5)
                        }
                    }
                }
                if let bypass {
                    SetupBypass(
                        path: Self.bypassPath(from: Self.x(of: bypass.from, width: width), to: Self.x(of: bypass.to, width: width), y: y),
                        color: lane,
                        reducesMotion: reducesMotion
                    )
                    .id("\(bypass.from)-\(bypass.to)")
                }
                ForEach(Self.steps, id: \.self) { step in
                    commit(step)
                        .position(x: Self.x(of: step, width: width), y: y + 13)
                }
            }
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup steps")
    }

    /// A commit's subject, under its dot. One behind `HEAD` is a button,
    /// which covers its dot too.
    @ViewBuilder private func commit(_ step: SetupModel.Step) -> some View {
        let kind = kind(of: step)
        let words = Text(step.subject)
            .font(.system(size: 11.5, weight: kind == .head ? .semibold : .regular))
            .foregroundStyle(color(for: kind))
            .underline(hovered == step, color: SetupColors.unavailable)
            .lineLimit(1)
            .fixedSize()
        let label = VStack(spacing: 4) {
            // The dot's place, so that the pointer over the dot counts.
            Color.clear.frame(width: 24, height: 14)
            words
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        switch kind {
        case .done, .skipped:
            Button {
                hovered = nil
                go(step)
            } label: {
                label
            }
            .buttonStyle(SetupLaneCommitStyle())
            .disabled(!isEnabled)
            .onHover { hovered = $0 && isEnabled ? step : (hovered == step ? nil : hovered) }
            .help("Back to \(step.subject)")
            .accessibilityLabel(step.subject)
            .accessibilityValue(kind == .skipped ? "Skipped" : "Done")
            .accessibilityHint("Goes back to this step")
        case .head, .ahead:
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(step.subject)
                .accessibilityValue(kind == .head ? "Current step" : "Not yet")
                .accessibilityAddTraits(kind == .head ? [.isStaticText, .isSelected] : .isStaticText)
        }
    }

    private func color(for kind: Kind) -> Color {
        switch kind {
        case .head: .primary
        case .done: SetupColors.note
        case .skipped, .ahead: SetupColors.unavailable
        }
    }
}

/// A stretch of the lane between two commits, as the canvas draws it.
private nonisolated struct LaneSegment: Sendable {
    var from: CGFloat
    var to: CGFloat
    var isFaint: Bool
}

/// A commit's dot, as the canvas draws it.
private nonisolated struct LaneDot: Sendable {
    enum Look: Sendable {
        /// Done.
        case solid
        /// Where setup is, with `HEAD`'s ring.
        case head
        /// Still to come, or skipped.
        case hollow
    }

    var x: CGFloat
    var look: Look
    var isHovered: Bool
}

/// A bypass over skipped steps, which draws itself in from the commit it
/// leaves when it first shows, or fades in for someone who asked for less
/// motion.
private struct SetupBypass: View {
    let path: Path
    let color: Color
    let reducesMotion: Bool
    @State private var drawn: CGFloat = 0

    var body: some View {
        path
            .trim(from: 0, to: reducesMotion ? 1 : drawn)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .opacity(reducesMotion ? drawn : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.easeOut(duration: reducesMotion ? 0.2 : 0.45)) { drawn = 1 }
            }
    }
}

/// A commit behind `HEAD` as a button, which only dims while it's pressed.
private struct SetupLaneCommitStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
