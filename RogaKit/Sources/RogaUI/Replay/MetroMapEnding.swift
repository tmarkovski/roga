import AppKit
import CommitGraph
import GitCore
import SwiftUI

/// How a replay ends (decision 64): the camera pulls back, a tour stops at
/// what stood out with the rest of the map turned down, and then the map
/// moves up to make room for a poster of the whole thing.
extension MetroMap {
    /// A replay with fewer commits than this has nothing worth a tour.
    private static let leastCommitsForTour = 12
    /// Where the map goes on the poster.
    static let posterTop = 104.0
    private static let posterBottomWithTiles = 290.0
    private static let posterBottomWithoutTiles = 60.0
    /// The poster only has tiles if the picture has room for them.
    private static let tilesLeastWidth = 900.0
    private static let tilesLeastHeight = 560.0

    // MARK: - The tour

    /// One stop on the tour.
    struct TourBeat {
        enum Focus {
            case commit(Int)
            case day(Int)
            case branch(Int)
        }

        var focus: Focus
        var eyebrow: String
        var value: String
        var valueIsAdded = false
        var detail: String
    }

    /// Where the tour is at one moment.
    struct TourMoment {
        /// How far the map is turned down, from 0 to 1.
        var dimming: Double
        var index: Int
        /// How visible the stop it's at is.
        var alpha: Double
        /// How long it has been at that stop.
        var elapsed: Double
    }

    static func beats(of replay: HistoryReplay, _ highlights: HistoryReplay.Highlights) -> [TourBeat] {
        guard replay.commits.count >= leastCommitsForTour else { return [] }
        let commits = replay.commits
        var beats: [TourBeat] = []
        if let step = highlights.biggestCommit {
            beats.append(TourBeat(focus: .commit(step), eyebrow: "THE BIGGEST COMMIT", value: lines(of: commits[step]), valueIsAdded: true, detail: commits[step].subject))
        }
        if let busiest = highlights.busiestDay {
            let day = highlights.days[busiest]
            let value = "\(weekdayFormatter.string(from: day.start)), \(dayFormatter.string(from: day.start))"
            // Saying how often only means something for a day with many.
            let often = day.commits >= 12 ? ", one for every \(24 * 60 / day.commits) minutes of the day" : ""
            beats.append(TourBeat(focus: .day(busiest), eyebrow: "THE BUSIEST DAY", value: value, detail: "\(day.commits.formatted()) commits\(often)"))
        }
        if let index = highlights.longestBranch {
            let number = replay.branches[index].pullRequest.map { "#\($0)  " } ?? ""
            let detail = number + title(ofBranch: index, in: replay)
            beats.append(TourBeat(focus: .branch(index), eyebrow: "THE LONGEST BRANCH", value: "\(highlights.longestBranchCommits.formatted()) commits", detail: detail))
        }
        if let step = highlights.latestCommit, highlights.latestIsAtNight {
            beats.append(TourBeat(focus: .commit(step), eyebrow: "THE LATEST NIGHT", value: timeFormatter.string(from: date(of: commits[step])), detail: commits[step].subject))
        }
        return beats
    }

    func tourMoment(at time: Double) -> TourMoment? {
        guard !beats.isEmpty, time >= tourStart, time <= tourStart + tourLength + 0.4 else { return nil }
        let intoTour = time - tourStart
        let index = max(0, min(beats.count - 1, Int(((intoTour - 0.2) / Self.beat).rounded(.down))))
        let elapsed = intoTour - 0.2 - Double(index) * Self.beat
        return TourMoment(
            dimming: clamp(intoTour / 0.4) * (1 - clamp((intoTour - tourLength + 0.1) / 0.5)),
            index: index,
            alpha: intoTour < 0.2 ? 0 : clamp(elapsed / 0.3) * (1 - clamp((elapsed - Self.beat + 0.3) / 0.3)),
            elapsed: elapsed
        )
    }

