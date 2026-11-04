import AppKit
import GitCore
import HistoryUI
import SwiftUI

/// A pull that needs someone to choose between rebasing and merging, because the
/// branch has diverged and `pull.rebase` doesn't say.
struct PullChoice: Equatable {
    var branch: String
    var upstream: String
    /// How many commits only the upstream has.
    var behind: Int
    /// How many commits only the branch has.
    var ahead: Int
    /// What's picked so far. This lives with the question rather than in the view,
    /// so that a button reads it when it's pressed: a keyboard shortcut can keep an
    /// older button's action until the button's title changes.
    var pick = Pull.rebase
    /// Whether to make that the way this repository pulls from now on.
    var remembers = false
}

/// Asks whether to rebase or merge, with a picture of what each leaves behind, and
/// shows the exact commands for what's picked (decision 29). The left and right
/// arrow keys pick, and Return runs it.
struct PullChoiceSheet: View {
    /// The question as it was asked, for while the sheet closes and it's gone.
    let asked: PullChoice
    let branch: BranchModel

    private var choice: PullChoice { branch.pullChoice ?? asked }

    var body: some View {
        DialogSheet(content: branch.dialog(for: choice)) {
            HStack(alignment: .top, spacing: 8) {
                card(.rebase, title: "Rebase", result: .rebase, key: .leftArrow)
                card(.merge, title: "Merge", result: .merge, key: .rightArrow)
            }
            .fixedSize(horizontal: false, vertical: true)
            DialogSwitchCard(switches: [
                DialogSwitch(
                    title: "Remember for this repository",
                    detail: "Sets pull.rebase in its git config, so yaga won't ask again.",
                    isOn: choice.remembers
                ) {
                    branch.pullChoice?.remembers.toggle()
                },
            ])
        }
    }

