import AppKit
import CommitGraph
import GitCore
import HistoryUI
import SwiftUI
import ThemeUI

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
    /// How long a number at the top takes to roll to a new count, unless
    /// the next count comes sooner.
    static let roll = 0.35
    /// How long each highlight holds in the tour after the zoom out, and how
    /// long the poster takes to arrive after it.
    static let beat = 2.0
    static let posterIn = 1.5

    /// Commit spacing in a window narrower than `smallWidth`, and in a wider one.
    private static let smallWidth = 640.0
    private static let smallSpacing = 26.0
    private static let largeSpacing = 34.0
    /// How far apart lanes are when there's room, in a narrow window and a wider one.
    static let smallLaneGap = 34.0
    static let largeLaneGap = 46.0

    struct Marker {
        var x: Double
        var time: Double
        var label: String
    }

    /// The moves of every label, kept for each way of spacing the picture out
    /// so that a frame only has to look them up.
    private final class Stacking {
        struct Layout: Hashable {
            var isSmall: Bool
            var halfPointsBetweenLanes: Int
        }

        var moves: [Layout: [[LabelStacks.Move]]] = [:]
    }

    /// The name that stays by a commit on the main line, or by the first
    /// commit of a branch.
    private struct Label {
        var step: Int
        var text: String
        /// How wide it is at the larger text size, with its padding.
        var width: Double
        var isAbove: Bool
        var branch: Int
        var lane: Int
    }

    /// The replay, starting once the title card has cleared.
    let replay: HistoryReplay
    let repositoryName: String
    /// What the title card says above the repository's name, which is the
    /// range being replayed, such as THE LAST 7 DAYS OF.
    let rangeLine: String
    /// Whether the house walks along the line, in front of the newest commit.
    var showsHouse: Bool
    let markers: [Marker]
    let days: Int
    let highlights: HistoryReplay.Highlights
    /// What the tour at the end stops at, in order.
    let beats: [TourBeat]
    /// What the poster at the end has a tile for, in order.
    let tiles: [PosterTile]
    /// The cards that come up as records are set.
    let flares: [Flare]
    /// The commits big enough for their lines to fly up to the count.
    let flights: [Int]
    /// The days that get their name across the picture, as indexes into `markers`.
    let gates: [Int]
    let pulse: Pulse
    /// How close commits are drawn, from how much the replay had to speed up.
    private let zoom: Double
    /// Every label, oldest first.
    private let labels: [Label]
    private let widestLabel: Double
    private let stacking = Stacking()
    /// The steps whose commits change each number at the top, oldest first.
    /// Every commit changes the count of commits.
    private let forkSteps: [Int]
    private let mergeSteps: [Int]
    private let addedSteps: [Int]
    private let removedSteps: [Int]

    static let dayFormatter = formatter("MMMd")
    static let weekdayFormatter = formatter("EEEE")
    static let narrowWeekdayFormatter = formatter("EEEEE")
    static let weekdayAndDayFormatter = formatter("EEEMMMd")
    static let timeFormatter = formatter("jmm")
    static let rangeFormatter = formatter("MMMdyyyy")

    static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    init(replay: HistoryReplay, repositoryName: String, rangeLine: String = "THE HISTORY OF", showsHouse: Bool = false) {
        // Every time in the picture is the replay's, so the replay waits
        // for the title card rather than the picture keeping two clocks.
        var replay = replay
        if !replay.commits.isEmpty { replay.start(at: Self.intro) }
        self.replay = replay
        self.repositoryName = repositoryName
        self.rangeLine = rangeLine
        self.showsHouse = showsHouse
        let zoom = max(0.35, min(1, replay.pace * 2))
        self.zoom = zoom

        let highlights = replay.highlights()
        self.highlights = highlights
        let markers = highlights.days.map { day in
            Marker(x: Double(day.first) - 0.5, time: replay.commits[day.first].time, label: Self.dayFormatter.string(from: day.start))
        }
        self.markers = markers
        days = highlights.dayCount
        beats = Self.beats(of: replay, highlights)
        tiles = Self.tiles(of: replay, highlights)
        flares = Self.flares(of: replay, highlights)
        flights = Self.flights(of: replay)
        gates = Self.gates(among: markers)
        pulse = Pulse(of: replay)
        labels = Self.labels(of: replay)
        widestLabel = labels.map(\.width).max() ?? 0
        let commits = replay.commits
        forkSteps = commits.indices.filter { commits[$0].isFork }
        mergeSteps = commits.indices.filter { commits[$0].isMerge }
        addedSteps = commits.indices.filter { commits[$0].lines.added > 0 }
        removedSteps = commits.indices.filter { commits[$0].lines.removed > 0 }
    }

    /// When the camera has finished pulling back.
    var zoomEnd: Double { replay.playEnd + Self.finale }
    var tourStart: Double { zoomEnd - 0.1 }
    var tourLength: Double { beats.isEmpty ? 0 : Double(beats.count) * Self.beat + 0.4 }
    /// When the poster starts to come in: after the tour, or with nothing to
    /// tour, as the camera finishes pulling back.
    var posterStart: Double { beats.isEmpty ? replay.playEnd + Self.finale * 0.7 : tourStart + tourLength }
    var duration: Double { posterStart + Self.posterIn + Self.hold }

    var summary: String {
        let commits = counted(replay.commits.count, "commit")
        let branches = counted(replay.branches.count - 1, "branch", plural: "branches")
        let summary = "\(replay.mainLineName) in \(repositoryName): \(commits), \(branches), \(counted(days, "day"))"
        let highlighted = beats.map { " \($0.eyebrow.capitalized): \($0.value)." }.joined()
        guard replay.hasLineCounts, let lines = replay.commits.last?.linesSoFar else { return summary + "." + highlighted }
        return summary + ", \(lines.added.formatted()) lines added and \(lines.removed.formatted()) removed." + highlighted
    }

    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// A label for every commit on the main line and for the first commit of
    /// every branch. Commits on the main line take turns going above and
    /// below it, except that a merge goes on the side away from its branch.
    private static func labels(of replay: HistoryReplay) -> [Label] {
        var labels: [Label] = []
        var nextIsAbove = true
        for (step, commit) in replay.commits.enumerated() {
            let branch = replay.branches[commit.branch]
            let text: String
            let isAbove: Bool
            if commit.branch != 0 {
                guard branch.first == step else { continue }
                text = (branch.pullRequest.map { "#\($0)  " } ?? "") + title(ofBranch: commit.branch, in: replay)
                isAbove = branch.lane < 0
            } else if let merged = commit.merged {
                let mergedBranch = replay.branches[merged]
                if let pullRequest = mergedBranch.pullRequest {
                    text = "Merged #\(pullRequest)"
                } else if mergedBranch.name != HistoryReplay.unnamedBranch {
                    text = "Merged \(mergedBranch.name)"
                } else {
                    text = commit.subject
                }
                isAbove = mergedBranch.lane > 0
            } else {
                text = commit.subject
                isAbove = nextIsAbove
                nextIsAbove.toggle()
            }
            guard !text.isEmpty else { continue }
            labels.append(Label(
                step: step,
                text: text,
                width: (text as NSString).size(withAttributes: [.font: labelFont]).width + 8,
                isAbove: isAbove,
                branch: commit.branch,
                lane: branch.lane
            ))
        }
        return labels
    }

    /// What to call a branch: its pull request's title, its name, or, with
    /// neither, the subject of its first commit.
    static func title(ofBranch index: Int, in replay: HistoryReplay) -> String {
        let branch = replay.branches[index]
        return branch.title ?? (branch.name == HistoryReplay.unnamedBranch ? replay.commits[branch.first].subject : branch.name)
    }

    /// Roughly how wide some text is, which is close enough for keeping it off
    /// other text, and costs nothing to work out for every frame.
    private static func estimatedWidth(_ text: String, size: Double) -> Double {
        Double(text.count) * size * 0.54
    }

    func counted(_ number: Int, _ singular: String, plural: String? = nil) -> String {
        "\(number.formatted()) \(number == 1 ? singular : plural ?? singular + "s")"
    }

    // MARK: - Drawing

    /// Where things are at one moment, in the size being drawn.
    struct Frame {
        var time: Double
        var width: Double
        var height: Double
        var isSmall: Bool
        var top: Double
        var bottom: Double
        /// How far into the zoom out at the end, from 0 to 1.
        var finished: Double
        /// How far the poster has come in, from 0 to 1.
        var posterProgress: Double
        /// How the numbers fit in the band at the top, or nil if they don't,
        /// and go on a line instead.
        var band: BandFit?
        var showsPulse: Bool
        /// How much the camera pulls back by the end.
        var fitZoom: Double
        var kx: Double
        var ky: Double
        /// How far apart commits and lanes are while the replay plays, which
        /// is what labels are stacked by, even as the camera pulls back.
        var spacing: Double
        var lanesApart: Double
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
        let tour = tourMoment(at: time)
        let intro = introMoment(at: time)
        // The tour turns the map down, so that what it stops at stands out.
        withOpacity(1 - 0.8 * (tour?.dimming ?? 0), context) { map in
            drawDays(map, frame)
            drawLines(map, frame, color)
            drawCommits(map, frame, color)
        }
        drawLabels(context, frame, color)
        if let tour { drawTourFocus(context, frame, color, tour) }

        var addedCount: CGPoint?
        // The board comes in as the title card clears, and the card brings
        // the repository's name to it.
        withOpacity((1 - frame.posterProgress) * (intro?.board ?? 1), context) { shell in
            addedCount = drawBand(shell, frame, arriving: intro)
            drawStrip(shell, frame, color, tour)
            if frame.showsPulse { drawPulse(shell, frame) }
        }
        drawFlares(context, frame)
        if let addedCount { drawFlights(context, frame, to: addedCount) }
        if showsHouse { drawHouse(context, frame) }
        drawPoster(context, frame)
        if let intro { drawIntro(context, frame, color, intro) }
    }

    /// Draws something all at one opacity, so that where its pieces overlap
    /// doesn't show.
    func withOpacity(_ alpha: Double, _ context: GraphicsContext, _ body: (GraphicsContext) -> Void) {
        guard alpha > 0 else { return }
        guard alpha < 1 else {
            body(context)
            return
        }
        var layer = context
        layer.opacity = alpha
        layer.drawLayer { body($0) }
    }

    private func layout(_ time: Double, size: CGSize, theme: MetroTheme) -> Frame {
        let width = size.width
        let height = size.height
        let count = replay.commits.count
        let isSmall = width < Self.smallWidth
        let spacing = (isSmall ? Self.smallSpacing : Self.largeSpacing) * zoom
        let laneGap = isSmall ? Self.smallLaneGap : Self.largeLaneGap
        let showsPulse = height >= Self.pulseLeastHeight
        let playTop = Self.bandHeight + 8 + (showsPulse ? Self.pulseHeight : 0)
        let playBottom = Self.stripHeight + 12
        let finished = easeInOut(clamp((time - replay.playEnd) / Self.finale))
        let posterProgress = easeInOut(clamp((time - posterStart) / Self.posterIn))
        let fitZoom = min(1, (width - 48) / (Double(max(count - 1, 1)) * spacing))
        let room = (height - playTop - playBottom) / 2 - 30
        let farthest = Double(max(replay.farthestLane, 1))
        let fitLanes = min(1, room / (farthest * laneGap))
        // The lanes stay well apart after the zoom out, because the tour and
        // the poster are about the shape of the whole history.
        let zoomedLanes = laneGap * fitLanes * lerp(1, 0.95, finished)
        let posterTop = Self.posterTop
        let posterBottom = posterBottom(width: width, height: height)
        let posterLanes = min(zoomedLanes * 0.82, max(0, (height - posterTop - posterBottom) / 2 - 14) / farthest)
        let top = lerp(playTop, posterTop, posterProgress)
        let bottom = lerp(playBottom, posterBottom, posterProgress)
        let kx = spacing * lerp(1, fitZoom, finished)
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
            posterProgress: posterProgress,
            band: bandFit(width: width),
            showsPulse: showsPulse,
            fitZoom: fitZoom,
            kx: kx,
            ky: lerp(zoomedLanes, posterLanes, posterProgress),
            spacing: spacing,
            lanesApart: laneGap * fitLanes,
            ox: width * anchor - focus * kx,
            oy: top + (height - top - bottom) / 2,
            dot: lerp(1, 0.62, finished),
            theme: theme,
            head: headAt(time)
        )
    }

    /// The newest commit that has landed by `time`, or -1.
    func headAt(_ time: Double) -> Int {
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
    func playheadX(_ time: Double) -> Double {
        let index = headAt(time)
        guard index >= 0 else { return 0 }
        guard index < replay.commits.count - 1 else { return Double(replay.commits.count - 1) }
        let current = replay.commits[index]
        let next = replay.commits[index + 1]
        return Double(index) + clamp((time - current.time) / (next.time - current.time))
    }

    /// The average of where the newest commit was over the last half second,
    /// so that the camera glides rather than stepping from commit to commit.
    func cameraX(_ time: Double) -> Double {
        let samples = 16
        var sum = 0.0
        for sample in 0 ..< samples {
            sum += playheadX(time - 0.5 * Double(sample) / Double(samples - 1))
        }
        return sum / Double(samples)
    }

    /// The colors to draw each branch in. The main line is last, in ink.
    func colorsByBranch(_ theme: MetroTheme) -> [Color] {
        theme.lanes + [theme.ink]
    }

    func colorIndex(_ branch: Int) -> Int {
        branch == 0 ? MetroTheme.laneCount : replay.branches[branch].color
    }

    func drawDays(_ context: GraphicsContext, _ frame: Frame) {
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
        drawGates(context, frame)
    }

    /// The range of steps worth drawing: from the left edge to the newest
    /// commit, which a line can reach back from even when it's far to the
    /// right.
    private func visibleSteps(_ frame: Frame) -> ClosedRange<Int>? {
        guard frame.head >= 0 else { return nil }
        let first = max(0, Int(frame.xMin.rounded(.down)))
        return first <= frame.head ? first ... frame.head : nil
    }

    /// Draws the lines of the commits that `only` allows, or of them all.
    func drawLines(
        _ context: GraphicsContext,
        _ frame: Frame,
        _ color: [Color],
        only: ((Int, HistoryReplay.Commit) -> Bool)? = nil,
        lineWidth: Double? = nil
    ) {
        guard let steps = visibleSteps(frame) else { return }
        var branchLines = [Path](repeating: Path(), count: color.count)
        var mainLines = [Path](repeating: Path(), count: color.count)
        for step in steps {
            let commit = replay.commits[step]
            if let only, !only(step, commit) { continue }
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
        let style = StrokeStyle(lineWidth: lineWidth ?? lerp(2.5, 1.6, frame.finished), lineCap: .round)
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

    /// How big a commit's stop is drawn, by how many lines it changed. Only
    /// the really big ones are still big once the camera has pulled back, or
    /// the stops would run together.
    func stopRadius(of commit: HistoryReplay.Commit, _ frame: Frame) -> Double {
        let lines = log10(Double(commit.lines.added + commit.lines.removed + 1))
        let near = clamp((lines - 1.6) / 2.4) * 8
        let far = clamp((lines - 3.1) / 0.9) * 7
        return (commit.branch == 0 ? 5 : 4.5) + lerp(near, far, frame.finished)
    }

    /// Draws the stops of the commits that `only` allows, or of them all.
    func drawCommits(
        _ context: GraphicsContext,
        _ frame: Frame,
        _ color: [Color],
        only: ((Int, HistoryReplay.Commit) -> Bool)? = nil
    ) {
        guard let steps = visibleSteps(frame) else { return }

        // The newest commit glows softly while the replay plays, once its dot is in.
        if frame.playing > 0 {
            let commit = replay.commits[frame.head]
            let alpha = 0.16 * frame.playing * clamp((frame.time - commit.time - Self.grow * 0.5) / Self.pop)
            var glow = context
            glow.opacity = alpha
            let center = point(frame, step: frame.head)
            let radius = 13 + 2 * sin(frame.time * 5) + stopRadius(of: commit, frame) - 5
            glow.fill(circle(center, radius), with: .color(color[colorIndex(commit.branch)]))
        }

        var dots = [Path](repeating: Path(), count: color.count)
        var interchanges = [Path](repeating: Path(), count: color.count)
        var interchangeFill = Path()
        for step in steps where Double(step) <= frame.xMax {
            let commit = replay.commits[step]
            if let only, !only(step, commit) { continue }
            let age = frame.time - commit.time
            let scale = easeOutBack(clamp((age - Self.grow * 0.5) / Self.pop))
            guard scale > 0 else { continue }
            let isOnMainLine = commit.branch == 0
            let radius = stopRadius(of: commit, frame) * frame.dot * scale
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

    /// The names that stay by their commits while the replay plays, each on a
    /// thin line back to its commit, on the tiers `LabelStacks` worked out. A
    /// label glides between tiers: it rests where its latest move put it,
    /// less what's left of the moves it's still making, so a frame still
    /// depends only on its time. One pushed past the edge of the picture
    /// fades until there's room for it to come back.
    private func drawLabels(_ context: GraphicsContext, _ frame: Frame, _ color: [Color]) {
        let alpha = 1 - clamp(frame.finished / 0.3)
        guard alpha > 0, frame.head >= 0 else { return }
        let newest = lastLabel(upTo: frame.head)
        let scale = frame.isSmall ? 10.0 / 11.0 : 1.0
        let widest = widestLabel * scale / frame.spacing
        let oldest = firstLabel(from: max(frame.xMin, Double(frame.head) - frame.width / frame.spacing) - widest)
        guard newest >= oldest else { return }

        let pitch = frame.isSmall ? 15.0 : 16.0
        func center(_ tier: Int) -> Double { 20 + Double(tier) * pitch }
        let moves = labelMoves(frame, pitch: pitch, scale: scale)

        struct Placed {
            var label: Label
            var x: Double
            var y: Double
            var alpha: Double
        }
        var shown: [Placed] = []
        var stems = Path()
        for index in oldest ... newest {
            let label = labels[index]
            let x = frame.x(Double(label.step))
            let age = frame.time - replay.commits[label.step].time - Self.grow * 0.4
            guard age >= 0, x <= frame.width, x + label.width * scale >= 0 else { continue }

            let own = moves[index]
            var latest = own.count - 1
            while latest > 0, own[latest].time > frame.time { latest -= 1 }
            var unfinished = 0.0
            var move = latest
            while move > 0, frame.time - own[move].time < LabelStacks.fallTime {
                unfinished += LabelStacks.remaining(of: center(own[move].tier) - center(own[move - 1].tier), age: frame.time - own[move].time)
                move -= 1
            }

            let side = label.isAbove ? -1.0 : 1.0
            let y = frame.y(0) + side * (center(own[latest].tier) - unfinished)
            let room = label.isAbove ? y - frame.top - 8 : frame.height - frame.bottom - 8 - y
            let edge = clamp(room / 24)
            guard edge > 0 else { continue }
            let start = frame.y(Double(label.lane)) + side * 7 * frame.dot
            let end = y + side * 7
            stems.move(to: CGPoint(x: x, y: start))
            stems.addLine(to: CGPoint(x: x, y: start + (end - start) * easeOut(clamp(age / 0.14))))
            shown.append(Placed(label: label, x: x, y: y, alpha: clamp(age / 0.12) * edge * alpha))
        }

        var stemContext = context
        stemContext.opacity = alpha * 0.55
        stemContext.stroke(stems, with: .color(frame.theme.muted), lineWidth: 1)

        let size = frame.isSmall ? 10.0 : 11.0
        for item in shown {
            var opaque = context
            opaque.opacity = item.alpha
            let tint = item.label.branch == 0 ? frame.theme.ink : color[colorIndex(item.label.branch)]
            let text = opaque.resolve(Text(item.label.text).font(.system(size: size, weight: .medium)).foregroundStyle(tint))
            let width = text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width
            let box = Path(roundedRect: CGRect(x: item.x + 0.5, y: item.y - 7, width: width + 7, height: 14), cornerRadius: 3)
            opaque.fill(box, with: .color(frame.theme.paper))
            if item.label.branch != 0 {
                var tinted = opaque
                tinted.opacity = item.alpha * (frame.theme.isDark ? 0.16 : 0.12)
                tinted.fill(box, with: .color(tint))
            }
            opaque.draw(text, at: CGPoint(x: item.x + 4, y: item.y), anchor: .leading)
        }
    }

    /// Every label's moves when the picture is spaced out like `frame`.
    private func labelMoves(_ frame: Frame, pitch: Double, scale: Double) -> [[LabelStacks.Move]] {
        let layout = Stacking.Layout(isSmall: frame.isSmall, halfPointsBetweenLanes: Int((frame.lanesApart * 2).rounded()))
        if let moves = stacking.moves[layout] { return moves }
        let moves = LabelStacks.moves(of: labels.map { label in
            LabelStacks.Item(
                start: Double(label.step) * frame.spacing,
                width: label.width * scale,
                isAbove: label.isAbove,
                lowestTier: max(0, Int(((Double(abs(label.lane)) * frame.lanesApart - 4) / pitch).rounded(.up))),
                time: replay.commits[label.step].time
            )
        })
        stacking.moves[layout] = moves
        return moves
    }

    /// The index of the newest label whose commit is at or before `step`, or
    /// -1 if there's none.
    private func lastLabel(upTo step: Int) -> Int {
        var low = 0
        var high = labels.count - 1
        var found = -1
        while low <= high {
            let middle = (low + high) / 2
            if labels[middle].step <= step {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    /// The index of the oldest label at `step` or later.
    private func firstLabel(from step: Double) -> Int {
        var low = 0
        var high = labels.count
        while low < high {
            let middle = (low + high) / 2
            if Double(labels[middle].step) < step {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// The numbers at the top at one moment, each as it changes from one
    /// count to the next.
    struct Counts {
        var commits = RollingNumber.Change.still(0)
        var branches = RollingNumber.Change.still(0)
        var merges = RollingNumber.Change.still(0)
        var added = RollingNumber.Change.still(0)
        var removed = RollingNumber.Change.still(0)
    }

    func counts(_ frame: Frame) -> Counts {
        guard frame.head >= 0 else { return Counts() }
        let commits = replay.commits
        return Counts(
            commits: change(in: nil, frame) { $0 + 1 },
            branches: change(in: forkSteps, frame) { commits[$0].forksSoFar },
            merges: change(in: mergeSteps, frame) { commits[$0].mergesSoFar },
            added: change(in: addedSteps, frame) { commits[$0].linesSoFar.added },
            removed: change(in: removedSteps, frame) { commits[$0].linesSoFar.removed }
        )
    }

    /// How a number is changing at the frame's time: from what it was to what
    /// the newest commit that changed it made it, and how far through the
    /// roll. A roll ends before the next change starts, so a number that
    /// changes quickly rolls quickly.
    ///
    /// - Parameters:
    ///   - steps: The steps whose commits change the number, or nil if every
    ///     commit does.
    ///   - value: The number once a step's commit has landed.
    private func change(in steps: [Int]?, _ frame: Frame, value: (Int) -> Int) -> RollingNumber.Change {
        let step: Int
        let next: Int?
        if let steps {
            // The newest step at or before the newest commit.
            var low = 0
            var high = steps.count - 1
            var found = -1
            while low <= high {
                let middle = (low + high) / 2
                if steps[middle] <= frame.head {
                    found = middle
                    low = middle + 1
                } else {
                    high = middle - 1
                }
            }
            guard found >= 0 else { return .still(0) }
            step = steps[found]
            next = found + 1 < steps.count ? steps[found + 1] : nil
        } else {
            step = frame.head
            next = step + 1 < replay.commits.count ? step + 1 : nil
        }
        let start = replay.commits[step].time
        let room = next.map { replay.commits[$0].time - start } ?? .infinity
        let length = min(Self.roll, room * 0.8)
        return RollingNumber.Change(
            from: step > 0 ? value(step - 1) : 0,
            to: value(step),
            progress: length > 0 ? easeOut(clamp((frame.time - start) / length)) : 1
        )
    }

    /// The counts on one line under the date, in a narrow picture. Words after
    /// a number move along smoothly as it gains a digit.
    func drawStatLine(_ context: GraphicsContext, _ frame: Frame, _ counts: Counts, alpha: Double) {
        let theme = frame.theme
        let last = replay.commits.last
        let size = 13.0
        let baseline = 74.0
        let numbers = RollingNumber(context, size: size, weight: .semibold, color: theme.ink)
        var x = 16.0

        func separate() {
            x += Double(drawText(context, "·", size: size, color: theme.muted, x: x + 7, baseline: baseline, alpha: alpha).width) + 14
        }
        func number(_ rolling: RollingNumber, _ change: RollingNumber.Change, most: Int) {
            let windows = RollingNumber.windows(for: most)
            let width = rolling.shownWidth(change, windows: windows)
            rolling.draw(change, windows: windows, in: context, right: x + width, baseline: baseline, alpha: alpha)
            x += width
        }

        let line = [
            (counts.commits, replay.commits.count, "commits"),
            (counts.branches, last?.forksSoFar ?? 0, "branches"),
            (counts.merges, last?.mergesSoFar ?? 0, "merges"),
        ]
        for (index, (change, most, name)) in line.enumerated() {
            if index > 0 { separate() }
            number(numbers, change, most: most)
            x += Double(drawText(context, name, size: size, color: theme.muted, x: x + 4, baseline: baseline, alpha: alpha).width) + 4
        }
        if replay.hasLineCounts, let total = last?.linesSoFar {
            separate()
            number(RollingNumber(context, size: size, weight: .semibold, color: theme.added, sign: "+"), counts.added, most: total.added)
            x += 6
            number(RollingNumber(context, size: size, weight: .semibold, color: theme.removed, sign: "−"), counts.removed, most: total.removed)
        }
    }

    // MARK: - Pieces

    func point(_ frame: Frame, step: Int) -> CGPoint {
        let lane = Double(replay.branches[replay.commits[step].branch].lane)
        return CGPoint(x: frame.x(Double(step)), y: frame.y(lane))
    }

    func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// Cuts text to about `width`, going by an estimate rather than measuring,
    /// since this happens for many labels on every frame.
    func fitted(_ text: String, width: Double, size: Double) -> String {
        guard Self.estimatedWidth(text, size: size) > width else { return text }
        let characters = max(1, Int(width / (size * 0.54)) - 1)
        return String(text.prefix(characters)) + "…"
    }

    /// Draws text whose baseline is at `baseline`, and returns its size.
    @discardableResult
    func drawText(
        _ context: GraphicsContext,
        _ string: String,
        size: Double,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        color: Color,
        x: Double,
        baseline: Double,
        alignment: HorizontalAlignment = .leading,
        alpha: Double = 1,
        tracking: Double = 0
    ) -> CGSize {
        var context = context
        context.opacity = alpha
        let text = context.resolve(Text(string).font(.system(size: size, weight: weight, design: design)).tracking(tracking).foregroundStyle(color))
        let measured = text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
        let anchor: UnitPoint = alignment == .center ? .bottom : alignment == .trailing ? .bottomTrailing : .bottomLeading
        // The bottom of a line of text is below its baseline by its descent.
        context.draw(text, at: CGPoint(x: x, y: baseline + size * 0.24), anchor: anchor)
        return measured
    }

    /// Draws text, smaller if it wouldn't otherwise fit in `width`, and cut
    /// short if it's still too wide at half the size. Returns how wide it is.
    @discardableResult
    func drawFittingText(
        _ context: GraphicsContext,
        _ string: String,
        width: Double,
        size: Double,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        color: Color,
        x: Double,
        baseline: Double,
        alpha: Double = 1
    ) -> Double {
        let fitted = fitting(context, string, width: width, size: size, weight: weight, design: design)
        return Double(drawText(context, fitted.text, size: fitted.size, weight: weight, design: design, color: color, x: x, baseline: baseline, alpha: alpha).width)
    }

    /// Text made to fit in `width`: at a smaller size if it wouldn't
    /// otherwise, and cut short if it's still too wide at half the size.
    func fitting(
        _ context: GraphicsContext,
        _ string: String,
        width: Double,
        size: Double,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> (text: String, size: Double) {
        let measured = textWidth(context, string, size: size, weight: weight, design: design)
        let fitting = measured > width ? max(size * width / measured, size * 0.5) : size
        let text = measured * fitting / size > width ? fitted(string, width: width, size: fitting) : string
        return (text, fitting)
    }

    func textWidth(
        _ context: GraphicsContext,
        _ string: String,
        size: Double,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        tracking: Double = 0
    ) -> Double {
        let text = Text(string).font(.system(size: size, weight: weight, design: design)).tracking(tracking)
        return Double(context.resolve(text).measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width)
    }

    /// Breaks text into at most `maxLines` lines that fit `width`, and ends
    /// the last with an ellipsis if there's more.
    func wrapped(_ text: String, width: Double, size: Double, weight: NSFont.Weight = .regular, maxLines: Int) -> [String] {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight)]
        func fits(_ line: String) -> Bool { (line as NSString).size(withAttributes: attributes).width <= width }
        var lines: [String] = []
        var line = ""
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        while let word = words.first {
            let longer = line.isEmpty ? word : line + " " + word
            if fits(longer) || line.isEmpty {
                line = longer
                words = words.dropFirst()
            } else {
                lines.append(line)
                line = ""
                if lines.count == maxLines { break }
            }
        }
        if lines.count < maxLines, !line.isEmpty { lines.append(line) }
        guard var last = lines.last else { return [] }
        if !words.isEmpty || !fits(last) {
            while last.count > 1, !fits(last + "…") { last.removeLast() }
            lines[lines.count - 1] = last.trimmingCharacters(in: .whitespaces) + "…"
        }
        return lines
    }

    /// Draws pieces of text in a row, each in its own color, and returns how
    /// wide the row is.
    @discardableResult
    func drawRow(
        _ context: GraphicsContext,
        _ pieces: [(String, Color)],
        size: Double,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        spacing: Double,
        x: Double,
        baseline: Double,
        alignment: HorizontalAlignment = .leading,
        alpha: Double = 1
    ) -> Double {
        var context = context
        context.opacity = alpha
        let font = Font.system(size: size, weight: weight, design: design)
        let texts = pieces.map { piece in context.resolve(Text(piece.0).font(font).foregroundStyle(piece.1)) }
        let widths = texts.map { Double($0.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width) }
        let total = widths.reduce(0, +) + spacing * Double(max(texts.count - 1, 0))
        var left = alignment == .center ? x - total / 2 : alignment == .trailing ? x - total : x
        for (text, width) in zip(texts, widths) {
            context.draw(text, at: CGPoint(x: left, y: baseline + size * 0.24), anchor: .bottomLeading)
            left += width + spacing
        }
        return total
    }

}

/// A number in a row of digit windows, like an odometer's, that rolls from
/// one count to the next. Each digit that changes rolls straight from its old
/// value to its new one, up when the number grows and down when it shrinks,
/// and the digits that stay the same hold still.
///
/// It has as many windows as its largest count needs, and leaves the ones to
/// the left of the number blank, so a digit the number gains rolls in from
/// blank.
struct RollingNumber {
    /// A number changing from one count to another, `progress` of the way
    /// there, from 0 to 1.
    struct Change {
        var from: Int
        var to: Int
        var progress: Double

        static func still(_ value: Int) -> Change {
            Change(from: value, to: value, progress: 1)
        }
    }

    /// The character between each group of three digits.
    private static let groupSeparator = Locale.current.groupingSeparator ?? ","

    private let digits: [GraphicsContext.ResolvedText]
    private let separator: GraphicsContext.ResolvedText
    private let sign: GraphicsContext.ResolvedText?
    private let size: Double
    private let digitWidth: Double
    private let separatorWidth: Double
    private let signWidth: Double

    /// - Parameter sign: Text that goes just before the number, such as `+`.
    init(_ context: GraphicsContext, size: Double, weight: Font.Weight, color: Color, sign: String? = nil) {
        // Every digit is as wide as every other, so the windows line up.
        let font = Font.system(size: size, weight: weight).monospacedDigit()
        func resolve(_ string: String) -> GraphicsContext.ResolvedText {
            context.resolve(Text(string).font(font).foregroundStyle(color))
        }
        func width(_ text: GraphicsContext.ResolvedText) -> Double {
            Double(text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width)
        }
        let digits = (0 ... 9).map { resolve(String($0)) }
        let separator = resolve(Self.groupSeparator)
        let signText = sign.map(resolve)
        self.digits = digits
        self.separator = separator
        self.sign = signText
        self.size = size
        digitWidth = digits.map(width).max() ?? size * 0.6
        separatorWidth = width(separator)
        signWidth = signText.map(width) ?? 0
    }

    /// How many windows it takes to show every count up to `most`.
    static func windows(for most: Int) -> Int {
        digitCount(most)
    }

    /// How wide the number is with every window showing, sign and all.
    func width(windows: Int) -> Double {
        Double(windows) * digitWidth + Double((windows - 1) / 3) * separatorWidth + signWidth
    }

    /// How wide the number is partway through a change, sign and all. It
    /// grows smoothly as the number gains a digit.
    func shownWidth(_ change: Change, windows: Int) -> Double {
        signWidth - leftEdge(of: change, windows: windows, right: 0)
    }

    /// Draws a number partway through a change, with its right edge at
    /// `right`, and returns how wide it is.
    @discardableResult
    func draw(_ change: Change, windows count: Int, in context: GraphicsContext, right: Double, baseline: Double, alpha: Double) -> Double {
        let most = Self.largest(windows: count)
        let from = min(max(change.from, 0), most)
        let to = min(max(change.to, 0), most)
        let progress = min(max(change.progress, 0), 1)
        // How far a digit moves to make way for the next, which takes it out
        // of its window. The old digit leaves upward when the number grows.
        let travel = (to >= from ? -1.0 : 1.0) * size * 1.2
        // The bottom of a line of text is below its baseline by its descent.
        let bottom = baseline + size * 0.24
        var place = 1
        for index in 0 ..< max(Self.digitCount(from), Self.digitCount(to)) {
            let old = Self.digit(of: from, at: index, place: place)
            let new = Self.digit(of: to, at: index, place: place)
            place *= 10
            let edge = rightEdge(index, right)
            if index > 0, index % 3 == 0 {
                var faded = context
                faded.opacity = alpha * ((old == nil ? 0 : 1) * (1 - progress) + (new == nil ? 0 : 1) * progress)
                faded.draw(separator, at: CGPoint(x: edge, y: bottom), anchor: .bottomLeading)
            }
            let x = edge - digitWidth
            if old == new || progress >= 1 {
                guard let digit = progress >= 1 ? new : old else { continue }
                var still = context
                still.opacity = alpha
                still.draw(digits[digit], at: CGPoint(x: x, y: bottom), anchor: .bottomLeading)
                continue
            }
            var window = context
            window.clip(to: Path(CGRect(x: x - 1, y: baseline - size * 0.98, width: digitWidth + 2, height: size * 1.22)))
            if let old {
                window.opacity = alpha * (1 - 0.6 * progress)
                window.draw(digits[old], at: CGPoint(x: x, y: bottom + travel * progress), anchor: .bottomLeading)
            }
            if let new {
                window.opacity = alpha * (1 - 0.6 * (1 - progress))
                window.draw(digits[new], at: CGPoint(x: x, y: bottom - travel * (1 - progress)), anchor: .bottomLeading)
            }
        }
        let left = leftEdge(of: Change(from: from, to: to, progress: progress), windows: count, right: right)
        if let sign {
            var signed = context
            signed.opacity = alpha
            signed.draw(sign, at: CGPoint(x: left - signWidth, y: bottom), anchor: .bottomLeading)
        }
        return right - left + signWidth
    }

    /// The size of a row of tiles with a number on them, one digit each, the
    /// way a departure board shows them.
    struct Tiles {
        var width: Double
        var height: Double
        var fontSize: Double
        var gap: Double
        var separator: Double

        /// How wide a row is, with its sign if it has one.
        func rowWidth(windows: Int, isSigned: Bool) -> Double {
            Double(windows) * width + Double(windows - 1) * gap + Double((windows - 1) / 3) * separator + (isSigned ? fontSize * 0.62 + 5 : 0)
        }
    }

    /// Draws a number on a row of tiles partway through a change, with the
    /// right edge of the row at `right`. Every tile shows from the start, so
    /// the row doesn't change size, and one with no digit yet is blank.
    func drawTiles(
        _ change: Change,
        windows count: Int,
        tiles: Tiles,
        back: Color,
        edge: Color,
        split: Color,
        in context: GraphicsContext,
        right: Double,
        top: Double
    ) {
        let most = Self.largest(windows: count)
        let from = min(max(change.from, 0), most)
        let to = min(max(change.to, 0), most)
        let progress = min(max(change.progress, 0), 1)
        let travel = (to >= from ? -1.0 : 1.0) * tiles.height
        let bottom = top + tiles.height / 2 + size * 0.36 + size * 0.24

        var lefts: [Double] = []
        var backs = Path()
        var splits = Path()
        var x = right
        for index in 0 ..< count {
            if index > 0, index % 3 == 0 { x -= tiles.separator }
            let left = x - tiles.width
            lefts.append(left)
            backs.addRoundedRect(in: CGRect(x: left, y: top, width: tiles.width, height: tiles.height), cornerSize: CGSize(width: 4, height: 4))
            splits.addRect(CGRect(x: left + 0.5, y: top + tiles.height / 2 - 0.5, width: tiles.width - 1, height: 1))
            x = left - tiles.gap
        }
        context.fill(backs, with: .color(back))
        context.stroke(backs, with: .color(edge), lineWidth: 1)

        var place = 1
        for (index, left) in lefts.enumerated() {
            let old = Self.digit(of: from, at: index, place: place)
            let new = Self.digit(of: to, at: index, place: place)
            place *= 10
            if index > 0, index % 3 == 0 {
                var faded = context
                faded.opacity = (old == nil ? 0 : 1) * (1 - progress) + (new == nil ? 0 : 1) * progress
                faded.draw(separator, at: CGPoint(x: left + tiles.width + tiles.separator / 2, y: bottom), anchor: .bottom)
            }
            let digitX = left + (tiles.width - digitWidth) / 2
            if old == new || progress >= 1 {
                if let digit = progress >= 1 ? new : old {
                    context.draw(digits[digit], at: CGPoint(x: digitX, y: bottom), anchor: .bottomLeading)
                }
                continue
            }
            var window = context
            window.clip(to: Path(CGRect(x: left, y: top, width: tiles.width, height: tiles.height)))
            if let old { window.draw(digits[old], at: CGPoint(x: digitX, y: bottom + travel * progress), anchor: .bottomLeading) }
            if let new { window.draw(digits[new], at: CGPoint(x: digitX, y: bottom - travel * (1 - progress)), anchor: .bottomLeading) }
        }
        context.fill(splits, with: .color(split))
        if let sign, let leftmost = lefts.last {
            context.draw(sign, at: CGPoint(x: leftmost - 5, y: bottom), anchor: .bottomTrailing)
        }
    }

    /// How many digits a count has, which is 1 for 0.
    private static func digitCount(_ value: Int) -> Int {
        var count = 1
        var place = 10
        while place <= value {
            count += 1
            place *= 10
        }
        return count
    }

    /// The largest count that fits in `windows`.
    private static func largest(windows: Int) -> Int {
        var largest = 1
        for _ in 0 ..< windows { largest *= 10 }
        return largest - 1
    }

    /// A digit of a count, counting from the ones, or nil for a window to the
    /// left of the count, which stays blank.
    private static func digit(of value: Int, at index: Int, place: Int) -> Int? {
        index > 0 && value < place ? nil : value / place % 10
    }

    /// The right edge of a window, counting from the ones, with a separator
    /// to the left of every third one.
    private func rightEdge(_ index: Int, _ right: Double) -> Double {
        right - Double(index) * digitWidth - Double(index / 3) * separatorWidth
    }

    /// Where the number starts partway through a change, which moves smoothly
    /// as it gains or loses a digit.
    private func leftEdge(of change: Change, windows: Int, right: Double) -> Double {
        let most = Self.largest(windows: windows)
        func edge(_ value: Int) -> Double {
            rightEdge(Self.digitCount(min(max(value, 0), most)) - 1, right) - digitWidth
        }
        let progress = min(max(change.progress, 0), 1)
        return edge(change.from) + (edge(change.to) - edge(change.from)) * progress
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
    /// The band at the top and the strip at the bottom, and what sits on them.
    var band: Color
    var tile: Color
    var tileEdge: Color
    var tileSplit: Color
    /// The poster's tiles.
    var card: Color
    var house: Color
    var lanes: [Color]
    /// Lines added and removed, in the colors the rest of Roga gives them.
    var added: Color
    var removed: Color

    /// Each color theme's, in light and in dark. The paper, ink and tiles are
    /// the departure board's whichever theme is chosen, and the lanes and
    /// what changed are the theme's (decision 71).
    private static let themes = Dictionary(uniqueKeysWithValues: ColorTheme.allCases.map { colors in
        (colors, (light: theme(isDark: false, appearance: .aqua, colors: colors), dark: theme(isDark: true, appearance: .darkAqua, colors: colors)))
    })

    static func of(_ scheme: ColorScheme, colors: ColorTheme = ColorTheme.observed) -> MetroTheme {
        let theme = themes[colors] ?? themes[.monokai]!
        return scheme == .dark ? theme.dark : theme.light
    }

    private static func theme(isDark: Bool, appearance: NSAppearance.Name, colors: ColorTheme) -> MetroTheme {
        let palette = colors.colors
        let git = resolved((palette.lanes + [palette.added, palette.removed]).map(\.color), appearance)
        return MetroTheme(
            isDark: isDark,
            paper: Color(hex: isDark ? 0x16150E : 0xFAF6EE),
            ink: Color(hex: isDark ? 0xF5F0E6 : 0x16150E),
            muted: Color(hex: isDark ? 0xA9A394 : 0x6A665A),
            line: Color(hex: isDark ? 0x3A372D : 0xDCD5C6),
            accent: Color(hex: isDark ? 0xF2702E : 0xB53D00),
            band: Color(hex: isDark ? 0x1E1C14 : 0xF1EADC),
            tile: Color(hex: isDark ? 0x0D0C08 : 0xFFFDF8),
            tileEdge: Color(hex: isDark ? 0x34312A : 0xD6CEBC),
            tileSplit: isDark ? Color.black.opacity(0.55) : Color(hex: 0x16150E).opacity(0.14),
            card: Color(hex: isDark ? 0x1C1A12 : 0xFFFDF8),
            house: Color(hex: 0xD54802),
            lanes: Array(git.prefix(palette.lanes.count)),
            added: git[palette.lanes.count],
            removed: git[palette.lanes.count + 1]
        )
    }

    /// The graph's colors in one appearance, whatever the window's is.
    private static func resolved(_ colors: [NSColor], _ name: NSAppearance.Name) -> [Color] {
        var resolved: [Color] = []
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            resolved = colors.map { Color(nsColor: $0.usingColorSpace(.sRGB) ?? $0) }
        }
        return resolved
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

func clamp(_ value: Double, _ low: Double = 0, _ high: Double = 1) -> Double {
    min(high, max(low, value))
}

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}

func easeInOut(_ t: Double) -> Double {
    t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}

func easeOut(_ t: Double) -> Double {
    1 - pow(1 - t, 3)
}

func easeOutBack(_ t: Double) -> Double {
    let c = 1.9
    return t <= 0 ? 0 : 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2)
}
