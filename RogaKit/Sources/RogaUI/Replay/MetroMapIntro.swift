import CommitGraph
import GitCore
import SwiftUI

/// How a replay opens: on a title card that says what's about to play, over
/// the whole map as the replay leaves it. A saved video's first frame is what
/// most places show for it, so the card is all there from the first frame.
///
/// Then the card clears. The replay runs backward to before its first commit
/// while the camera goes to where that commit will land, the repository's
/// name shrinks into its place in the band, and the board comes in around it.
extension MetroMap {
    /// How long the card stays, and how long it takes to clear.
    static let introHold = 2.9
    static let introClear = 1.3
    static let intro = introHold + introClear

    /// Where the opening is at one moment.
    struct IntroMoment {
        /// How far through its stay the card is, from 0 to 1.
        var held: Double
        /// How far through clearing it is, from 0 to 1.
        var clearing: Double

        /// How visible everything on the card but the name is.
        var card: Double { 1 - clamp(clearing / 0.22) }
        /// How far back the replay has run, from its end to its start.
        var rewind: Double { easeInOut(clamp((clearing - 0.04) / 0.74)) }
        /// How far the camera and the name have gone to where they start.
        var move: Double { easeInOut(clamp((clearing - 0.1) / 0.86)) }
        /// How visible the band, the strip and the pulse are.
        var board: Double { clamp((clearing - 0.3) / 0.5) }
        /// How visible the branch's name is in the band, which waits for the
        /// repository's name to get there.
        var branch: Double { clamp((move - 0.8) / 0.2) }
    }

    func introMoment(at time: Double) -> IntroMoment? {
        guard time < Self.intro, !replay.commits.isEmpty else { return nil }
        return IntroMoment(held: clamp(time / Self.introHold), clearing: clamp((time - Self.introHold) / Self.introClear))
    }

    /// A number on the card, with what it counts under it.
    private struct IntroCount {
        var value: String
        var name: String
        var color: KeyPath<MetroTheme, Color>
        var isLines = false
    }

    /// What the band's numbers end on. A count of none is left out, since it
    /// says nothing about what's coming.
    private var introCounts: [IntroCount] {
        let last = replay.commits.last
        let commits = replay.commits.count
        let branches = last?.forksSoFar ?? 0
        let merges = last?.mergesSoFar ?? 0
        var counts = [IntroCount(value: commits.formatted(), name: commits == 1 ? "COMMIT" : "COMMITS", color: \.ink)]
        if branches > 0 {
            counts.append(IntroCount(value: branches.formatted(), name: branches == 1 ? "BRANCH" : "BRANCHES", color: \.ink))
        }
        if merges > 0 {
            counts.append(IntroCount(value: merges.formatted(), name: merges == 1 ? "MERGE" : "MERGES", color: \.ink))
        }
        if replay.hasLineCounts, let lines = last?.linesSoFar, lines.added + lines.removed > 0 {
            counts.append(IntroCount(value: "+\(lines.added.formatted())", name: "LINES ADDED", color: \.added, isLines: true))
            counts.append(IntroCount(value: "−\(lines.removed.formatted())", name: "LINES REMOVED", color: \.removed, isLines: true))
        }
        return counts
    }

    /// The branch and the dates the replay covers.
    private var introDetail: String {
        guard let first = replay.commits.first, let last = replay.commits.last else { return replay.mainLineName }
        let from = Self.rangeFormatter.string(from: Self.date(of: first))
        let to = Self.rangeFormatter.string(from: Self.date(of: last))
        return "\(replay.mainLineName)  ·  " + (from == to ? from : "\(from) to \(to)")
    }