    /// Draws what the tour has stopped at back over the dimmed map, and a
    /// card about it, tied to it by a thin line.
    func drawTourFocus(_ context: GraphicsContext, _ frame: Frame, _ color: [Color], _ tour: TourMoment) {
        guard tour.alpha > 0 else { return }
        let theme = frame.theme
        let beat = beats[tour.index]
        let span = Double(replay.farthestLane) * frame.ky
        let focusX: Double
        let focusY: Double
        let side: Double
        let stemStart: Double
        switch beat.focus {
        case .commit(let step):
            let center = point(frame, step: step)
            focusX = center.x
            focusY = center.y
            side = tour.index == 0 ? -1 : 1
            stemStart = 34
            withOpacity(tour.alpha, context) { focus in
                drawLines(focus, frame, color, only: { candidate, _ in candidate == step })
                let tint = color[colorIndex(replay.commits[step].branch)]
                let throb = 1 + 0.05 * sin(tour.elapsed * 6)
                let grown = easeOutBack(clamp(tour.elapsed / 0.4))
                focus.fill(circle(center, 10 * grown), with: .color(tint))
                focus.stroke(circle(center, 18 * throb * grown), with: .color(theme.ink), lineWidth: 1.5)
                var outer = focus
                outer.opacity = 0.5
                outer.stroke(circle(center, 30 * throb * grown), with: .color(theme.ink), lineWidth: 1.5)
            }
        case .day(let index):
            let days = highlights.days
            let left = frame.x(Double(days[index].first) - 0.5)
            let right = frame.x(Double(index + 1 < days.count ? days[index + 1].first : replay.commits.count) - 0.5)
            focusX = (left + right) / 2
            focusY = frame.oy
            side = 1
            stemStart = span + 6
            withOpacity(tour.alpha, context) { focus in
                var band = focus
                band.opacity = 0.07
                band.fill(Path(CGRect(x: left, y: frame.top + 8, width: right - left, height: frame.height - frame.bottom - frame.top - 16)), with: .color(theme.ink))
                var clipped = focus
                clipped.clip(to: Path(CGRect(x: left, y: frame.top, width: right - left, height: frame.height - frame.top - frame.bottom)))
                drawLines(clipped, frame, color)
                drawCommits(clipped, frame, color)
            }
        case .branch(let index):
            let branch = replay.branches[index]
            focusX = frame.x(Double(branch.first + (branch.merge ?? branch.first)) / 2)
            focusY = frame.y(Double(branch.lane))
            side = branch.lane < 0 ? -1 : 1
            stemStart = 12
            withOpacity(tour.alpha, context) { focus in
                drawLines(focus, frame, color, only: { step, commit in commit.branch == index || step == branch.merge }, lineWidth: 3.2)
                drawCommits(focus, frame, color, only: { _, commit in commit.branch == index })
            }
        }

        let cardWidth = min(470, frame.width - 64)
        let left = clamp(focusX - 40, 32, frame.width - cardWidth - 32)
        let detail = wrapped(beat.detail, width: cardWidth, size: 16, maxLines: 2)
        let blockHeight = 18 + 46 + Double(detail.count) * 22 + 8
        let wanted = side < 0 ? frame.oy - span - 34 - blockHeight : frame.oy + span + 34
        let rest = min(frame.height - frame.bottom - blockHeight - 10, max(wanted, frame.top + 10))
        let top = rest + (1 - easeOut(clamp(tour.elapsed / 0.4))) * 10 * side

        var stem = Path()
        stem.move(to: CGPoint(x: focusX, y: focusY + side * stemStart))
        stem.addLine(to: CGPoint(x: focusX, y: side < 0 ? top + blockHeight + 2 : top - 2))
        var line = context
        line.opacity = tour.alpha
        line.stroke(stem, with: .color(theme.ink), lineWidth: 1)

        var backing = context
        backing.opacity = tour.alpha * 0.86
        backing.fill(Path(roundedRect: CGRect(x: left - 12, y: top - 6, width: cardWidth + 24, height: blockHeight + 12), cornerRadius: 10), with: .color(theme.paper))

        drawText(context, beat.eyebrow, size: 11, weight: .bold, color: theme.muted, x: left, baseline: top + 12, alpha: tour.alpha, tracking: 1.6)
        drawFittingText(context, beat.value, width: cardWidth, size: frame.isSmall ? 30 : 42, weight: .heavy, color: beat.valueIsAdded ? theme.added : theme.ink, x: left, baseline: top + 56, alpha: tour.alpha)
        for (index, text) in detail.enumerated() {
            drawText(context, text, size: 16, color: theme.ink, x: left, baseline: top + 84 + Double(index) * 22, alpha: tour.alpha * 0.92)
        }
    }

    // MARK: - The poster

    enum PosterTile {
        case busiestDay(Int)
        case biggestCommit(Int)
        case longestBranch(Int)
        case hours(latest: Int)
    }

