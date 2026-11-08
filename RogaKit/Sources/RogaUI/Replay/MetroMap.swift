import AppKit
import CommitGraph
import GitCore
import HistoryUI
import SwiftUI

/// A replay drawn as a metro map: the main line across the middle in ink, each
/// branch in a lane above or below it, and merges as interchanges (decision 62).
///
/// Everything is worked out from the time alone. The timings and sizes are the
/// ones from the prototype in `prototypes/history-replay`.
struct MetroMap: ReplayPicture {
    /// How many commit steps a curve between two lanes spans.
    static let curve = 0.9
    /// How long a line takes to reach its commit, a dot takes to pop, and a
    /// merge's ring takes to fade.
    static let grow = 0.32
    static let pop = 0.3
    static let ring = 0.8
    /// The zoom out to the whole history at the end, and how long it holds there.
    static let finale = 2.4
    static let hold = 2.4
    /// How long a commit's subject stays up through a flat stretch, and how
    /// long a merge's note does.
    static let tick = 0.9
    static let note = 1.8
    /// The stems take turns going down and up, at two heights, so that
    /// neighbors don't land on each other.
    static let stems: [(side: Double, length: Double)] = [(1, 18), (-1, 18), (1, 36), (-1, 36)]

    /// Commit spacing in a window narrower than `smallWidth`, and in a wider one.
    private static let smallWidth = 640.0
    private static let smallSpacing = 26.0
    private static let largeSpacing = 34.0

    private struct Marker {
        var x: Double
        var time: Double
        var label: String
    }

    let replay: HistoryReplay
    let repositoryName: String
    private let markers: [Marker]
    private let days: Int
    /// How close commits are drawn, from how much the replay had to speed up.
    private let zoom: Double
    /// Which merges get a note when the commits are spaced for each width.
    /// The rest would land on a note that's still showing.
    private let notesWhenSmall: Set<Int>
    private let notesWhenLarge: Set<Int>

