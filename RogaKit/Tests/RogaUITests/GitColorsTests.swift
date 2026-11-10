import AppKit
import Foundation
import Testing
@testable import CommitGraph
@testable import HistoryUI
import ThemeUI

/// The graph's and the branches' colors, which have to read in both appearances
/// in every color theme (decisions 27 and 71).
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

    /// A color's components in extended sRGB, so that a Display P3 color outside
    /// sRGB, as several of Xcode's are, keeps its value rather than being clipped.
    private func components(_ color: NSColor, in look: Look) throws -> [CGFloat] {
        var result: [CGFloat] = []
        NSAppearance(named: look.name)?.performAsCurrentDrawingAppearance {
            if let resolved = color.usingColorSpace(.extendedSRGB) {
                result = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
            }
        }
        return try #require(result.count == 3 ? result : nil)
    }

    private func luminance(_ components: [CGFloat]) -> CGFloat {
        let linear = components.map { value in
            let magnitude = abs(value)
            let linear = magnitude <= 0.04045 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
            return value < 0 ? -linear : linear
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private func contrast(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func luminance(ofGray white: CGFloat) -> CGFloat {
        luminance([white, white, white])
    }

    private func luminance(_ color: NSColor, in look: Look) throws -> CGFloat {
        try luminance(components(color, in: look))
    }

    @Test(arguments: ColorTheme.allCases)
    func everyLaneReadsOnARowAndOnASelectedOne(theme: ColorTheme) throws {
        let colors = theme.colors
        for look in Self.looks {
            for lane in colors.lanes + [colors.current] {
                let value = try luminance(lane.color, in: look)
                #expect(contrast(value, luminance(ofGray: look.surface)) >= 3, "\(theme) in \(look.name.rawValue)")
                #expect(contrast(value, luminance(ofGray: look.selection)) >= 3, "\(theme) in \(look.name.rawValue)")
            }
        }
    }

    @Test(arguments: ColorTheme.allCases)
    func textInTheseColorsIsReadable(theme: ColorTheme) throws {
        let colors = theme.colors
        for look in Self.looks {
            let surface = luminance(ofGray: look.surface)
            #expect(try contrast(luminance(colors.onCurrent.color, in: look), luminance(colors.current.color, in: look)) >= 4.5)
            #expect(try contrast(luminance(colors.onDanger.color, in: look), luminance(colors.removed.color, in: look)) >= 4.5)
            let plain = try luminance(GitColors.color(light: look.plainFill, dark: look.plainFill), in: look)
            #expect(try contrast(luminance(colors.otherBranch.color, in: look), plain) >= 4.5)
            for color in [colors.added, colors.removed, colors.moved, colors.ok, colors.ours, colors.theirs] {
                #expect(try contrast(luminance(color.color, in: look), surface) >= 4.5, "\(theme) in \(look.name.rawValue)")
            }
        }
    }

    /// The terminal block is dark in both appearances, and so are its colors.
    @Test(arguments: ColorTheme.allCases)
    func commandsReadInTheTerminal(theme: ColorTheme) throws {
        let colors = theme.colors
        let command = colors.command
        for look in Self.looks {
            let terminal = try luminance(colors.terminal.color, in: look)
            for color in [command.program, command.option, command.dangerousOption, command.value, command.text, command.prompt, command.output] {
                #expect(try contrast(luminance(color, in: look), terminal) >= 4.5, "\(theme) in \(look.name.rawValue)")
            }
        }
    }

    @Test(arguments: ColorTheme.allCases)
    func neighboringColumnsDiffer(theme: ColorTheme) throws {
        for look in Self.looks {
            let lanes = try theme.colors.lanes.map { try components($0.color, in: look) }
            #expect(lanes.count == LaneLayout.colors)
            for (index, lane) in lanes.enumerated() {
                #expect(lane != lanes[(index + 1) % lanes.count])
            }
        }
    }

    /// Roga starts in Monokai, and keeps a theme it doesn't know as Monokai.
    @Test func aStoredThemeIsMonokaiUnlessItSaysXcode() throws {
        let defaults = try #require(UserDefaults(suiteName: "ColorThemeTests.\(UUID().uuidString)"))
        #expect(ColorTheme.stored(in: defaults) == .monokai)
        defaults.set("xcode", forKey: ColorTheme.key)
        #expect(ColorTheme.stored(in: defaults) == .xcode)
        defaults.set("dracula", forKey: ColorTheme.key)
        #expect(ColorTheme.stored(in: defaults) == .monokai)
    }

    /// What AppKit views keep follows the theme in use, which is Monokai unless
    /// something chose another.
    @Test func colorsThatFollowTheThemeAreTheThemesOwn() throws {
        let look = Self.looks[1]
        #expect(try components(GitColors.current, in: look) == components(ColorTheme.current.colors.current.color, in: look))
        #expect(try components(GitColors.lanes[0], in: look) == components(ColorTheme.current.colors.lanes[0].color, in: look))
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