    static func tiles(of replay: HistoryReplay, _ highlights: HistoryReplay.Highlights) -> [PosterTile] {
        var tiles: [PosterTile] = []
        if let busiest = highlights.busiestDay { tiles.append(.busiestDay(busiest)) }
        if let step = highlights.biggestCommit { tiles.append(.biggestCommit(step)) }
        if let branch = highlights.longestBranch { tiles.append(.longestBranch(branch)) }
        if let step = highlights.latestCommit { tiles.append(.hours(latest: step)) }
        // One tile on its own looks like something went missing.
        return tiles.count > 1 ? tiles : []
    }

    private func showsTiles(width: Double, height: Double) -> Bool {
        !tiles.isEmpty && width >= Self.tilesLeastWidth && height >= Self.tilesLeastHeight
    }

    func posterBottom(width: Double, height: Double) -> Double {
        showsTiles(width: width, height: height) ? Self.posterBottomWithTiles : Self.posterBottomWithoutTiles
    }

    func drawPoster(_ context: GraphicsContext, _ frame: Frame) {
        let elapsed = frame.time - posterStart
        guard elapsed > 0, let first = replay.commits.first, let last = replay.commits.last else { return }
        if showsTiles(width: frame.width, height: frame.height) { drawTiles(context, frame, elapsed: elapsed) }

        let alpha = clamp((elapsed - 0.9) / 0.6)
        guard alpha > 0 else { return }
        let theme = frame.theme
        let margin = frame.isSmall ? 16.0 : 32.0
        let scale = frame.isSmall ? 0.68 : 1.0
        var titleWidth = frame.width - margin * 2
        if replay.hasLineCounts {
            let lines = last.linesSoFar
            let added = drawText(context, "+\(lines.added.formatted())", size: 30 * scale, weight: .heavy, color: theme.added, x: frame.width - margin, baseline: 54 * lerp(0.8, 1, scale), alignment: .trailing, alpha: alpha)
            drawText(context, "−\(lines.removed.formatted())", size: 20 * scale, weight: .bold, color: theme.removed, x: frame.width - margin, baseline: 82 * lerp(0.84, 1, scale), alignment: .trailing, alpha: alpha)
            titleWidth -= Double(added.width) + 24
        }
        let title = "\(counted(replay.commits.count, "commit")), \(counted(replay.branches.count - 1, "branch", plural: "branches")), \(counted(days, "day"))"
        drawFittingText(context, title, width: titleWidth, size: 36 * scale, weight: .heavy, color: theme.ink, x: margin, baseline: 58 * lerp(0.8, 1, scale), alpha: alpha)
        let from = Self.rangeFormatter.string(from: Self.date(of: first))
        let to = Self.rangeFormatter.string(from: Self.date(of: last))
        drawFittingText(context, "\(repositoryName)  ·  \(from) to \(to)", width: titleWidth, size: 14, color: theme.muted, x: margin, baseline: 84 * lerp(0.84, 1, scale), alpha: alpha)
        drawBrandLine(context, frame, baseline: frame.height - 16, alpha: alpha)
    }

    private func drawBrandLine(_ context: GraphicsContext, _ frame: Frame, baseline: Double, alpha: Double) {
        let label = "Replayed in Roga"
        let height = 20.0
        let houseWidth = HouseRig.frame.width * height / HouseRig.frame.height
        let labelWidth = Double(context.resolve(Text(label).font(.system(size: 13, weight: .medium))).measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width)
        let left = frame.width / 2 - (houseWidth + 6 + labelWidth) / 2
        withOpacity(alpha, context) { faded in
            drawHouse(faded, .mark, height: height, color: frame.theme.house, centeredAt: left + houseWidth / 2, floor: baseline + 3)
        }
        drawText(context, label, size: 13, weight: .medium, color: frame.theme.muted, x: left + houseWidth + 6, baseline: baseline, alpha: alpha)
    }

