import AppKit
import Testing
@testable import CommitGraph
@testable import HistoryUI

/// The graph's and the branches' colors, which have to read in both appearances
/// (decision 27).
@Suite(.timeLimit(.minutes(1)))
struct GitColorsTests {
    /// An appearance, with what a graph's lines and a row's text sit on.
    struct Look {
        let name: NSAppearance.Name
        let surface: CGFloat
        let selection: CGFloat
        let plainFill: Int
    }

    static let looks = [
        Look(name: .aqua, surface: 1, selection: 0.91, plainFill: 0xFFFFFF),
        Look(name: .darkAqua, surface: 0.135, selection: 0.245, plainFill: 0x2A2A29),
    ]

    private func components(_ color: NSColor, in look: Look) throws -> [CGFloat] {
        var result: [CGFloat] = []
        NSAppearance(named: look.name)?.performAsCurrentDrawingAppearance {
            if let resolved = color.usingColorSpace(.sRGB) {
                result = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
            }
        }
        return try #require(result.count == 3 ? result : nil)
    }

    private func luminance(_ components: [CGFloat]) -> CGFloat {
        let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private func contrast(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func luminance(ofGray white: CGFloat) -> CGFloat {
        luminance([white, white, white])
    }

    @Test func everyLaneReadsOnARowAndOnASelectedOne() throws {
        for look in Self.looks {
            for lane in GitColors.lanes + [GitColors.current] {
                let value = try luminance(components(lane, in: look))
                #expect(contrast(value, luminance(ofGray: look.surface)) >= 3)
                #expect(contrast(value, luminance(ofGray: look.selection)) >= 3)
            }
        }
    }

    @Test func textInTheseColorsIsReadable() throws {
        for look in Self.looks {
            let onCurrent = try contrast(luminance(components(GitColors.onCurrent, in: look)), luminance(components(GitColors.current, in: look)))
            #expect(onCurrent >= 4.5)
            let plain = try luminance(components(GitColors.color(light: look.plainFill, dark: look.plainFill), in: look))
            #expect(try contrast(luminance(components(GitColors.otherBranch, in: look)), plain) >= 4.5)
            for color in [GitColors.green, GitColors.red, GitColors.blue] {
                #expect(try contrast(luminance(components(color, in: look)), luminance(ofGray: look.surface)) >= 4.5)
            }
        }
    }

    @Test func neighboringColumnsDiffer() throws {
        for look in Self.looks {
            let lanes = try GitColors.lanes.map { try components($0, in: look) }
            #expect(lanes.count == LaneLayout.colors)
            for (index, lane) in lanes.enumerated() {
                #expect(lane != lanes[(index + 1) % lanes.count])
            }
        }
    }

    /// The ring is the color of the current branch's badge, and the dot inside it
    /// keeps its lane's color.
    @Test func theRingHasTheCurrentBranchsColorInLight() throws {
        try checkTheRing(in: Self.looks[0])
    }

    @Test func theRingHasTheCurrentBranchsColorInDark() throws {
        try checkTheRing(in: Self.looks[1])
    }

    private func checkTheRing(in look: Look) throws {
        var drawing: CurrentCommitRowTests.Drawing?
        var failure: (any Error)?
        NSAppearance(named: look.name)?.performAsCurrentDrawingAppearance {
            do {
                drawing = try CurrentCommitRowTests.Drawing(CurrentCommitRowTests.straightDown, isCurrent: true)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        let drawn = try #require(drawing)
        let ring = try #require(drawn.color(x: CurrentCommitRowTests.dotX + LaneRenderer.ringRadius, y: CurrentCommitRowTests.middle))
        let dot = try #require(drawn.color(x: CurrentCommitRowTests.dotX, y: CurrentCommitRowTests.middle))

        func distance(_ drawn: NSColor, to color: NSColor) throws -> CGFloat {
            var resolved: NSColor?
            NSAppearance(named: look.name)?.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.deviceRGB)
            }
            let target = try #require(resolved)
            let pixel = try #require(drawn.usingColorSpace(.deviceRGB))
            return abs(pixel.redComponent - target.redComponent)
                + abs(pixel.greenComponent - target.greenComponent)
                + abs(pixel.blueComponent - target.blueComponent)
        }
        let lane = GitColors.lanes[CurrentCommitRowTests.straightDown.color]
        #expect(try distance(ring, to: GitColors.current) < distance(ring, to: lane))
        #expect(try distance(dot, to: lane) < distance(dot, to: GitColors.current))
    }

    /// A line is drawn in its lane's color, whichever column it moves into,
    /// and a dot in its own lane's color rather than its column's.
    @Test func linesAndDotsHaveTheirLanesColors() throws {
        let look = Self.looks[1]
        let row = LaneLayout.Row(column: 0, color: 3, lines: [
            LaneLayout.Line(top: .column(4), bottom: .column(1), color: 2),
        ])
        var drawing: CurrentCommitRowTests.Drawing?
        NSAppearance(named: look.name)?.performAsCurrentDrawingAppearance {
            drawing = try? CurrentCommitRowTests.Drawing(row, isCurrent: false)
        }
        let drawn = try #require(drawing)

        // The lane whose color is nearest what was drawn at a point.
        func lane(x: CGFloat, y: CGFloat) throws -> Int {
            let pixel = try #require(drawn.color(x: x, y: y)?.usingColorSpace(.deviceRGB))
            let distances = try GitColors.lanes.map { color in
                var resolved: NSColor?
                NSAppearance(named: look.name)?.performAsCurrentDrawingAppearance {
                    resolved = color.usingColorSpace(.deviceRGB)
                }
                let target = try #require(resolved)
                return abs(pixel.redComponent - target.redComponent)
                    + abs(pixel.greenComponent - target.greenComponent)
                    + abs(pixel.blueComponent - target.blueComponent)
            }
            return try #require(distances.indices.min { distances[$0] < distances[$1] })
        }
        // Where the line reaches the second column, at the bottom of the row.
        let bottom = CGFloat(CurrentCommitRowTests.Drawing.height) - 1
        #expect(try lane(x: CurrentCommitRowTests.x(ofColumn: 1), y: bottom) == 2)
        #expect(try lane(x: CurrentCommitRowTests.dotX, y: CurrentCommitRowTests.middle) == 3)
    }
}
