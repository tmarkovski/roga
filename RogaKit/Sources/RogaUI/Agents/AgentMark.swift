import IconUI
import SwiftUI

/// The mark a sidebar row shows for an agent (decision 41): a ring while it
/// works, the amber circle-alert while it waits for you, and a blue dot once
/// it has finished and nobody has looked yet.
///
/// The ring is the design canvas's: a gray track with a quarter of it in the
/// brand's orange, from the top. It stands still, as the canvas draws it,
/// because a spinning mark on every row would keep the sidebar redrawing. The
/// waiting mark is a circle rather than the canvas's triangle, since decision
/// 28's red triangle already means conflicts. VoiceOver doesn't read the mark,
/// because the row describes it.
struct AgentMark: View {
    let state: AgentSummary.State
    /// The width and height it takes up. The canvas draws marks in a 16-point
    /// box at 14 points.
    var size: CGFloat = 14

    /// How much of the icon's width the waiting mark's font size is, so that
    /// the circle is as wide as the ring. Roga's icons are as wide as their
    /// 24-point grid, which comes to 1.128 times the font's size.
    private static let iconWidthPerPoint: CGFloat = 1.128

    var body: some View {
        Group {
            switch state {
            case .working:
                ring
            case .waiting:
                Icon.circleAlert.image
                    .font(.system(size: size / Self.iconWidthPerPoint, weight: .medium))
                    .foregroundStyle(AgentColors.warn)
            case .finished:
                Circle()
                    .fill(AgentColors.finished)
                    .frame(width: size / 2, height: size / 2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The canvas's ring: a circle of radius 5.5 in a 16-point box, stroked 2
    /// points wide, and a quarter arc from the top with round ends.
    private var ring: some View {
        let scale = size / 16
        let diameter = 11 * scale
        let width = 2 * scale
        return ZStack {
            Circle()
                .stroke(AgentColors.ringTrack, lineWidth: width)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(Palette.action, style: StrokeStyle(lineWidth: width, lineCap: .round))
                // A circle's outline starts on the right, so a quarter turn
                // back starts it at the top.
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The colors of agents' marks and of what Settings says about agents, from
/// the design canvas's Settings boards.
enum AgentColors {
    /// Amber, for an agent that waits for you, and for a warning that isn't an
    /// error.
    static let warn = DialogColors.appearanceColor(light: 0x9A5200, dark: 0xF0A54A)
    /// Green, for what works, such as hooks that are installed.
    static let ok = DialogColors.appearanceColor(light: 0x3F7D00, dark: 0xA6E22E)
    /// The blue of a dot for what finished and nobody has looked at yet, the
    /// same in both appearances.
    static let finished = DialogColors.appearanceColor(light: 0x2F6DE1, dark: 0x2F6DE1)
    /// The track of the ring, in the canvas's line gray.
    static let ringTrack = SettingsColors.line
}
