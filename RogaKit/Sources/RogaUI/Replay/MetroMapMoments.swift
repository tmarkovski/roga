import CommitGraph
import GitCore
import SwiftUI

/// What happens on the map as records are set and days go by (decision 64).
extension MetroMap {
    /// How long a flare stays, and the least time between two of them, so
    /// that they don't land on top of each other.
    private static let flareLength = 2.6
    /// How long a day's name stays, and the least time between two of them.
    private static let gateLength = 2.2
    /// Only commits that changed more lines than this fly up to the count,
    /// and only this many of the biggest.
    private static let flightLeastLines = 900
    private static let mostFlights = 16

    /// A card that comes up over the commit that set a record.
    struct Flare {
        var step: Int
        var eyebrow: String
        var value: String
        var isAbove: Bool
    }

    static func lines(of commit: HistoryReplay.Commit) -> String {
        "+\(commit.lines.added.formatted()) −\(commit.lines.removed.formatted())"
    }

    static func date(of commit: HistoryReplay.Commit) -> Date {
        Date(timeIntervalSince1970: Double(commit.commitTime))
    }

    /// The records in a replay, in the order they land. When two would come
    /// up at nearly the same moment, the one earlier in this list wins.
    static func flares(of replay: HistoryReplay, _ highlights: HistoryReplay.Highlights) -> [Flare] {
        let commits = replay.commits
        var candidates: [Flare] = []
        if let step = highlights.biggestCommit {
            candidates.append(Flare(step: step, eyebrow: "BIGGEST COMMIT", value: lines(of: commits[step]), isAbove: true))
        }
        if let step = highlights.latestCommit, highlights.latestIsAtNight {
            candidates.append(Flare(step: step, eyebrow: "LATEST NIGHT", value: timeFormatter.string(from: date(of: commits[step])), isAbove: false))
        }
        if let branch = highlights.longestBranch, let merge = replay.branches[branch].merge {
            let value = "\(highlights.longestBranchCommits.formatted()) commits"
            candidates.append(Flare(step: merge, eyebrow: "LONGEST BRANCH", value: value, isAbove: true))
        }
        if let busiest = highlights.busiestDay {
            let day = highlights.days[busiest]
            let value = "\(day.commits.formatted()) commits on \(weekdayFormatter.string(from: day.start))"
            candidates.append(Flare(step: day.last, eyebrow: "BUSIEST DAY", value: value, isAbove: false))
        }
        var milestone = 100
        while milestone <= commits.count {
            let commit = commits[milestone - 1]
            candidates.append(Flare(step: milestone - 1, eyebrow: "\(milestone.formatted())TH COMMIT", value: weekdayAndDayFormatter.string(from: date(of: commit)), isAbove: true))
            milestone *= 10
        }

        var kept: [Flare] = []
        for flare in candidates where !kept.contains(where: { abs(commits[$0.step].time - commits[flare.step].time) < flareLength }) {
            kept.append(flare)
        }
        return kept.sorted { $0.step < $1.step }
    }

    static func flights(of replay: HistoryReplay) -> [Int] {
        let commits = replay.commits
        let big = commits.indices.filter { commits[$0].lines.added > 0 && commits[$0].lines.added + commits[$0].lines.removed > flightLeastLines }
        func lines(_ step: Int) -> Int { commits[step].lines.added + commits[step].lines.removed }
        return Array(big.sorted { lines($0) > lines($1) }.prefix(mostFlights))
    }

    /// Which days get their name across the picture: all of them in a short
    /// replay, and fewer the faster the days go by.
    static func gates(among markers: [Marker]) -> [Int] {
        var last = -Double.infinity
        return markers.indices.filter { index in
            guard markers[index].time - last >= gateLength else { return false }
            last = markers[index].time
            return true
        }
    }

    /// As a day starts, a line sweeps down the picture and the day's name
    /// comes up beside it.
    func drawGates(_ context: GraphicsContext, _ frame: Frame) {
        guard frame.finished == 0 else { return }
        let theme = frame.theme
        for index in gates {
            let marker = markers[index]
            let age = frame.time - marker.time
            guard age >= 0, age < Self.gateLength, marker.x >= frame.xMin, marker.x <= frame.xMax else { continue }
            let x = frame.x(marker.x)
            if age < 1.8 {
                var line = Path()
                line.move(to: CGPoint(x: x, y: frame.top + 8))
                line.addLine(to: CGPoint(x: x, y: frame.top + 8 + (frame.height - frame.bottom - frame.top - 16) * easeOut(clamp(age / 0.35))))
                var fading = context
                fading.opacity = 1 - clamp((age - 0.9) / 0.9)
                fading.stroke(line, with: .color(theme.ink), lineWidth: 1.5)
            }
            let alpha = clamp(age / 0.25) * (1 - clamp((age - 1.5) / 0.7))
            let rise = (1 - easeOut(clamp(age / 0.4))) * 8
            let day = highlights.days[index]
            let name = Self.weekdayFormatter.string(from: day.start).uppercased()
            drawText(context, name, size: 24, weight: .heavy, color: theme.ink, x: x + 6, baseline: frame.top + 46 + rise, alpha: alpha, tracking: 1.2)
            let detail = "Day \(day.number) of \(days)  ·  \(counted(day.commits, "commit"))"
            drawText(context, detail, size: 12, weight: .medium, color: theme.muted, x: x + 7, baseline: frame.top + 64 + rise, alpha: alpha)
        }
    }

