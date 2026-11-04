import AppKit

/// The colors of the graph, of branches, and of what git says has changed, which
/// are Monokai's (decision 27). Dark mode uses Monokai's own values, moved only
/// where a line wouldn't read on a selected row. Classic Monokai has no light
/// theme, so light mode has a deeper version of each. They're fixed rather than
/// system colors, so they don't follow the accent color.
public enum GitColors {
    /// Each column of the graph, in turn. Monokai's orange isn't among them,
    /// because orange means a click would run something (decision 19).
    public static let lanes: [NSColor] = [
        color(light: 0xDB1C61, dark: 0xFF3478), // Pink
        color(light: 0x10819E, dark: 0x66D9EF), // Sky
        color(light: 0x608A00, dark: 0xA6E22E), // Green
        color(light: 0x7240C0, dark: 0xAE81FF), // Violet
        color(light: 0x968505, dark: 0xE6DB74), // Yellow
        color(light: 0x2552AA, dark: 0x6796E6), // Blue
        color(light: 0x676450, dark: 0xA59F85), // Stone
        color(light: 0x0D906D, dark: 0xA1EFE4), // Seafoam
    ]

    /// The current branch wherever it shows: its badge's fill, the ring around the
    /// commit `HEAD` is on, and its icon in the refs panel.
    public static let current = color(light: 0x547A02, dark: 0xA6E22E)
    /// Text on the current branch's badge.
    static let onCurrent = color(light: 0xFFFFFF, dark: 0x272822)
    /// The name of any other local branch.
    static let otherBranch = color(light: 0x00566E, dark: 0x66D9EF)

    /// What was added, and commits ahead of the upstream.
    public static let green = color(light: 0x4D7000, dark: 0xA6E22E)
    /// What was removed, and commits behind the upstream.
    public static let red = color(light: 0xCD1755, dark: 0xFC5884)
    /// What was moved or copied.
    public static let blue = color(light: 0x036E8B, dark: 0x66D9EF)

    /// A color for each appearance, from its hex values.
    static func color(light: Int, dark: Int) -> NSColor {
        func color(_ value: Int) -> NSColor {
            NSColor(
                srgbRed: CGFloat(value >> 16 & 0xFF) / 255,
                green: CGFloat(value >> 8 & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
        let (light, dark) = (color(light), color(dark))
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}