    func drawIntro(_ context: GraphicsContext, _ frame: Frame, _ color: [Color], _ intro: IntroMoment) {
        let theme = frame.theme
        // Everything is sized from the picture, so a saved video and a small
        // window show the same card.
        let unit = min(frame.width / 1280, frame.height / 720)
        let margin = max(20, 72 * unit)
        let width = frame.width - margin * 2
        let rest = namePlace(context, frame)

        // The name is the band's, as large as fits the card, so that it's
        // the same text all the way to the band.
        let largest = min(170, max(44, 132 * unit))
        let titleSize = max(rest.size, min(largest, largest * width / textWidth(context, rest.text, size: largest, weight: rest.weight)))
        let eyebrowSize = max(13, 24 * unit)
        let detailSize = max(12, 22 * unit)
        let eyebrowBaseline = frame.height * 0.13 + eyebrowSize
        let titleBaseline = eyebrowBaseline + 14 * unit + titleSize * 0.74
        let detailBaseline = titleBaseline + titleSize * 0.24 + 10 * unit + detailSize

        // The numbers, without the lines if they'd run off the card, and
        // smaller if they still would.
        var counts = introCounts
        var countSize = max(18, 40 * unit)
        var captionSize = max(9, 11 * unit)
        var gap = max(18, 40 * unit)
        func widths() -> [Double] {
            counts.map { count in
                max(
                    textWidth(context, count.value, size: countSize, weight: .heavy),
                    textWidth(context, count.name, size: captionSize, weight: .semibold, tracking: 1)
                )
            }
        }
        func rowWidth() -> Double { widths().reduce(0, +) + gap * Double(counts.count - 1) }
        if rowWidth() > width { counts.removeAll(where: \.isLines) }
        let shrink = min(1, width / rowWidth())
        countSize *= shrink
        captionSize *= shrink
        gap *= shrink
        let countBaseline = detailBaseline + 30 * unit + countSize
        let captionBaseline = countBaseline + 7 * unit + captionSize

        let map = introMap(frame, intro, top: captionBaseline + 20 * unit, bottom: max(16, 40 * unit))
        drawDays(context, map)
        drawLines(context, map, color)
        drawCommits(context, map, color)

        let alpha = intro.card
        if alpha > 0 {
            drawText(context, rangeLine, size: eyebrowSize, weight: .bold, color: theme.muted, x: margin + 1, baseline: eyebrowBaseline, alpha: alpha, tracking: eyebrowSize * 0.12)
            drawBrandLine(context, frame, baseline: eyebrowBaseline, alpha: alpha, right: frame.width - margin)
            drawFittingText(context, introDetail, width: width, size: detailSize, weight: .medium, color: theme.muted, x: margin + 1, baseline: detailBaseline, alpha: alpha)
            var x = margin
            for (count, width) in zip(counts, widths()) {
                drawText(context, count.value, size: countSize, weight: .heavy, color: theme[keyPath: count.color], x: x, baseline: countBaseline, alpha: alpha)
                drawText(context, count.name, size: captionSize, weight: .semibold, color: theme.muted, x: x + 1, baseline: captionBaseline, alpha: alpha, tracking: 1)
                x += width + gap
            }
        }

        // The name goes from the card to its place in the band.
        let move = intro.move
        drawText(
            context,
            rest.text,
            size: move < 1 ? titleSize * pow(rest.size / titleSize, move) : rest.size,
            weight: rest.weight,
            color: theme.ink,
            x: lerp(margin, rest.x, move),
            baseline: lerp(titleBaseline, rest.baseline, move)
        )
    }

    /// The whole map as the replay leaves it, in the room the card gives it,
    /// growing a little so that the card isn't quite still. As the card
    /// clears, the map is drawn at earlier and earlier moments, and the
    /// camera goes to where it is when the replay starts.
    private func introMap(_ frame: Frame, _ intro: IntroMoment, top: Double, bottom: Double) -> Frame {
        let settled = lerp(0.97, 1, intro.held)
        let farthest = Double(max(replay.farthestLane, 1))
        // A short history is drawn up to twice as large as it plays, so
        // that a few commits don't leave the card looking empty.
        let fit = (frame.width - 48) / (Double(max(replay.commits.count - 1, 1)) * frame.spacing)
        let larger = max(1, min(2, fit))
        let wholeKx = frame.spacing * min(larger, fit) * settled
        let lanesApart = frame.lanesApart * 0.95 * larger
        let wholeKy = min(lanesApart, max(0, (frame.height - top - bottom) / 2 - 14) / farthest) * settled
        // Stops get smaller along with the lanes, or they'd run together
        // in a small picture.
        let roomyLanes = (frame.isSmall ? Self.smallLaneGap : Self.largeLaneGap) * 0.95
        let stops = lerp(0.62, 1, larger - 1) * clamp(wholeKy / roomyLanes, 0.55, 1)
        let move = intro.move
        var map = frame
        // From a little after the end, when the last commit's ring has gone.
        map.time = lerp(replay.playEnd + 1, replay.start, intro.rewind)
        map.head = headAt(map.time)
        map.finished = 1 - move
        map.kx = wholeKx * pow(frame.kx / wholeKx, move)
        map.ky = lerp(wholeKy, frame.ky, move)
        map.ox = lerp(frame.width / 2 - Double(replay.commits.count - 1) / 2 * wholeKx, frame.ox, move)
        map.top = lerp(top, frame.top, move)
        map.bottom = lerp(bottom, frame.bottom, move)
        map.oy = map.top + (frame.height - map.top - map.bottom) / 2
        map.dot = lerp(stops * settled, 1, move)
        return map
    }
}
