import AppKit

/// One color of a theme, with a value for each appearance.
public struct ThemeColor: Sendable {
    public let light: NSColor
    public let dark: NSColor
    /// The color in whichever appearance it's drawn in, for views that take a
    /// color once and redraw when the theme changes, such as SwiftUI's.
    public let color: NSColor

    public init(light: NSColor, dark: NSColor) {
        self.light = light
        self.dark = dark
        color = NSColor(name: nil) { $0.isDark ? dark : light }
    }

    /// Hex values in sRGB, which Monokai's are.
    init(srgb light: Int, _ dark: Int) {
        self.init(light: .srgb(light), dark: .srgb(dark))
    }

    /// Hex values in Display P3, which Xcode draws its theme's colors in. Several
    /// of them are outside sRGB, so they'd lose some of their color in it.
    init(p3 light: Int, _ dark: Int) {
        self.init(light: .displayP3(light), dark: .displayP3(dark))
    }

    /// The same color in both appearances.
    init(fixed: NSColor) {
        self.init(light: fixed, dark: fixed)
    }

    /// The value for an appearance.
    public func resolved(for appearance: NSAppearance) -> NSColor {
        appearance.isDark ? dark : light
    }
}

/// What a theme colors: the graph and the branches, what changed, the sides of a
/// conflict and the commands in a terminal block (decision 71). Everything else
/// keeps Roga's own colors whichever theme is chosen: the neutral surfaces and
/// text, the orange of what runs something (decision 19), an agent's amber and
/// blue, and remote branches' and tags' warm gray.
public struct ThemeColors: Sendable {
    /// The colors the graph's lanes take turns with, one for each of
    /// `LaneLayout.colors`. Neither theme has an orange among them, because
    /// orange means a click would run something (decision 19).
    public let lanes: [ThemeColor]
    /// The current branch wherever it shows: its badge's fill, the ring around the
    /// commit `HEAD` is on, and its icon in the refs panel.
    public let current: ThemeColor
    /// Text on the current branch's badge.
    public let onCurrent: ThemeColor
    /// The name of any other local branch.
    public let otherBranch: ThemeColor
    /// What was added, and commits ahead of the upstream, as text and marks.
    public let added: ThemeColor
    /// What was removed, commits behind the upstream, conflicts and what's
    /// dangerous, as text, marks and the fill of a destructive button.
    public let removed: ThemeColor
    /// What was moved or copied.
    public let moved: ThemeColor
    /// The tint behind an added line of a diff, and the bar beside it.
    public let diffAdded: ThemeColor
    /// The tint behind a removed line of a diff, and the stripes beside it.
    public let diffRemoved: ThemeColor
    /// The side of a conflict that's the current branch's.
    public let ours: ThemeColor
    /// The side of a conflict that's coming in.
    public let theirs: ThemeColor
    /// What works, such as an agent's hooks that are installed.
    public let ok: ThemeColor
    /// Text on a destructive button, which `removed` fills.
    public let onDanger: ThemeColor
    /// The terminal block under a dialog, which stays dark in both appearances.
    public let terminal: ThemeColor
    /// The parts of a command in the terminal block, which are the same in both
    /// appearances because the block is dark in both.
    public let command: CommandColors
}

/// How the terminal block colors a command and what it printed.
public struct CommandColors: Sendable {
    /// `git` and its subcommand, or a program and its subcommands.
    public let program: NSColor
    public let option: NSColor
    /// An option that makes the command able to lose something.
    public let dangerousOption: NSColor
    /// A branch, a remote, a path or another value.
    public let value: NSColor
    /// Words someone wrote, such as a commit's message.
    public let text: NSColor
    /// The `$` before a command, and comments.
    public let prompt: NSColor
    /// What a command printed.
    public let output: NSColor
}