    private static let dateFormatter = formatter("EEEMMMdjmm")
    private static let dayFormatter = formatter("MMMd")
    private static let rangeFormatter = formatter("MMMdyyyy")

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    init(replay: HistoryReplay, repositoryName: String) {
        self.replay = replay
        self.repositoryName = repositoryName
        let zoom = max(0.35, min(1, replay.pace * 2))
        self.zoom = zoom

        var markers: [Marker] = []
        let calendar = Calendar.current
        var dayStart = Double.infinity
        var dayEnd = -Double.infinity
        var dayCount = 0
        for (step, commit) in replay.commits.enumerated() {
            let date = Double(commit.commitTime)
            // Most commits are on the same day as the one before.
            if date < dayStart || date >= dayEnd {
                let start = calendar.startOfDay(for: Date(timeIntervalSince1970: date))
                dayStart = start.timeIntervalSince1970
                dayEnd = (calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)).timeIntervalSince1970
                markers.append(Marker(x: Double(step) - 0.5, time: commit.time, label: Self.dayFormatter.string(from: start)))
                dayCount += 1
            }
        }
        self.markers = markers
        if let first = replay.commits.first, let last = replay.commits.last {
            let firstDay = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(first.commitTime)))
            let lastDay = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(last.commitTime)))
            days = (calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0) + 1
        } else {
            days = 0
        }
        notesWhenSmall = Self.notes(of: replay, spacing: Self.smallSpacing * zoom)
        notesWhenLarge = Self.notes(of: replay, spacing: Self.largeSpacing * zoom)
    }

    var duration: Double { replay.playEnd + Self.finale + Self.hold }

    var summary: String {
        let commits = counted(replay.commits.count, "commit")
        let branches = counted(replay.branches.count - 1, "branch", plural: "branches")
        return "\(replay.mainLineName) in \(repositoryName): \(commits), \(branches), \(counted(days, "day"))."
    }

    /// Finds the merges that can show their note. Going through them in order
    /// makes a note's fate the same at every moment, so that nothing flickers.
    /// Notes on opposite sides of the main line can't touch.
    private static func notes(of replay: HistoryReplay, spacing: Double) -> Set<Int> {
        var shown = Set<Int>()
        var lastOnSide: [Bool: (step: Int, time: Double, width: Double)] = [:]
        for (step, commit) in replay.commits.enumerated() where commit.isMerge {
            guard let merged = commit.merged else { continue }
            let side = replay.branches[merged].lane < 0
            let width = estimatedWidth(noteText(replay.branches[merged]), size: 12)
            if let last = lastOnSide[side],
               commit.time - last.time < note,
               Double(step - last.step) * spacing < (last.width + width) / 2 + 10 {
                continue
            }
            shown.insert(step)
            lastOnSide[side] = (step, commit.time, width)
        }
        return shown
    }

    private static func noteText(_ branch: HistoryReplay.Branch) -> String {
        branch.pullRequest.map { "Merged #\($0)" } ?? "Merged"
    }

    /// Roughly how wide some text is, which is close enough for keeping it off
    /// other text, and costs nothing to work out for every frame.
    private static func estimatedWidth(_ text: String, size: Double) -> Double {
        Double(text.count) * size * 0.54
    }

    private func counted(_ number: Int, _ singular: String, plural: String? = nil) -> String {
        "\(number) \(number == 1 ? singular : plural ?? singular + "s")"
    }

    // MARK: - Drawing

    /// Where things are at one moment, in the size being drawn.
    private struct Frame {
        var time: Double
        var width: Double
        var height: Double
        var isSmall: Bool
        var top: Double
        var bottom: Double
        /// How far into the zoom out at the end, from 0 to 1.
        var finished: Double
        var kx: Double
        var ky: Double
        var ox: Double
        var oy: Double
        var dot: Double
        var theme: MetroTheme
        /// The newest commit landed, or -1 before the first.
        var head: Int

        var playing: Double { 1 - finished }
        var xMin: Double { -ox / kx - 2 }
        var xMax: Double { (width - ox) / kx + 2 }
        func x(_ step: Double) -> Double { ox + step * kx }
        func y(_ lane: Double) -> Double { oy + lane * ky }
    }

    func draw(in context: GraphicsContext, size: CGSize, at time: Double, colorScheme: ColorScheme) {
        let theme = MetroTheme.of(colorScheme)
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.paper))
        guard !replay.commits.isEmpty else { return }
        let frame = layout(time, size: size, theme: theme)
        let color = colorsByBranch(theme)
        drawDays(context, frame)
        drawLines(context, frame, color)
        drawCommits(context, frame, color)
        if frame.playing > 0 { drawSubjects(context, frame) }
        drawBranchNames(context, frame, color)
        drawNotes(context, frame)
        drawMainLineName(context, frame)
        drawHeader(context, frame)
        drawCaption(context, frame, color)
        drawSummary(context, frame)
    }

    private func layout(_ time: Double, size: CGSize, theme: MetroTheme) -> Frame {
        let width = size.width
        let height = size.height
        let count = replay.commits.count
        let isSmall = width < Self.smallWidth
        let spacing = (isSmall ? Self.smallSpacing : Self.largeSpacing) * zoom
        let laneGap = isSmall ? 34.0 : 46.0
        let top = isSmall ? 96.0 : 84.0
        let bottom = 60.0
        let finished = easeInOut(clamp((time - replay.playEnd) / Self.finale))
        let fitZoom = min(1, (width - 48) / (Double(max(count - 1, 1)) * spacing))
        let room = (height - top - bottom) / 2 - 30
        let fitLanes = min(1, room / (Double(max(replay.farthestLane, 1)) * laneGap))
        let kx = spacing * lerp(1, fitZoom, finished)
        let ky = laneGap * fitLanes * lerp(1, 0.6, finished)
        let focus = lerp(cameraX(min(time, replay.playEnd)), Double(count - 1) / 2, finished)
        let anchor = lerp(isSmall ? 0.7 : 0.66, 0.5, finished)
        return Frame(
            time: time,
            width: width,
            height: height,
            isSmall: isSmall,
            top: top,
            bottom: bottom,
            finished: finished,
            kx: kx,
            ky: ky,
            ox: width * anchor - focus * kx,
            oy: top + (height - top - bottom) / 2,
            dot: lerp(1, 0.55, finished),
            theme: theme,
            head: headAt(time)
        )
    }

    /// The newest commit that has landed by `time`, or -1.
    private func headAt(_ time: Double) -> Int {
        var low = 0
        var high = replay.commits.count - 1
        var found = -1
        while low <= high {
            let middle = (low + high) / 2
            if replay.commits[middle].time <= time {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    /// Where the newest commit is, sliding toward the next one between them.
    private func playheadX(_ time: Double) -> Double {
        let index = headAt(time)
        guard index >= 0 else { return 0 }
        guard index < replay.commits.count - 1 else { return Double(replay.commits.count - 1) }
        let current = replay.commits[index]
        let next = replay.commits[index + 1]
        return Double(index) + clamp((time - current.time) / (next.time - current.time))
    }

    /// The average of where the newest commit was over the last half second,
    /// so that the camera glides rather than stepping from commit to commit.
    private func cameraX(_ time: Double) -> Double {
        let samples = 16
        var sum = 0.0
        for sample in 0 ..< samples {
            sum += playheadX(time - 0.5 * Double(sample) / Double(samples - 1))
        }
        return sum / Double(samples)
    }

    /// The colors to draw each branch in. The main line is last, in ink.
    private func colorsByBranch(_ theme: MetroTheme) -> [Color] {
        theme.lanes + [theme.ink]
    }

    private func colorIndex(_ branch: Int) -> Int {
        branch == 0 ? MetroTheme.laneCount : replay.branches[branch].color
    }

    private func drawDays(_ context: GraphicsContext, _ frame: Frame) {
        var lastLabel = -Double.infinity
        for marker in markers where marker.time <= frame.time && marker.x >= frame.xMin && marker.x <= frame.xMax {
            let x = frame.x(marker.x)
            var line = Path()
            line.move(to: CGPoint(x: x, y: frame.top + 8))
            line.addLine(to: CGPoint(x: x, y: frame.height - frame.bottom - 8))
            context.stroke(line, with: .color(frame.theme.line), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
            if x - lastLabel > 48 {
                drawText(context, marker.label, size: 11, weight: .medium, color: frame.theme.muted, x: x + 6, baseline: frame.top + 18)
                lastLabel = x
            }
        }
    }

    /// The range of steps worth drawing: from the left edge to the newest
    /// commit, which a line can reach back from even when it's far to the
    /// right.
    private func visibleSteps(_ frame: Frame) -> ClosedRange<Int>? {
        guard frame.head >= 0 else { return nil }
        let first = max(0, Int(frame.xMin.rounded(.down)))
        return first <= frame.head ? first ... frame.head : nil
    }

    private func drawLines(_ context: GraphicsContext, _ frame: Frame, _ color: [Color]) {
        guard let steps = visibleSteps(frame) else { return }
        var branchLines = [Path](repeating: Path(), count: color.count)
        var mainLines = [Path](repeating: Path(), count: color.count)
        for step in steps {
            let commit = replay.commits[step]
            let progress = easeOut(clamp((frame.time - commit.time) / Self.grow))
            let branch = replay.branches[commit.branch]
            for parent in commit.parents where Double(parent) <= frame.xMax {
                let parentBranch = replay.commits[parent].branch
                let kind: EdgeKind =
                    parentBranch == commit.branch ? .straight
                    : parent == branch.forkPoint && step == branch.first ? .fork
                    : .merge
                let drawnIn = colorIndex(kind == .merge ? parentBranch : commit.branch)
                let from = Double(replay.branches[parentBranch].lane)
                let to = Double(branch.lane)
                if commit.branch == 0 {
                    addEdge(to: &mainLines[drawnIn], frame, parent: parent, child: step, from: from, to: to, kind, progress)
                } else {
                    addEdge(to: &branchLines[drawnIn], frame, parent: parent, child: step, from: from, to: to, kind, progress)
                }
            }
        }
        let style = StrokeStyle(lineWidth: lerp(2.5, 1.6, frame.finished), lineCap: .round)
        for lines in [branchLines, mainLines] {
            for (index, path) in lines.enumerated() where !path.isEmpty {
                context.stroke(path, with: .color(color[index]), style: style)
            }
        }
    }

    private enum EdgeKind {
        case straight, fork, merge
    }

    /// The line from a parent to its child, as far along as `progress`. A
    /// branch leaves its parent's lane straight away, and a merge comes in at
    /// the end, so lines run along their own lanes in between.
    private func addEdge(
        to path: inout Path,
        _ frame: Frame,
        parent: Int,
        child: Int,
        from: Double,
        to: Double,
        _ kind: EdgeKind,
        _ progress: Double
    ) {
        let start = Double(parent)
        let span = Double(child - parent)
        let reach = span * progress
        if kind == .straight || from == to {
            path.move(to: CGPoint(x: frame.x(start), y: frame.y(to)))
            path.addLine(to: CGPoint(x: frame.x(start + reach), y: frame.y(to)))
            return
        }
        let curve = min(Self.curve, span)
        if kind == .fork {
            addCurve(to: &path, frame, x0: start, lane0: from, x1: start + curve, lane1: to, progress: min(1, reach / curve), move: true)
            if reach > curve { path.addLine(to: CGPoint(x: frame.x(start + reach), y: frame.y(to))) }
        } else {
            let straight = span - curve
            path.move(to: CGPoint(x: frame.x(start), y: frame.y(from)))
            path.addLine(to: CGPoint(x: frame.x(start + min(reach, straight)), y: frame.y(from)))
            if reach > straight {
                addCurve(to: &path, frame, x0: start + straight, lane0: from, x1: Double(child), lane1: to, progress: (reach - straight) / curve, move: false)
            }
        }
    }

    /// An S-shaped curve between two lanes, as far along as `progress`.
    private func addCurve(
        to path: inout Path,
        _ frame: Frame,
        x0: Double,
        lane0: Double,
        x1: Double,
        lane1: Double,
        progress: Double,
        move: Bool
    ) {
        let middle = (x0 + x1) / 2
        var points = [(x0, lane0), (middle, lane0), (middle, lane1), (x1, lane1)]
        if progress < 1 { points = splitCubic(points, progress) }
        let screen = points.map { CGPoint(x: frame.x($0.0), y: frame.y($0.1)) }
        if move { path.move(to: screen[0]) }
        path.addCurve(to: screen[3], control1: screen[1], control2: screen[2])
    }

    /// The first part of a cubic curve, up to `t`.
    private func splitCubic(_ points: [(Double, Double)], _ t: Double) -> [(Double, Double)] {
        func at(_ p: (Double, Double), _ q: (Double, Double)) -> (Double, Double) {
            (p.0 + (q.0 - p.0) * t, p.1 + (q.1 - p.1) * t)
        }
        let ab = at(points[0], points[1])
        let bc = at(points[1], points[2])
        let cd = at(points[2], points[3])
        let abc = at(ab, bc)
        let bcd = at(bc, cd)
        return [points[0], ab, abc, at(abc, bcd)]
    }

    private func drawCommits(_ context: GraphicsContext, _ frame: Frame, _ color: [Color]) {
        guard let steps = visibleSteps(frame) else { return }

        // The newest commit glows softly while the replay plays, once its dot is in.
        if frame.playing > 0 {
            let commit = replay.commits[frame.head]
            let alpha = 0.16 * frame.playing * clamp((frame.time - commit.time - Self.grow * 0.5) / Self.pop)
            var glow = context
            glow.opacity = alpha
            let center = point(frame, step: frame.head)
            let radius = 13 + 2 * sin(frame.time * 5)
            glow.fill(circle(center, radius), with: .color(color[colorIndex(commit.branch)]))
        }

        var dots = [Path](repeating: Path(), count: color.count)
        var interchanges = [Path](repeating: Path(), count: color.count)
        var interchangeFill = Path()
        for step in steps where Double(step) <= frame.xMax {
            let commit = replay.commits[step]
            let age = frame.time - commit.time
            let scale = easeOutBack(clamp((age - Self.grow * 0.5) / Self.pop))
            guard scale > 0 else { continue }
            let isOnMainLine = commit.branch == 0
            let radius = (isOnMainLine ? 5 : 4.5) * frame.dot * scale
            let center = point(frame, step: step)
            let index = colorIndex(commit.branch)

            if commit.isMerge, age < Self.ring, let merged = commit.merged {
                let fade = age / Self.ring
                var ring = context
                ring.opacity = (1 - fade) * 0.9
                ring.stroke(
                    circle(center, radius + 28 * easeOut(fade)),
                    with: .color(color[colorIndex(merged)]),
                    lineWidth: 2
                )
            }
            if frame.theme.isDark, age < 1.4 {
                var halo = context
                halo.opacity = 0.32 * (1 - clamp(age / 1.4))
                halo.fill(circle(center, radius + 7), with: .color(color[index]))
            }
            // A pull request squashed onto the main line is an interchange
            // too, since its branch is gone from the history.
            if commit.isMerge || (isOnMainLine && commit.pullRequest != nil) {
                let outer = radius + 1.5 * frame.dot
                interchangeFill.addPath(circle(center, outer))
                interchanges[index].addPath(circle(center, outer))
            } else {
                dots[index].addPath(circle(center, radius))
            }
        }
        for (index, path) in dots.enumerated() where !path.isEmpty {
            context.fill(path, with: .color(color[index]))
        }
        context.fill(interchangeFill, with: .color(frame.theme.paper))
        for (index, path) in interchanges.enumerated() where !path.isEmpty {
            context.stroke(path, with: .color(color[index]), lineWidth: 2.5 * frame.dot)
        }
    }

    /// Each commit in a flat stretch flicks its subject off the line, trailing
    /// behind its stem as the camera moves on, and fades quickly.
    private func drawSubjects(_ context: GraphicsContext, _ frame: Frame) {
        guard frame.head >= 0 else { return }
        let size = frame.isSmall ? 10.0 : 11.0
        let room = frame.kx * Double(Self.stems.count) - 12
        var step = frame.head
        while step >= 0 {
            let commit = replay.commits[step]
            let age = frame.time - commit.time - Self.grow * 0.4
            if age > Self.tick { break }
            defer { step -= 1 }
            guard age >= 0, let stem = commit.stem, Double(step) >= frame.xMin, Double(step) <= frame.xMax else { continue }

            let (side, length) = Self.stems[stem]
            let reach = length * easeOut(clamp(age / 0.14)) + 4 * (age / Self.tick)
            let alpha = (1 - clamp((age - 0.3) / (Self.tick - 0.3))) * frame.playing
            let x = frame.x(Double(step))
            let tip = frame.y(0) + side * reach

            var stemContext = context
            stemContext.opacity = alpha * 0.7
            var line = Path()
            line.move(to: CGPoint(x: x, y: frame.y(0) + side * 7 * frame.dot))
            line.addLine(to: CGPoint(x: x, y: tip))
            stemContext.stroke(line, with: .color(frame.theme.muted), lineWidth: 1)

            guard room > 40 else { continue }
            drawText(
                context,
                fitted(commit.subject, width: room, size: size),
                size: size,
                weight: .medium,
                color: frame.theme.ink,
                x: x - 5,
                baseline: tip + 4,
                alignment: .trailing,
                alpha: alpha * 0.85 * clamp(age / 0.1)
            )
        }
    }

    private func drawBranchNames(_ context: GraphicsContext, _ frame: Frame, _ color: [Color]) {
        let size = frame.isSmall ? 11.0 : 12.0
        for (index, branch) in replay.branches.enumerated().dropFirst() {
            let first = replay.commits[branch.first]
            guard first.time <= frame.time, let merge = branch.merge else { continue }
            let appear = clamp((frame.time - first.time) / 0.35)
            var alpha = appear * frame.playing
            let mergeTime = replay.commits[merge].time
            if mergeTime <= frame.time { alpha *= 1 - clamp((frame.time - mergeTime - 0.9) / 0.5) }
            guard alpha > 0 else { continue }
            let side = branch.lane < 0 ? -1.0 : 1.0
            var name = branch.title ?? branch.name
            if name.count > 44 { name = String(name.prefix(43)).trimmingCharacters(in: .whitespaces) + "…" }
            let label = (branch.pullRequest.map { "#\($0)  " } ?? "") + name
            drawPill(
                context,
                label,
                x: frame.x(Double(branch.first)) - 7,
                y: frame.y(Double(branch.lane)) + side * (19 - 6 * (1 - appear)),
                color: color[colorIndex(index)],
                alpha: alpha,
                size: size,
                frame
            )
        }
    }

    /// A note under each merge, on the side away from its branch.
    private func drawNotes(_ context: GraphicsContext, _ frame: Frame) {
        guard frame.head >= 0 else { return }
        let shown = frame.isSmall ? notesWhenSmall : notesWhenLarge
        var step = frame.head
        while step >= 0, frame.time - replay.commits[step].time <= Self.note {
            defer { step -= 1 }
            guard shown.contains(step), let merged = replay.commits[step].merged else { continue }
            let age = frame.time - replay.commits[step].time
            let branch = replay.branches[merged]
            let alpha = min(clamp(age / 0.2), clamp((Self.note - age) / 0.5)) * frame.playing
            drawText(
                context,
                Self.noteText(branch),
                size: 12,
                weight: .medium,
                color: frame.theme.muted,
                x: frame.x(Double(step)),
                baseline: frame.y(0) + (branch.lane < 0 ? 26 : -18),
                alignment: .center,
                alpha: alpha
            )
        }
    }

    /// The main line's name stays at the left edge once it scrolls past.
    private func drawMainLineName(_ context: GraphicsContext, _ frame: Frame) {
        drawPill(
            context,
            replay.mainLineName,
            x: max(16, frame.x(0) - 7),
            y: frame.y(0) - 19,
            color: frame.theme.ink,
            alpha: clamp(frame.time / 0.6),
            size: frame.isSmall ? 11 : 12,
            frame
        )
    }

    private func drawHeader(_ context: GraphicsContext, _ frame: Frame) {
        let alpha = frame.playing
        guard alpha > 0 else { return }
        let theme = frame.theme
        let commit = frame.head >= 0 ? replay.commits[frame.head] : nil
        drawText(context, repositoryName, size: 17, weight: .bold, color: theme.ink, x: 16, baseline: 32, alpha: alpha)

        let date = commit.map { Self.dateFormatter.string(from: Date(timeIntervalSince1970: Double($0.commitTime))) } ?? ""
        let dateText = drawText(context, date, size: 13, color: theme.muted, x: 16, baseline: 52, alpha: alpha)
        if let commit, commit.isFast, frame.head < replay.commits.count - 1 {
            drawText(context, "Fast-forwarding", size: 12, weight: .semibold, color: theme.accent, x: 16 + dateText.width + 12, baseline: 52, alpha: alpha)
        }

        let stats = [
            (commit == nil ? 0 : frame.head + 1, "commits"),
            (commit?.forksSoFar ?? 0, "branches"),
            (commit?.mergesSoFar ?? 0, "merges"),
        ]
        if frame.isSmall {
            let line = stats.map { "\($0.0) \($0.1)" }.joined(separator: "  ·  ")
            drawText(context, line, size: 13, color: theme.muted, x: 16, baseline: 74, alpha: alpha)
        } else {
            var x = frame.width - 16
            for (number, label) in stats.reversed() {
                drawText(context, String(number), size: 20, weight: .bold, color: theme.ink, x: x, baseline: 34, alignment: .trailing, alpha: alpha)
                drawText(context, label.uppercased(), size: 10, weight: .semibold, color: theme.muted, x: x, baseline: 52, alignment: .trailing, alpha: alpha)
                x -= 86
            }
        }
    }

    private func drawCaption(_ context: GraphicsContext, _ frame: Frame, _ color: [Color]) {
        guard frame.head >= 0 else { return }
        let commit = replay.commits[frame.head]
        let alpha = clamp((frame.time - commit.time) / 0.2) * frame.playing
        guard alpha > 0 else { return }
        let y = frame.height - 26
        let hash = drawText(
            context,
            String(commit.id.hex.prefix(7)),
            size: 12,
            design: .monospaced,
            color: color[colorIndex(commit.branch)],
            x: 16,
            baseline: y,
            alpha: alpha
        )
        let hashWidth = hash.width + 12
        drawText(
            context,
            fitted(commit.subject, width: frame.width - 32 - hashWidth, size: 15),
            size: 15,
            color: frame.theme.ink,
            x: 16 + hashWidth,
            baseline: y,
            alpha: alpha
        )
    }

    private func drawSummary(_ context: GraphicsContext, _ frame: Frame) {
        let alpha = clamp((frame.time - replay.playEnd - Self.finale * 0.7) / 0.6)
        guard alpha > 0, let first = replay.commits.first, let last = replay.commits.last else { return }
        let theme = frame.theme
        let center = frame.width / 2
        let counts = [
            counted(replay.commits.count, "commit"),
            counted(replay.branches.count - 1, "branch", plural: "branches"),
            counted(days, "day"),
        ].joined(separator: "  ·  ")
        drawText(context, counts, size: frame.isSmall ? 18 : 24, weight: .bold, color: theme.ink, x: center, baseline: frame.isSmall ? 40 : 42, alignment: .center, alpha: alpha)

        let from = Self.rangeFormatter.string(from: Date(timeIntervalSince1970: Double(first.commitTime)))
        let to = Self.rangeFormatter.string(from: Date(timeIntervalSince1970: Double(last.commitTime)))
        drawText(context, "\(repositoryName), \(from) to \(to)", size: 13, color: theme.muted, x: center, baseline: frame.isSmall ? 62 : 66, alignment: .center, alpha: alpha)
        drawText(context, "Replayed in Roga", size: 13, color: theme.muted, x: center, baseline: frame.height - 26, alignment: .center, alpha: alpha)
    }

    // MARK: - Pieces

    private func point(_ frame: Frame, step: Int) -> CGPoint {
        let lane = Double(replay.branches[replay.commits[step].branch].lane)
        return CGPoint(x: frame.x(Double(step)), y: frame.y(lane))
    }

    private func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// Cuts text to about `width`, going by an estimate rather than measuring,
    /// since this happens for many labels on every frame.
    private func fitted(_ text: String, width: Double, size: Double) -> String {
        guard Self.estimatedWidth(text, size: size) > width else { return text }
        let characters = max(1, Int(width / (size * 0.54)) - 1)
        return String(text.prefix(characters)) + "…"
    }

    /// Draws text whose baseline is at `baseline`, and returns its size.
    @discardableResult
    private func drawText(
        _ context: GraphicsContext,
        _ string: String,
        size: Double,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        color: Color,
        x: Double,
        baseline: Double,
        alignment: HorizontalAlignment = .leading,
        alpha: Double = 1
    ) -> CGSize {
        var context = context
        context.opacity = alpha
        let text = context.resolve(Text(string).font(.system(size: size, weight: weight, design: design)).foregroundStyle(color))
        let measured = text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
        let anchor: UnitPoint = alignment == .center ? .bottom : alignment == .trailing ? .bottomTrailing : .bottomLeading
        // The bottom of a line of text is below its baseline by its descent.
        context.draw(text, at: CGPoint(x: x, y: baseline + size * 0.24), anchor: anchor)
        return measured
    }

    private func drawPill(
        _ context: GraphicsContext,
        _ string: String,
        x: Double,
        y: Double,
        color: Color,
        alpha: Double,
        size: Double,
        _ frame: Frame
    ) {
        var background = context
        background.opacity = alpha * (frame.theme.isDark ? 0.16 : 0.12)
        let width = max(context.resolve(Text(string).font(.system(size: size, weight: .semibold))).measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width, 0) + 14
        background.fill(Path(roundedRect: CGRect(x: x, y: y - 10, width: width, height: 20), cornerRadius: 6), with: .color(color))
        drawText(context, string, size: size, weight: .semibold, color: color, x: x + 7, baseline: y + 4, alpha: alpha)
    }
}

/// The colors of the picture. They're fixed for each appearance rather than
/// following the system, so that a saved video looks the same as the window.
struct MetroTheme {
    static let laneCount = GitColors.lanes.count

    var isDark: Bool
    var paper: Color
    var ink: Color
    var muted: Color
    var line: Color
    var accent: Color
    var lanes: [Color]

    private static let light = MetroTheme(
        isDark: false,
        paper: Color(hex: 0xFAF6EE),
        ink: Color(hex: 0x16150E),
        muted: Color(hex: 0x6A665A),
        line: Color(hex: 0xDCD5C6),
        accent: Color(hex: 0xB53D00),
        lanes: resolvedLanes(.aqua)
    )
    private static let dark = MetroTheme(
        isDark: true,
        paper: Color(hex: 0x16150E),
        ink: Color(hex: 0xF5F0E6),
        muted: Color(hex: 0xA9A394),
        line: Color(hex: 0x3A372D),
        accent: Color(hex: 0xF2702E),
        lanes: resolvedLanes(.darkAqua)
    )

    static func of(_ scheme: ColorScheme) -> MetroTheme {
        scheme == .dark ? dark : light
    }

    /// The graph's lane colors in one appearance, whatever the window's is.
    private static func resolvedLanes(_ name: NSAppearance.Name) -> [Color] {
        var colors: [Color] = []
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            colors = GitColors.lanes.map { Color(nsColor: $0.usingColorSpace(.sRGB) ?? $0) }
        }
        return colors
    }
}

private extension Color {
    init(hex: Int) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

private func clamp(_ value: Double, _ low: Double = 0, _ high: Double = 1) -> Double {
    min(high, max(low, value))
}

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}

private func easeInOut(_ t: Double) -> Double {
    t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}

private func easeOut(_ t: Double) -> Double {
    1 - pow(1 - t, 3)
}

private func easeOutBack(_ t: Double) -> Double {
    let c = 1.9
    return t <= 0 ? 0 : 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2)
}
