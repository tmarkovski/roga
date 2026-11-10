import AppKit
import ThemeUI

/// The colors of the graph, of branches, and of what git says has changed, which
/// are the color theme's (decisions 27 and 71). Each is always the current
/// theme's, in either appearance, so a view that keeps one only has to draw again
/// when the theme changes. They're fixed rather than system colors, so they don't
/// follow the accent color.
public enum GitColors {
    /// The colors the graph's lanes take turns with, one for each of
    /// `LaneLayout.colors`.
    public static let lanes: [NSColor] = ColorTheme.monokai.colors.lanes.indices.map { lane in
        ColorTheme.following { $0.lanes[lane] }
    }

    /// The current branch wherever it shows: its badge's fill, the ring around the
    /// commit `HEAD` is on, and its icon in the refs panel.
    public static let current = ColorTheme.following(\.current)
    /// Text on the current branch's badge.
    static let onCurrent = ColorTheme.following(\.onCurrent)
    /// The name of any other local branch.
    static let otherBranch = ColorTheme.following(\.otherBranch)

    /// What was added, and commits ahead of the upstream.
    public static let green = ColorTheme.following(\.added)
    /// What was removed, and commits behind the upstream.
    public static let red = ColorTheme.following(\.removed)
    /// What was moved or copied.
    public static let blue = ColorTheme.following(\.moved)

    /// A color for each appearance, from its hex values, which is the same in
    /// every theme.
    static func color(light: Int, dark: Int) -> NSColor {
        ThemeColor(light: .srgb(light), dark: .srgb(dark)).color
    }
}