extension ThemeColors {
    /// Monokai's colors (decision 27). Dark mode uses Monokai's own values, moved
    /// only where a line wouldn't read on a selected row. Classic Monokai has no
    /// light theme, so light mode has a deeper version of each. A diff's tints
    /// stay the system's green and red, as they were before there were themes.
    static let monokai = ThemeColors(
        lanes: [
            ThemeColor(srgb: 0xDB1C61, 0xFF3478), // Pink
            ThemeColor(srgb: 0x10819E, 0x66D9EF), // Sky
            ThemeColor(srgb: 0x608A00, 0xA6E22E), // Green
            ThemeColor(srgb: 0x7240C0, 0xAE81FF), // Violet
            ThemeColor(srgb: 0x968505, 0xE6DB74), // Yellow
            ThemeColor(srgb: 0x2552AA, 0x6796E6), // Blue
            ThemeColor(srgb: 0x676450, 0xA59F85), // Stone
            ThemeColor(srgb: 0x0D906D, 0xA1EFE4), // Seafoam
        ],
        current: ThemeColor(srgb: 0x547A02, 0xA6E22E),
        onCurrent: ThemeColor(srgb: 0xFFFFFF, 0x272822),
        otherBranch: ThemeColor(srgb: 0x00566E, 0x66D9EF),
        added: ThemeColor(srgb: 0x4D7000, 0xA6E22E),
        removed: ThemeColor(srgb: 0xCD1755, 0xFC5884),
        moved: ThemeColor(srgb: 0x036E8B, 0x66D9EF),
        diffAdded: ThemeColor(fixed: .systemGreen),
        diffRemoved: ThemeColor(fixed: .systemRed),
        ours: ThemeColor(srgb: 0x2559B0, 0x8FB4F7),
        theirs: ThemeColor(srgb: 0x7136B8, 0xC4A2FF),
        ok: ThemeColor(srgb: 0x3F7D00, 0xA6E22E),
        onDanger: ThemeColor(srgb: 0xFFFFFF, 0x272822),
        // Monokai's background, which nearly matches a dialog's surface in dark
        // mode, so that goes darker.
        terminal: ThemeColor(srgb: 0x272822, 0x1A1B17),
        command: CommandColors(
            program: .srgb(0xF8F8F2),
            option: .srgb(0xE6DB74),
            dangerousOption: .srgb(0xFC5884),
            value: .srgb(0x66D9EF),
            text: .srgb(0xAE81FF),
            prompt: .srgb(0xA59F85),
            output: .srgb(0xCFCFC2)
        )
    )

    /// The colors of Xcode 27's Standard theme in dark mode, as its Themes
    /// settings show them, in Display P3. Each role takes the syntax color it's
    /// nearest to: keywords' pink, type declarations' sky, project types' mint,
    /// other types' lavender, numbers' gold, links' blue, other members' magenta
    /// and comments' slate, with Source Control's additions and deletions for
    /// what changed. Light mode has each darkened in OKLCH, keeping its hue, until
    /// a lane clears 3:1 on a row and on a selected one, and text clears 4.5:1.
    static let xcode = ThemeColors(
        lanes: [
            ThemeColor(p3: 0xC05E87, 0xEF89B2), // Pink
            ThemeColor(p3: 0x028BB7, 0x5BC7F5), // Sky
            ThemeColor(p3: 0x009375, 0x62D6B4), // Mint
            ThemeColor(p3: 0x9C68C4, 0xCE99F8), // Lavender
            ThemeColor(p3: 0xA47916, 0xE1AB3A), // Gold
            ThemeColor(p3: 0x5380C9, 0x6896E0), // Blue
            ThemeColor(p3: 0xBB4ED2, 0xC85BDF), // Magenta
            ThemeColor(p3: 0x798096, 0xACB3CB), // Slate
        ],
        current: ThemeColor(p3: 0x008939, 0x65DB80),
        onCurrent: ThemeColor(srgb: 0xFFFFFF, 0x1C1C1C),
        otherBranch: ThemeColor(p3: 0x117EA5, 0x5BC7F5),
        added: ThemeColor(p3: 0x008939, 0x65DB80),
        removed: ThemeColor(p3: 0xB2594D, 0xF09283),
        moved: ThemeColor(p3: 0x117EA5, 0x5BC7F5),
        diffAdded: ThemeColor(p3: 0x099640, 0x65DB80),
        diffRemoved: ThemeColor(p3: 0xBF6558, 0xF09283),
        // Deeper in light mode than other text, because they name a side's rows
        // on a tinted band.
        ours: ThemeColor(p3: 0x3B67AD, 0x6896E0),
        theirs: ThemeColor(p3: 0x824FA8, 0xCE99F8),
        ok: ThemeColor(p3: 0x008939, 0x65DB80),
        onDanger: ThemeColor(srgb: 0xFFFFFF, 0x1C1C1C),
        // Xcode's console is a neutral dark gray, which goes darker than a
        // dialog's surface in dark mode for the same reason Monokai's does.
        terminal: ThemeColor(srgb: 0x262626, 0x1C1C1C),
        command: CommandColors(
            program: .displayP3(0xF8F1F3),
            option: .displayP3(0xEF89B2),
            // Xcode's deletions are the same salmon as its strings, so what's
            // dangerous takes a red that stands apart from a message.
            dangerousOption: .displayP3(0xFF6B66),
            value: .displayP3(0x5BC7F5),
            text: .displayP3(0xF0937F),
            prompt: .displayP3(0xACB3CB),
            output: .displayP3(0xD2CCCE)
        )
    )
}

public extension NSColor {
    /// A color from its hex value in sRGB.
    static func srgb(_ value: Int, alpha: CGFloat = 1) -> NSColor {
        let (red, green, blue) = components(value)
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// A color from its hex value in Display P3.
    static func displayP3(_ value: Int, alpha: CGFloat = 1) -> NSColor {
        let (red, green, blue) = components(value)
        return NSColor(displayP3Red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func components(_ value: Int) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat(value >> 16 & 0xFF) / 255, CGFloat(value >> 8 & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