    /// The tiles along the bottom of the poster, which rise in one after
    /// another.
    private func drawTiles(_ context: GraphicsContext, _ frame: Frame, elapsed: Double) {
        let theme = frame.theme
        let margin = 32.0
        let gap = 12.0
        let count = Double(tiles.count)
        let width = min(300, (frame.width - margin * 2 - gap * (count - 1)) / count)
        let total = width * count + gap * (count - 1)
        let height = 228.0
        for (index, tile) in tiles.enumerated() {
            let progress = easeOut(clamp((elapsed - 0.55 - Double(index) * 0.12) / 0.6))
            guard progress > 0 else { continue }
            let x = (frame.width - total) / 2 + Double(index) * (width + gap)
            let y = frame.height - 278 + (1 - progress) * 26
            withOpacity(progress, context) { faded in
                let box = Path(roundedRect: CGRect(x: x + 0.5, y: y + 0.5, width: width - 1, height: height - 1), cornerRadius: 12)
                faded.fill(box, with: .color(theme.card))
                faded.stroke(box, with: .color(theme.line), lineWidth: 1)
                drawTile(tile, faded, theme, x: x + 16, y: y, width: width - 32)
            }
        }
    }

    private func drawEyebrow(_ context: GraphicsContext, _ theme: MetroTheme, _ text: String, x: Double, y: Double) {
        drawText(context, text, size: 10, weight: .bold, color: theme.muted, x: x, baseline: y + 28, tracking: 1.4)
    }

    private func drawTile(_ tile: PosterTile, _ context: GraphicsContext, _ theme: MetroTheme, x: Double, y: Double, width: Double) {
        switch tile {
        case .busiestDay(let index):
            drawBusiestDay(index, context, theme, x: x, y: y, width: width)
        case .biggestCommit(let step):
            let commit = replay.commits[step]
            drawEyebrow(context, theme, "BIGGEST COMMIT", x: x, y: y)
            drawFittingText(context, "+\(commit.lines.added.formatted())", width: width, size: 34, weight: .heavy, color: theme.added, x: x, baseline: y + 66)
            drawFittingText(context, "−\(commit.lines.removed.formatted()) lines removed", width: width, size: 13, weight: .medium, color: theme.removed, x: x, baseline: y + 90)
            for (index, line) in wrapped(commit.subject, width: width, size: 15, weight: .medium, maxLines: 4).enumerated() {
                drawText(context, line, size: 15, weight: .medium, color: theme.ink, x: x, baseline: y + 126 + Double(index) * 20)
            }
            let hash = String(commit.id.hex.prefix(7))
            drawFittingText(context, "\(hash)  ·  \(Self.weekdayAndDayFormatter.string(from: Self.date(of: commit)))", width: width, size: 11, design: .monospaced, color: theme.muted, x: x, baseline: y + 212)
        case .longestBranch(let index):
            drawLongestBranch(index, context, theme, x: x, y: y, width: width)
        case .hours(let step):
            drawHours(latest: step, context, theme, x: x, y: y, width: width)
        }
    }

    private func drawBusiestDay(_ index: Int, _ context: GraphicsContext, _ theme: MetroTheme, x: Double, y: Double, width: Double) {
        let days = highlights.days
        let day = days[index]
        drawEyebrow(context, theme, "BUSIEST DAY", x: x, y: y)
        drawFittingText(context, Self.weekdayFormatter.string(from: day.start), width: width, size: 26, weight: .heavy, color: theme.ink, x: x, baseline: y + 62)
        drawFittingText(context, "\(day.commits.formatted()) commits on \(Self.dayFormatter.string(from: day.start))", width: width, size: 13, color: theme.muted, x: x, baseline: y + 84)

        // A bar for each day, or for each few days of a long replay.
        let perBar = max(1, (days.count + 39) / 40)
        let isOnePerDay = perBar == 1
        let counts = stride(from: 0, to: days.count, by: perBar).map { first in
            days[first ..< min(first + perBar, days.count)].reduce(0) { $0 + $1.commits }
        }
        let gap = counts.count > 14 ? 2.0 : 5.0
        let barWidth = (width - Double(counts.count - 1) * gap) / Double(counts.count)
        let most = Double(max(counts.max() ?? 1, 1))
        let base = y + 196
        var others = Path()
        var busiest = Path()
        for (bar, commits) in counts.enumerated() {
            let height = Double(commits) / most * 84
            let left = x + Double(bar) * (barWidth + gap)
            let rect = CGRect(x: left, y: base - height, width: barWidth, height: height)
            let isBusiest = bar == index / perBar
            if isBusiest {
                busiest.addRoundedRect(in: rect, cornerSize: CGSize(width: 2.5, height: 2.5))
            } else {
                others.addRoundedRect(in: rect, cornerSize: CGSize(width: 2.5, height: 2.5))
            }
            if isOnePerDay, counts.count <= 14 {
                let letter = Self.narrowWeekdayFormatter.string(from: days[bar].start)
                drawText(context, letter, size: 10, weight: .medium, color: isBusiest ? theme.ink : theme.muted, x: left + barWidth / 2, baseline: base + 16, alignment: .center)
            }
        }
        context.fill(others, with: .color(theme.line))
        context.fill(busiest, with: .color(theme.ink))
    }

