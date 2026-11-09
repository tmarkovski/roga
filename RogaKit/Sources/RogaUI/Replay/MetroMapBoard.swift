import AppKit
import CommitGraph
import GitCore
import SwiftUI

/// The frame around the map (decision 64): a band across the top with the
/// numbers on tiles, like a departure board, a strip across the bottom that
/// says what just arrived, and under the band a pulse of how much every commit
/// changed.
extension MetroMap {
    static let bandHeight = 96.0
    static let stripHeight = 50.0
    static let pulseHeight = 60.0
    /// In a picture shorter than this, the pulse would leave too little of the map.
    static let pulseLeastHeight = 500.0

    private static let dateCellWidth = 196.0
    private static let leastNameWidth = 150.0
    private static let cellInset = 16.0

    /// How the numbers go in the band.
    struct BandFit {
        var tiles: RollingNumber.Tiles
        var showsDate: Bool
    }

    private static let largeTiles = RollingNumber.Tiles(width: 26, height: 42, fontSize: 26, gap: 2, separator: 8)
    private static let mediumTiles = RollingNumber.Tiles(width: 21, height: 36, fontSize: 22, gap: 2, separator: 7)
    private static let smallTiles = RollingNumber.Tiles(width: 17, height: 30, fontSize: 18, gap: 1.5, separator: 6)
    /// The ways to fit the band, starting with the one to use if there's room.
    private static let bandFits = [
        BandFit(tiles: largeTiles, showsDate: true),
        BandFit(tiles: mediumTiles, showsDate: true),
        BandFit(tiles: smallTiles, showsDate: true),
        BandFit(tiles: smallTiles, showsDate: false),
    ]

