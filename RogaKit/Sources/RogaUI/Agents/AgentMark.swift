import AppKit
import IconUI
import SwiftUI
import ThemeUI

/// The mark a sidebar row shows for an agent (decision 41): the house's
/// windows at work while it works (decision 122), the amber circle-alert while
/// it waits for you, and a blue dot once it has finished and nobody has looked
/// yet.
///
/// The windows play one of `HouseWindowAnimation`'s animations, the one Roga
/// picked for this launch, so each launch brings another. They stand upright
/// rather than at the logo's tilt, which sits better among the row's other
/// marks and words and still looks like the house. Core Animation plays
/// it rather than SwiftUI, because a SwiftUI animation would redraw the
/// sidebar many times a second for as long as an agent works, which can be
/// hours (see `HouseWindowLayerView`). The waiting mark is a circle rather
/// than the canvas's triangle, since decision 28's red triangle already means
/// conflicts. VoiceOver doesn't read the mark, because the row describes it.
struct AgentMark: View {
    let state: AgentSummary.State
    /// The width and height it takes up. The canvas draws marks in a 16-point
    /// box at 14 points.
    var size: CGFloat = 14
    /// What the windows play while an agent works.
    var animation = HouseWindowAnimation.forThisLaunch

    /// The windows stand still for someone who asked for less motion, as the
    /// house does.
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    /// How much of the icon's width the waiting mark's font size is. Roga's
    /// icons are as wide as their 24-point grid, which comes to 1.128 times
    /// the font's size.
    private static let iconWidthPerPoint: CGFloat = 1.128
    /// How much smaller than its box the circle-alert is drawn. At full size
    /// it would fill the box, while the ring that marked an agent at work
    /// before the windows was 13/16 of it across. At this size the circle
    /// measures about 0.81 of the box, so it looks as big as the windows, and
    /// as the ring did, in the sidebar and in the legends in Settings alike.
    private static let waitingScale: CGFloat = 0.88
    /// How much of the box the four panes at rest take up across. Solid panes
    /// in a square look bigger than a circle drawn with a line, so they're a
    /// little narrower than the waiting circle to look as big as it.
    static let windowWidth: CGFloat = 0.75
    /// How much bigger than the box the windows' drawing area is, which makes
    /// the panes at rest `windowWidth` of the box across. Sash Shift slides
    /// the panes out sideways, so for a moment they reach about half a point
    /// past a 14-point box.
    static let windowReach: CGFloat = {
        let frame = HouseWindowFigure.frame
        let upright = HouseOutline.window.applying(HouseWindowFigure.placement(in: frame.size, rotation: .zero))
        return windowWidth * frame.width / upright.boundingRect.width
    }()

    var body: some View {
        Group {
            switch state {
            case .working:
                AgentWindows(animation: animation, plays: !reducesMotion)
                    .frame(width: size * Self.windowReach, height: size * Self.windowReach)
            case .waiting:
                Icon.circleAlert.image
                    .font(Self.circleFont(size: size))
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

    /// The font for an icon in a circle, such as the waiting mark's, that
    /// looks as big as the windows in a box of this size.
    static func circleFont(size: CGFloat) -> Font {
        .system(size: size * waitingScale / iconWidthPerPoint, weight: .medium)
    }
}

/// The windows at work, upright, drawn by `HouseWindowLayerView` at whatever
/// size it's given.
private struct AgentWindows: NSViewRepresentable {
    let animation: HouseWindowAnimation
    let plays: Bool

    func makeNSView(context: Context) -> HouseWindowLayerView {
        let view = HouseWindowLayerView()
        view.rotation = .zero
        return view
    }

    func updateNSView(_ view: HouseWindowLayerView, context: Context) {
        view.animation = animation
        view.plays = plays
    }
}

/// The colors of agents' marks and of what Settings says about agents, from
/// the design canvas's Settings boards.
enum AgentColors {
    /// Amber, for an agent that waits for you, and for a warning that isn't an
    /// error.
    static let warn = DialogColors.appearanceColor(light: 0x9A5200, dark: 0xF0A54A)
    /// The color theme's green, for what works, such as hooks that are installed.
    static var ok: Color { Palette.themed(\.ok) }
    /// The blue of a dot for what finished and nobody has looked at yet, the
    /// same in both appearances.
    static let finished = DialogColors.appearanceColor(light: 0x2F6DE1, dark: 0x2F6DE1)
    /// The still line around an agent's command, the brand's orange at about
    /// half strength (decision 68).
    static let outline = orange(light: 0.42, dark: 0.45)
    /// The same line under the pointer or while an agent works, and the tail of
    /// the light that runs along it.
    static let outlineLit = orange(light: 0.85, dark: 0.9)
    /// The front of the light, which is brighter than the brand's orange in dark
    /// mode so that it catches the eye, and redder in light mode, where a lighter
    /// orange would fade into the white around it.
    static let light = DialogColors.appearanceColor(light: 0xE8590C, dark: 0xFFB27D)
    /// The soft glow around the front of the light.
    static let glow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 160 / 255, blue: 100 / 255, alpha: 0.6)
            : NSColor(srgbRed: 232 / 255, green: 89 / 255, blue: 12 / 255, alpha: 0.45)
    })

    /// `Palette.action` at a strength for each appearance.
    private static func orange(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 240 / 255, green: 129 / 255, blue: 63 / 255, alpha: dark)
                : NSColor(srgbRed: 201 / 255, green: 68 / 255, blue: 2 / 255, alpha: light)
        })
    }
}