    private func drawLongestBranch(_ index: Int, _ context: GraphicsContext, _ theme: MetroTheme, x: Double, y: Double, width: Double) {
        let branch = replay.branches[index]
        let tint = theme.lanes[branch.color]
        drawEyebrow(context, theme, "LONGEST BRANCH", x: x, y: y)
        drawFittingText(context, "\(highlights.longestBranchCommits.formatted()) commits", width: width, size: 26, weight: .heavy, color: theme.ink, x: x, baseline: y + 62)

        let lineY = y + 96
        var line = Path()
        line.move(to: CGPoint(x: x + 4, y: lineY))
        line.addLine(to: CGPoint(x: x + width - 4, y: lineY))
        context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        var stops = Path()
        let stopCount = min(highlights.longestBranchCommits, 32)
        for stop in 0 ..< stopCount {
            stops.addPath(circle(CGPoint(x: x + 4 + Double(stop) * (width - 8) / Double(max(stopCount - 1, 1)), y: lineY), 4))
        }
        context.fill(stops, with: .color(tint))

        if let number = branch.pullRequest.map({ "#\($0)" }) ?? (branch.name == HistoryReplay.unnamedBranch ? nil : branch.name) {
            drawFittingText(context, number, width: width, size: 13, weight: .bold, color: tint, x: x, baseline: y + 130)
        }
        let title = branch.pullRequest != nil || branch.name == HistoryReplay.unnamedBranch
            ? Self.title(ofBranch: index, in: replay)
            : replay.commits[branch.first].subject
        for (line, text) in wrapped(title, width: width, size: 15, weight: .medium, maxLines: 3).enumerated() {
            drawText(context, text, size: 15, weight: .medium, color: theme.ink, x: x, baseline: y + 152 + Double(line) * 20)
        }
    }

    private func drawHours(latest step: Int, _ context: GraphicsContext, _ theme: MetroTheme, x: Double, y: Double, width: Double) {
        let date = Self.date(of: replay.commits[step])
        drawEyebrow(context, theme, "WHEN IT HAPPENED", x: x, y: y)
        drawFittingText(context, Self.timeFormatter.string(from: date), width: width, size: 26, weight: .heavy, color: theme.ink, x: x, baseline: y + 62)
        drawText(context, "the latest it got", size: 13, color: theme.muted, x: x, baseline: y + 84)

        let latestHour = Calendar.current.component(.hour, from: date)
        let most = Double(max(highlights.commitsByHour.max() ?? 1, 1))
        let barWidth = (width - 23 * 2) / 24
        let base = y + 196
        var day = Path()
        var night = Path()
        var latest = Path()
        for (hour, commits) in highlights.commitsByHour.enumerated() {
            let height = max(1.5, Double(commits) / most * 84)
            let rect = CGRect(x: x + Double(hour) * (barWidth + 2), y: base - height, width: barWidth, height: height)
            if hour == latestHour {
                latest.addRoundedRect(in: rect, cornerSize: CGSize(width: 1.5, height: 1.5))
            } else if hour < 6 || hour > 21 {
                night.addRoundedRect(in: rect, cornerSize: CGSize(width: 1.5, height: 1.5))
            } else {
                day.addRoundedRect(in: rect, cornerSize: CGSize(width: 1.5, height: 1.5))
            }
        }
        context.fill(day, with: .color(theme.line))
        context.fill(night, with: .color(theme.muted))
        context.fill(latest, with: .color(theme.ink))
        for hour in stride(from: 0, to: 24, by: 6) {
            drawText(context, Self.hourLabels[hour / 6], size: 10, weight: .medium, color: theme.muted, x: x + Double(hour) * (barWidth + 2), baseline: y + 212)
        }
    }

    /// Midnight, 6, noon and 6, as the viewer's clock says them.
    private static let hourLabels: [String] = {
        let hours = MetroMap.formatter("j")
        let midnight = Calendar.current.startOfDay(for: Date())
        return stride(from: 0, to: 24, by: 6).map { hours.string(from: midnight.addingTimeInterval(Double($0) * 3600)) }
    }()
}