    private func card(_ option: Pull, title: String, result: PullPicture.Result, key: KeyEquivalent) -> some View {
        let isPicked = choice.pick == option
        return Button {
            branch.pullChoice?.pick = option
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                PullPicture(result: result, choice: choice)
                Text(title)
                    .fontWeight(.medium)
                Text(PullPicture.summary(of: result, yours: choice.ahead))
                    .font(.system(size: 12.5))
                    .foregroundStyle(DialogColors.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 11, trailing: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isPicked ? DialogColors.surface : DialogColors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if isPicked {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DialogColors.ink, lineWidth: 1.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

/// The graph a pull would leave behind. It shows the shape of the result rather
/// than the actual commits, which don't exist yet: up to `dotLimit` commits on a
/// side get a dot each, and past that a dotted line stands for the rest.
struct PullPicture: View {
    enum Result {
        case rebase
        case merge
    }

    /// A dot on one of the picture's two lines.
    struct Dot: Equatable {
        enum Kind: Equatable {
            /// Where the branch ends up.
            case tip
            /// One of the commits on the first line.
            case first
            /// One of the commits on the second line.
            case second
        }

        var kind: Kind
        var point: CGPoint
    }

    /// A piece of a line between dots.
    struct Stroke: Equatable {
        var from: CGPoint
        var to: CGPoint
        var isSecondLine = false
        /// Stands for more commits than it draws.
        var isDotted = false
        /// Leaves one line and joins the other.
        var isCurve = false
    }

    /// Words beside a dot.
    struct Label: Equatable {
        var text: String
        var point: CGPoint
    }

    /// Where everything goes, which doesn't depend on the view.
    struct Layout: Equatable {
        var dots: [Dot] = []
        var strokes: [Stroke] = []
        var labels: [Label] = []
    }

    let result: Result
    let choice: PullChoice

    /// The most commits on a side to draw a dot for.
    static let dotLimit = 4
    private static let height: CGFloat = 100
    private static let top: CGFloat = 12
    private static let firstLine: CGFloat = 20
    private static let secondLine: CGFloat = 44
    private static let mostSpace: CGFloat = 18

    var body: some View {
        let layout = Self.layout(of: result, choice: choice)
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for stroke in layout.strokes {
                    var path = Path()
                    path.move(to: stroke.from)
                    if stroke.isCurve {
                        let middle = (stroke.from.y + stroke.to.y) / 2
                        path.addCurve(
                            to: stroke.to,
                            control1: CGPoint(x: stroke.from.x, y: middle),
                            control2: CGPoint(x: stroke.to.x, y: middle)
                        )
                    } else {
                        path.addLine(to: stroke.to)
                    }
                    let lane = Color(nsColor: GitColors.lanes[stroke.isSecondLine ? 1 : 0])
                    let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: stroke.isDotted ? [0.1, 4.5] : [])
                    context.stroke(path, with: .color(lane), style: style)
                }
                for dot in layout.dots {
                    let radius: CGFloat = dot.kind == .tip ? 4.5 : 3.5
                    let rectangle = CGRect(x: dot.point.x - radius, y: dot.point.y - radius, width: radius * 2, height: radius * 2)
                    let color = switch dot.kind {
                    case .tip: Color(nsColor: GitColors.current)
                    case .first: Color(nsColor: GitColors.lanes[0])
                    case .second: Color(nsColor: GitColors.lanes[1])
                    }
                    context.fill(Path(ellipseIn: rectangle), with: .color(color))
                }
            }
            ForEach(Array(layout.labels.enumerated()), id: \.offset) { _, label in
                Text(verbatim: label.text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(DialogColors.note)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, label.point.x)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: label.point.y - 7)
            }
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel(Self.accessibilityDescription(of: result, choice: choice))
    }

    // MARK: What it says

    static func summary(of result: Result, yours: Int) -> String {
        switch (result, yours == 1) {
        case (.rebase, true): "A straight line, and your commit gets a new hash."
        case (.rebase, false): "A straight line, and your commits get new hashes."
        case (.merge, true): "A merge commit joins them, and your commit keeps its hash."
        case (.merge, false): "A merge commit joins them, and your commits keep their hashes."
        }
    }

    private static func accessibilityDescription(of result: Result, choice: PullChoice) -> String {
        let yours = commits(choice.ahead, "your")
        let theirs = commits(choice.behind, "their")
        return switch result {
        case .rebase: "After a rebase, one straight line, with \(yours) on top of \(theirs)."
        case .merge: "After a merge, two lines, \(yours) and \(theirs), joined by a merge commit on top."
        }
    }

    private static func commits(_ count: Int, _ whose: String) -> String {
        count == 1 ? "\(whose) commit" : "\(whose) \(count.formatted()) commits"
    }

    // MARK: Where everything goes

    /// How many dots a side gets, and whether a dotted line follows them.
    static func dots(for count: Int) -> (count: Int, isCollapsed: Bool) {
        count > dotLimit ? (1, true) : (count, false)
    }

    static func layout(of result: Result, choice: PullChoice) -> Layout {
        switch result {
        case .rebase: rebaseLayout(choice)
        case .merge: mergeLayout(choice)
        }
    }

    /// Your commits on top of theirs, on one line, and what they all started from.
    private static func rebaseLayout(_ choice: PullChoice) -> Layout {
        let yours = dots(for: choice.ahead)
        let theirs = dots(for: choice.behind)
        // A dotted stretch gets the room of two ordinary ones.
        let spaces = yours.count + (yours.isCollapsed ? 1 : 0) + theirs.count + (theirs.isCollapsed ? 1 : 0)
        let space = min(mostSpace, (height - 8 - top) / CGFloat(max(spaces, 1)))
        var layout = Layout()
        var y = top
        func add(_ kind: Dot.Kind, _ count: Int, isCollapsed: Bool) {
            for index in 0..<count {
                let next = y + space * (isCollapsed ? 2 : 1)
                layout.dots.append(Dot(kind: index == 0 && kind == .tip ? .tip : .first, point: CGPoint(x: firstLine, y: y)))
                layout.strokes.append(Stroke(from: CGPoint(x: firstLine, y: y), to: CGPoint(x: firstLine, y: next), isDotted: isCollapsed))
                y = next
            }
        }
        add(.tip, yours.count, isCollapsed: yours.isCollapsed)
        let theirTip = y
        add(.first, theirs.count, isCollapsed: theirs.isCollapsed)
        layout.dots.append(Dot(kind: .first, point: CGPoint(x: firstLine, y: y)))
        layout.strokes.append(Stroke(from: CGPoint(x: firstLine, y: y), to: CGPoint(x: firstLine, y: height)))
        layout.labels = [
            Label(text: "\(choice.branch), \(commits(choice.ahead, "your"))", point: CGPoint(x: firstLine + 14, y: top)),
            Label(text: named(choice.upstream, choice.behind), point: CGPoint(x: firstLine + 14, y: theirTip)),
        ]
        return layout
    }

    /// A merge commit on top, their commits on the second line, your commits on the
    /// first, and what they both started from.
    private static func mergeLayout(_ choice: PullChoice) -> Layout {
        let yours = dots(for: choice.ahead)
        let theirs = dots(for: choice.behind)
        // A dotted stretch of theirs has a dot at each end.
        let theirDots = theirs.isCollapsed ? 2 : theirs.count
        let spaces = 1 + (theirDots - 1) + (theirs.isCollapsed ? 1 : 0) + yours.count + (yours.isCollapsed ? 1 : 0) + 1
        let space = min(mostSpace, (height - 8 - top) / CGFloat(max(spaces, 1)))
        var layout = Layout()
        var y = top
        let merge = CGPoint(x: firstLine, y: y)
        layout.dots.append(Dot(kind: .tip, point: merge))
        y += space
        let theirTip = CGPoint(x: secondLine, y: y)
        layout.strokes.append(Stroke(from: merge, to: theirTip, isSecondLine: true, isCurve: true))
        for index in 0..<theirDots {
            let point = CGPoint(x: secondLine, y: y)
            layout.dots.append(Dot(kind: .second, point: point))
            if index < theirDots - 1 {
                let next = y + space * (theirs.isCollapsed ? 2 : 1)
                layout.strokes.append(Stroke(from: point, to: CGPoint(x: secondLine, y: next), isSecondLine: true, isDotted: theirs.isCollapsed))
                y = next
            }
        }
        let theirEnd = CGPoint(x: secondLine, y: y)
        y += space
        let yourTip = y
        var previous = merge
        for _ in 0..<yours.count {
            let point = CGPoint(x: firstLine, y: y)
            layout.strokes.append(Stroke(from: previous, to: point))
            layout.dots.append(Dot(kind: .first, point: point))
            previous = point
            y += space * (yours.isCollapsed ? 2 : 1)
        }
        let base = CGPoint(x: firstLine, y: y)
        layout.strokes.append(Stroke(from: previous, to: base, isDotted: yours.isCollapsed))
        layout.strokes.append(Stroke(from: theirEnd, to: base, isSecondLine: true, isCurve: true))
        layout.strokes.append(Stroke(from: base, to: CGPoint(x: firstLine, y: height)))
        layout.dots.append(Dot(kind: .first, point: base))
        layout.labels = [
            Label(text: "\(choice.branch), merge commit", point: CGPoint(x: firstLine + 14, y: top)),
            Label(text: choice.upstream, point: CGPoint(x: secondLine + 12, y: theirTip.y)),
        ]
        if theirs.isCollapsed {
            let middle = (theirTip.y + theirEnd.y) / 2
            layout.labels.append(Label(text: commits(choice.behind, "their"), point: CGPoint(x: secondLine + 12, y: middle)))
        }
        layout.labels.append(Label(text: commits(choice.ahead, "your"), point: CGPoint(x: secondLine + 12, y: yourTip)))
        return layout
    }

    private static func named(_ upstream: String, _ count: Int) -> String {
        count > dotLimit ? "\(upstream), \(count.formatted()) commits" : upstream
    }
}