    /// A big commit's lines rise off its stop and fly up into the count.
    func drawFlights(_ context: GraphicsContext, _ frame: Frame, to target: CGPoint) {
        guard frame.playing > 0 else { return }
        for step in flights {
            let commit = replay.commits[step]
            let age = frame.time - commit.time
            guard age >= 0.05, age <= 1.05 else { continue }
            let progress = easeInOut(clamp((age - 0.25) / 0.75))
            let start = point(frame, step: step)
            let x = lerp(start.x + 8, target.x, progress)
            let y = lerp(start.y - 44, target.y, progress)
            let size = lerp(26, 13, progress)
            let alpha = clamp((age - 0.05) / 0.18) * (1 - clamp((progress - 0.82) / 0.18)) * frame.playing

            let text = "+\(commit.lines.added.formatted())"
            var backing = context
            backing.opacity = alpha
            let width = Double(backing.resolve(Text(text).font(.system(size: size, weight: .heavy))).measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width)
            let box = CGRect(x: x - 8, y: y - size * 0.95, width: width + 16, height: size * 1.3)
            backing.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(frame.theme.paper))
            drawText(context, text, size: size, weight: .heavy, color: frame.theme.added, x: x, baseline: y, alpha: alpha)
        }
    }

    /// Rings go out from the commit that set a record, and a card stands over
    /// it on a thin line, saying which.
    func drawFlares(_ context: GraphicsContext, _ frame: Frame) {
        guard frame.playing > 0 else { return }
        let theme = frame.theme
        for flare in flares {
            let age = frame.time - replay.commits[flare.step].time
            guard age >= 0, age <= Self.flareLength else { continue }
            let center = point(frame, step: flare.step)
            for delay in [0, 0.22] {
                let progress = clamp((age - delay) / 0.9)
                guard progress > 0, progress < 1 else { continue }
                var ring = context
                ring.opacity = (1 - progress) * 0.7 * frame.playing
                ring.stroke(circle(center, 10 + 62 * easeOut(progress)), with: .color(theme.ink), lineWidth: 1.5)
            }

            let alpha = clamp(age / 0.2) * (1 - clamp((age - 2.1) / 0.5)) * frame.playing
            let grown = easeOutBack(clamp(age / 0.3))
            var card = context
            card.opacity = alpha
            let valueWidth = Double(card.resolve(Text(flare.value).font(.system(size: 19, weight: .heavy))).measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width)
            let width = max(valueWidth, 120) + 28
            let height = 54.0
            let side = flare.isAbove ? -1.0 : 1.0
            let middle = flare.isAbove
                ? max(frame.top + 8 + height / 2, center.y - 112)
                : min(frame.height - frame.bottom - 8 - height / 2, center.y + 112)
            let left = min(frame.width - width - 16, center.x - 20)

            var stem = Path()
            stem.move(to: CGPoint(x: center.x, y: center.y + side * 14))
            stem.addLine(to: CGPoint(x: center.x, y: middle - side * height / 2))
            card.stroke(stem, with: .color(theme.ink), lineWidth: 1.25)

            card.translateBy(x: left + width / 2, y: middle)
            card.scaleBy(x: grown, y: grown)
            card.translateBy(x: -(left + width / 2), y: -middle)
            card.fill(Path(roundedRect: CGRect(x: left, y: middle - height / 2, width: width, height: height), cornerRadius: 8), with: .color(theme.ink))
            drawText(card, flare.eyebrow, size: 9.5, weight: .bold, color: theme.paper, x: left + 14, baseline: middle - 8, alpha: alpha, tracking: 1.2)
            drawText(card, flare.value, size: 19, weight: .heavy, color: theme.paper, x: left + 14, baseline: middle + 15, alpha: alpha)
        }
    }

    /// The lane the newest commit has been in over the last half second, as
    /// an average, so that the house glides from one lane to the next as the
    /// camera glides along.
    private func houseLane(_ time: Double) -> Double {
        let samples = 16
        var sum = 0.0
        for sample in 0 ..< samples {
            let head = headAt(time - 0.5 * Double(sample) / Double(samples - 1))
            if head >= 0 { sum += Double(replay.branches[replay.commits[head].branch].lane) }
        }
        return sum / Double(samples)
    }

    /// The house, walking the line at the newest commit in decision 21's
    /// stride, where the camera is looking, so that the line slides along
    /// under its feet. It steps in time with the picture, and comes to rest on
    /// its still pose as the last commit lands.
    func drawHouse(_ context: GraphicsContext, _ frame: Frame) {
        guard frame.head >= 0 else { return }
        let time = min(frame.time, replay.playEnd)
        let x = frame.x(cameraX(time))
        let y = frame.y(houseLane(time)) - 2

        let motion = StrideMotion.push
        let pose = motion.pose(at: motion.stillPhase * motion.duration + min(frame.time, replay.playEnd) - replay.playEnd)
        drawHouse(context, pose, height: lerp(38, 24, frame.finished), color: frame.theme.house, centeredAt: x, floor: y)
    }

    /// Draws the house in a pose, with its feet on `floor`.
    func drawHouse(_ context: GraphicsContext, _ pose: HousePose, height: Double, color: Color, centeredAt x: Double, floor: Double) {
        let rig = HouseRig.frame
        let scale = height / rig.height
        var house = context
        house.translateBy(x: x - rig.width * scale / 2, y: floor - (HouseRig.floor - rig.minY) * scale)
        house.scaleBy(x: scale, y: scale)
        house.translateBy(x: -rig.minX, y: -rig.minY)
        HouseFigure.draw(pose, color: color, thickness: HouseFigure.thickness(forHeight: height), in: house)
    }
}