    private static let cellNameWidths: [String: Double] = {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .kern: 1]
        return Dictionary(uniqueKeysWithValues: ["MERGES", "BRANCHES", "COMMITS", "LINES REMOVED", "LINES ADDED"].map {
            ($0, ($0 as NSString).size(withAttributes: attributes).width)
        })
    }()

    private struct BandCell {
        var name: String
        /// The last count, which says how many tiles it needs.
        var most: Int
        var count: KeyPath<Counts, RollingNumber.Change>
        var color: KeyPath<MetroTheme, Color>
        var sign: String?
    }

    /// The numbers in the band, from the right. The lines come in once
    /// they're counted.
    private var bandCells: [BandCell] {
        let last = replay.commits.last
        var cells = [
            BandCell(name: "MERGES", most: last?.mergesSoFar ?? 0, count: \.merges, color: \.ink),
            BandCell(name: "BRANCHES", most: last?.forksSoFar ?? 0, count: \.branches, color: \.ink),
            BandCell(name: "COMMITS", most: replay.commits.count, count: \.commits, color: \.ink),
        ]
        if replay.hasLineCounts, let lines = last?.linesSoFar {
            cells.append(BandCell(name: "LINES REMOVED", most: lines.removed, count: \.removed, color: \.removed, sign: "−"))
            cells.append(BandCell(name: "LINES ADDED", most: lines.added, count: \.added, color: \.added, sign: "+"))
        }
        return cells
    }

    private func width(of cell: BandCell, _ tiles: RollingNumber.Tiles) -> Double {
        let row = tiles.rowWidth(windows: RollingNumber.windows(for: cell.most), isSigned: cell.sign != nil)
        return max(row, Self.cellNameWidths[cell.name] ?? 0)
    }

    /// The largest way the band fits a width, which depends only on the
    /// numbers' last counts, so that nothing changes size as they grow.
    func bandFit(width: Double) -> BandFit? {
        let cells = bandCells
        return Self.bandFits.first { fit in
            let numbers = cells.reduce(0) { $0 + self.width(of: $1, fit.tiles) + Self.cellInset * 2 }
            return numbers + (fit.showsDate ? Self.dateCellWidth : 0) + Self.leastNameWidth <= width
        }
    }

    /// The day a commit is in, as an index into the highlights' days.
    private func dayIndex(of step: Int) -> Int {
        let days = highlights.days
        var low = 0
        var high = days.count - 1
        var found = 0
        while low <= high {
            let middle = (low + high) / 2
            if days[middle].first <= step {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    /// Draws the band, and returns where the count of lines added is, once
    /// there's one for big commits to fly to.
    func drawBand(_ context: GraphicsContext, _ frame: Frame) -> CGPoint? {
        let theme = frame.theme
        context.fill(Path(CGRect(x: 0, y: 0, width: frame.width, height: Self.bandHeight)), with: .color(theme.band))
        context.fill(Path(CGRect(x: 0, y: Self.bandHeight - 1, width: frame.width, height: 1)), with: .color(theme.line))
        let counts = counts(frame)
        guard let fit = frame.band else {
            drawNarrowBand(context, frame, counts)
            return nil
        }

        var dividers = Path()
        var addedCount: CGPoint?
        var x = frame.width
        let tileTop = 34 + (Self.largeTiles.height - fit.tiles.height) / 2
        for cell in bandCells {
            let content = width(of: cell, fit.tiles)
            let right = x - Self.cellInset
            let number = RollingNumber(context, size: fit.tiles.fontSize, weight: .bold, color: theme[keyPath: cell.color], sign: cell.sign)
            number.drawTiles(
                counts[keyPath: cell.count],
                windows: RollingNumber.windows(for: cell.most),
                tiles: fit.tiles,
                back: theme.tile,
                edge: theme.tileEdge,
                split: theme.tileSplit,
                in: context,
                right: right,
                top: tileTop
            )
            drawText(context, cell.name, size: 10, weight: .semibold, color: theme.muted, x: right - content, baseline: 25, tracking: 1)
            if cell.sign == "+" { addedCount = CGPoint(x: right - content / 2, y: 54) }
            x = right - content - Self.cellInset
            dividers.addRect(CGRect(x: x, y: 0, width: 1, height: Self.bandHeight))
        }

        if fit.showsDate {
            let left = x - Self.dateCellWidth + 18
            if frame.head >= 0 {
                let date = Date(timeIntervalSince1970: Double(replay.commits[frame.head].commitTime))
                let day = highlights.days[dayIndex(of: frame.head)]
                drawText(context, "DAY \(day.number) OF \(days)", size: 10, weight: .semibold, color: theme.muted, x: left, baseline: 25, tracking: 1)
                drawText(context, Self.weekdayAndDayFormatter.string(from: date), size: 22, weight: .bold, color: theme.ink, x: left, baseline: 58)
                drawText(context, Self.timeFormatter.string(from: date), size: 13, weight: .medium, color: theme.muted, x: left, baseline: 79)
            }
            x -= Self.dateCellWidth
            dividers.addRect(CGRect(x: x, y: 0, width: 1, height: Self.bandHeight))
        }
        context.fill(dividers, with: .color(theme.line))

        drawFittingText(context, repositoryName, width: x - 32, size: 30, weight: .heavy, color: theme.ink, x: 16, baseline: 50)
        drawFittingText(context, replay.mainLineName, width: x - 32, size: 12, weight: .medium, color: theme.muted, x: 17, baseline: 76)
        return addedCount
    }

    /// The band of a picture too narrow for tiles, with the numbers on a line
    /// under the date.
    private func drawNarrowBand(_ context: GraphicsContext, _ frame: Frame, _ counts: Counts) {
        let theme = frame.theme
        let nameWidth = drawFittingText(context, repositoryName, width: frame.width * 0.6, size: 17, weight: .bold, color: theme.ink, x: 16, baseline: 32)
        drawFittingText(context, replay.mainLineName, width: frame.width - 48 - nameWidth, size: 12, weight: .medium, color: theme.muted, x: 16 + nameWidth + 8, baseline: 32)
        if frame.head >= 0 {
            let date = Date(timeIntervalSince1970: Double(replay.commits[frame.head].commitTime))
            let text = Self.weekdayAndDayFormatter.string(from: date) + ", " + Self.timeFormatter.string(from: date)
            drawText(context, text, size: 13, color: theme.muted, x: 16, baseline: 52)
        }
        drawStatLine(context, frame, counts, alpha: 1)
    }

    /// The strip across the bottom, which says what just arrived while the
    /// replay plays, and where the tour has got to after that.
    func drawStrip(_ context: GraphicsContext, _ frame: Frame, _ color: [Color], _ tour: TourMoment?) {
        let theme = frame.theme
        let top = frame.height - Self.stripHeight
        context.fill(Path(CGRect(x: 0, y: top, width: frame.width, height: Self.stripHeight)), with: .color(theme.band))
        context.fill(Path(CGRect(x: 0, y: top, width: frame.width, height: 1)), with: .color(theme.line))
        if let tour, tour.alpha > 0 {
            drawText(context, "HIGHLIGHT \(tour.index + 1) OF \(beats.count)", size: 10, weight: .semibold, color: theme.muted, x: 16, baseline: top + 30, alpha: tour.alpha, tracking: 1)
        }
        guard frame.head >= 0, frame.playing > 0 else { return }

        let commit = replay.commits[frame.head]
        let alpha = clamp((frame.time - commit.time) / 0.2) * frame.playing
        let tint = color[colorIndex(commit.branch)]
        let baseline = top + 31
        var dotX = 23.0
        if !frame.isSmall {
            drawText(context, "ARRIVING", size: 10, weight: .semibold, color: theme.muted, x: 16, baseline: baseline - 1, alpha: frame.playing, tracking: 1)
            dotX = 104
        }
        var dot = context
        dot.opacity = alpha
        dot.fill(circle(CGPoint(x: dotX, y: baseline - 5), 7), with: .color(tint))

        var x = dotX + 16
        x += drawText(context, String(commit.id.hex.prefix(7)), size: 12, design: .monospaced, color: tint, x: x, baseline: baseline, alpha: alpha).width + 12
        if replay.hasLineCounts, commit.lines.added + commit.lines.removed > 0 {
            x += drawRow(
                context,
                [("+\(commit.lines.added.formatted())", theme.added), ("−\(commit.lines.removed.formatted())", theme.removed)],
                size: 12,
                weight: .medium,
                design: .monospaced,
                spacing: 6,
                x: x,
                baseline: baseline,
                alpha: alpha
            ) + 12
        }
        var right = frame.width - 16
        let branch = replay.branches[commit.branch]
        if commit.branch != 0, !frame.isSmall, branch.name != HistoryReplay.unnamedBranch || branch.pullRequest != nil {
            let name = branch.name == HistoryReplay.unnamedBranch ? "" : branch.name
            let line = (branch.pullRequest.map { "#\($0) " } ?? "") + name
            right -= drawText(context, fitted(line, width: 220, size: 12), size: 12, weight: .medium, color: tint, x: right, baseline: baseline, alignment: .trailing, alpha: alpha).width + 20
        }
        drawText(context, fitted(commit.subject, width: right - x, size: 15), size: 15, color: theme.ink, x: x, baseline: baseline, alpha: alpha)
    }

    // MARK: - The pulse

    /// How much each commit changed, gathered into as many bars as can be
    /// told apart, so that drawing them costs the same for a whole history.
    struct Pulse {
        struct Bar {
            var first: Int
            var last: Int
            var added: Int
            var removed: Int
            var hasMerge: Bool
        }

        private static let mostBars = 480

        let bars: [Bar]
        let mostAdded: Int
        let mostRemoved: Int

        init(of replay: HistoryReplay) {
            let commits = replay.commits
            let perBar = max(1, (commits.count + Self.mostBars - 1) / Self.mostBars)
            bars = stride(from: 0, to: commits.count, by: perBar).map { first in
                let last = min(first + perBar, commits.count) - 1
                var bar = Bar(first: first, last: last, added: 0, removed: 0, hasMerge: false)
                for commit in commits[first ... last] {
                    bar.added += commit.lines.added
                    bar.removed += commit.lines.removed
                    bar.hasMerge = bar.hasMerge || commit.isMerge
                }
                return bar
            }
            mostAdded = max(1, bars.map(\.added).max() ?? 1)
            mostRemoved = max(1, bars.map(\.removed).max() ?? 1)
        }
    }

    /// The pulse, under the band. Each bar is at the same place across as its
    /// commit is once the camera has pulled back, so the two line up at the
    /// end of the zoom out.
    func drawPulse(_ context: GraphicsContext, _ frame: Frame) {
        let theme = frame.theme
        let count = replay.commits.count
        let top = Self.bandHeight + 4
        let middle = top + 34
        let scale = frame.spacing * frame.fitZoom
        func x(_ step: Double) -> Double { frame.width / 2 + (step - Double(count - 1) / 2) * scale }

        context.fill(Path(CGRect(x: 24, y: middle, width: frame.width - 48, height: 1)), with: .color(theme.line))
        let barStep = Double(pulse.bars.first.map { $0.last - $0.first + 1 } ?? 1) * scale
        let barWidth = min(10, max(1.5, barStep * 0.62))
        var added = Path()
        var removed = Path()
        var merges = Path()
        var waiting = Path()
        for bar in pulse.bars {
            let left = x(Double(bar.first + bar.last) / 2) - barWidth / 2
            let isDone = bar.last <= frame.head
            if bar.added > 0 {
                let height = (Double(bar.added) / Double(pulse.mostAdded)).squareRoot() * (44 - 12)
                let rect = CGRect(x: left, y: middle - height, width: barWidth, height: height)
                if isDone { added.addRect(rect) } else { waiting.addRect(rect) }
            }
            if bar.removed > 0 {
                let height = (Double(bar.removed) / Double(pulse.mostRemoved)).squareRoot() * 10
                let rect = CGRect(x: left, y: middle + 1, width: barWidth, height: height)
                if isDone { removed.addRect(rect) } else { waiting.addRect(rect) }
            }
            if bar.hasMerge {
                let rect = CGRect(x: left, y: middle - 2, width: barWidth, height: 3)
                if isDone { merges.addRect(rect) } else { waiting.addRect(rect) }
            }
        }
        context.fill(waiting, with: .color(theme.line))
        context.fill(added, with: .color(theme.added))
        context.fill(removed, with: .color(theme.removed))
        context.fill(merges, with: .color(theme.ink))

        // Days that would crowd each other only get a tick when they get a label.
        let leastBetweenTicks = Double(markers.count) * 12 > frame.width ? 44.0 : 3.0
        var ticks = Path()
        var lastTick = -Double.infinity
        var lastLabel = -Double.infinity
        for marker in markers {
            let tick = x(marker.x + 0.5) - 2
            guard tick - lastTick >= leastBetweenTicks else { continue }
            ticks.addRect(CGRect(x: tick, y: top + 4, width: 1, height: 52))
            lastTick = tick
            if tick - lastLabel > 44 {
                drawText(context, marker.label, size: 10, weight: .medium, color: theme.muted, x: tick + 4, baseline: top + 54)
                lastLabel = tick
            }
        }
        context.fill(ticks, with: .color(theme.line))

        guard frame.head >= 0, frame.finished < 1 else { return }
        let head = x(playheadX(min(frame.time, replay.playEnd)))
        var playhead = Path(CGRect(x: head - 0.75, y: top, width: 1.5, height: 56))
        playhead.move(to: CGPoint(x: head - 5, y: top))
        playhead.addLine(to: CGPoint(x: head + 5, y: top))
        playhead.addLine(to: CGPoint(x: head, y: top + 6))
        playhead.closeSubpath()
        var faded = context
        faded.opacity = 1 - frame.finished
        faded.fill(playhead, with: .color(theme.ink))
    }
}
