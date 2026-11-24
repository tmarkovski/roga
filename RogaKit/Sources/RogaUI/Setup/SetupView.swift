import AgentEngine
import AppKit
import IconUI
import SwiftUI

/// Setup, in the whole window: one centered column with a heading, what Roga
/// found, and the buttons that answer the screen, as the design canvas's
/// First run boards draw it. A lane of commits along the bottom, one for
/// each screen, says how far along it is, and the house runs along it as it
/// goes, hops over the steps that were answered No, and waddles while Roga
/// is busy. A screen comes in from the side setup is moving toward.
struct SetupView: View {
    let setup: SetupModel
    /// The row whose popover is open when the view appears, for drawing a
    /// screen with its popover open in a preview.
    var openPicker: String?
    @Environment(GitProvider.self) private var gitProvider
    @Environment(AgentProvider.self) private var agents
    /// Where Welcome has room for the house, once it's laid out. It's kept
    /// after Welcome goes, which is where the house goes back to.
    @State private var welcomeHouse: SetupHouseSpot?
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    /// The agents Roga found and can run.
    private var found: [AgentKind] {
        AgentKind.allCases.filter { agents.installation($0) != nil }
    }

    var body: some View {
        let isWelcome = setup.step == .welcome
        let skipped = setup.skipped(found: found)
        GeometryReader { proxy in
            // The window has no title bar over setup (decision 96), so it
            // keeps room for the title row at its top.
            let top = SetupLayout.titleRow + SetupLayout.top
            let house = isWelcome
                ? SetupHouseTarget(place: .welcome, spot: welcomeHouse)
                : SetupHouseTarget(
                    place: .floor(SetupLane.position(of: setup.step)),
                    spot: SetupLane.spot(at: setup.step, in: proxy.size),
                    skipped: skipped.map(SetupLane.position(of:))
                )
            ScrollView(.vertical) {
                // One over the other, so that a screen on its way out
                // doesn't push the one coming in down the window.
                ZStack(alignment: .top) {
                    if isWelcome {
                        // Welcome sits in the middle of the window, a little
                        // above it.
                        SetupWelcome(setup: setup) { welcomeHouse = $0 }
                            .frame(width: SetupLayout.column)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height - 40)
                            .transition(SetupMotion.fade)
                    } else {
                        // The other screens start at the top, and scroll
                        // above the lane when they're too tall for the window.
                        ZStack(alignment: .top) {
                            screen
                                .id(setup.step)
                                .transition(SetupMotion.screen(goesBack: setup.goesBack, reducesMotion: reducesMotion))
                        }
                        .frame(width: SetupLayout.column)
                        .frame(maxWidth: .infinity)
                        .padding(.top, top)
                        .padding(.bottom, SetupLayout.floorGap)
                        .transition(SetupMotion.fade)
                    }
                }
                .animation(SetupMotion.step(reducesMotion), value: setup.step)
            }
            .scrollBounceBehavior(.basedOnSize)
            // The lane runs along the bottom of the window, under every
            // screen after Welcome, and stands in for the dots that used to
            // say how far along setup is.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ZStack {
                    if !isWelcome {
                        SetupLane(current: setup.step, skipped: skipped, isEnabled: !(setup.step == .hooks && isBusy)) { step in
                            setup.go(to: step)
                        }
                        // A screen that scrolls goes under the lane, so the
                        // lane has the window's surface, and what's scrolled
                        // fades out above it rather than being cut off.
                        .background {
                            SetupColors.surface
                                .overlay(alignment: .top) {
                                    LinearGradient(colors: [SetupColors.surface.opacity(0), SetupColors.surface], startPoint: .top, endPoint: .bottom)
                                        .frame(height: SetupLayout.floorGap)
                                        .offset(y: -SetupLayout.floorGap)
                                        .allowsHitTesting(false)
                                }
                        }
                        .transition(SetupMotion.fade)
                    }
                }
                .frame(height: isWelcome ? 0 : SetupLane.height)
                .animation(SetupMotion.step(reducesMotion), value: isWelcome)
            }
            // The house is over the screens and the lane rather than in one
            // of them, so that it can go from one to the next, and from
            // Welcome's middle down onto the lane.
            .overlay {
                SetupHouseLayer(target: house, isBusy: isBusy)
            }
            .coordinateSpace(.named(SetupLayout.space))
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SetupColors.surface
                .ignoresSafeArea()
        }
        .font(.system(size: 13))
        .environment(\.openProgramPicker, openPicker)
        // At the size the boards draw it, whatever size the window had last
        // time, and out of full screen (decision 69).
        .background { SetupWindowSize() }
        .navigationTitle("Roga")
        // Settings… does nothing during setup, which sets the same things,
        // rather than opening another window to show Settings on.
        .focusedSceneValue(\.showsSettings, .constant(false))
    }

    @ViewBuilder private var screen: some View {
        switch setup.step {
        case .welcome: EmptyView()
        case .looking: SetupLooking(setup: setup, found: found)
        case .git: SetupGit(setup: setup, found: found)
        case .agents: SetupAgents(setup: setup, found: found)
        case .hooks: SetupHooks(setup: setup, found: found)
        case .ready: SetupReady(setup: setup, found: found)
        }
    }

    /// Whether Roga is doing something the person waits for, which the house
    /// waddles through: looking around, or installing hooks.
    private var isBusy: Bool {
        switch setup.step {
        case .looking, .git, .agents:
            gitProvider.isLooking || (gitProvider.git != nil && agents.isLooking)
        case .hooks:
            AgentKind.allCases.contains { agents.hookWork[$0] == .installing }
        case .welcome, .ready:
            false
        }
    }
}

/// The measurements the screens share, from the boards.
enum SetupLayout {
    /// How large the window is while setup shows, which is the size the
    /// window first opens at and the boards are drawn at.
    static let window = CGSize(width: 1280, height: 800)
    /// How wide the column is.
    static let column: CGFloat = 620
    /// How tall the window's title row is, which setup keeps room for at its
    /// top, beside the traffic lights.
    static let titleRow: CGFloat = TitleBar.height
    /// The room between the title row and where a screen starts.
    static let top: CGFloat = 20
    /// The space between a screen's parts.
    static let gap: CGFloat = 14
    /// The least room between a screen's buttons and the lane under them.
    static let floorGap: CGFloat = 20
    /// The least width of the button that goes on, so that it's the same
    /// size and in the same place from one screen to the next.
    static let mainButton: CGFloat = 168
    /// The size of a command in a card, at which each of the commands that
    /// install the hooks fits on one line of the column.
    static let commandFontSize: CGFloat = 11
    /// How tall the house is on Welcome.
    static let welcomeHouse: CGFloat = 168
    /// The name of the coordinates the house is placed in, which are those
    /// of everything that scrolls.
    static let space = "setup"
}

// MARK: The window

/// Puts setup's window at `SetupLayout.window`, or as much of it as the screen
/// has, in the middle of the screen and out of full screen, and keeps it that
/// size while setup shows (decision 69). So setup looks as the boards draw it,
/// with the floor under the buttons, rather than spread over a window that
/// was full screen or large the last time Roga ran. Once setup ends, the
/// window can be resized and go full screen again, from that size.
private struct SetupWindowSize: NSViewRepresentable {
    func makeNSView(context: Context) -> SizingView {
        SizingView()
    }

    func updateNSView(_ view: SizingView, context: Context) {}

    static func dismantleNSView(_ view: SizingView, coordinator: ()) {
        view.release()
    }

    final class SizingView: NSView {
        /// The window it sized, and what it changed there, to put back.
        private weak var sized: NSWindow?
        private var wasResizable = false
        private var wasFullScreenNone = false
        private var observers: [NSObjectProtocol] = []

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== sized else { return }
            release()
            guard let window else { return }
            sized = window
            wasResizable = window.styleMask.contains(.resizable)
            wasFullScreenNone = window.collectionBehavior.contains(.fullScreenNone)
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fit() }
            })
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                // After this turn of the run loop, when macOS has put back the
                // frame the window had when Roga last quit.
                DispatchQueue.main.async { [weak self] in self?.fit() }
            }
        }

        /// Sizes and centers the window, and stops it changing size, once
        /// it's out of full screen.
        private func fit() {
            guard let window = sized, !window.styleMask.contains(.fullScreen) else { return }
            var size = SetupLayout.window
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size {
                size.width = min(size.width, visible.width)
                size.height = min(size.height, visible.height)
            }
            window.setFrame(window.frameRect(forContentRect: NSRect(origin: window.frame.origin, size: size)), display: true)
            window.center()
            window.styleMask.remove(.resizable)
            window.collectionBehavior.insert(.fullScreenNone)
        }

        /// Lets the window change size and go full screen again, as it could
        /// before setup.
        func release() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window = sized else { return }
            sized = nil
            if wasResizable { window.styleMask.insert(.resizable) }
            if !wasFullScreenNone { window.collectionBehavior.remove(.fullScreenNone) }
        }
    }
}

// MARK: Motion

/// How setup moves. Someone who asked for less motion gets the fades and
/// none of the movement.
enum SetupMotion {
    /// What moving from one screen to another animates with.
    static func step(_ reducesMotion: Bool) -> Animation {
        .easeOut(duration: reducesMotion ? 0.2 : 0.3)
    }

    /// What something on a screen animates with when it changes what it
    /// says or how tall it is, or nil for no animation.
    static func change(_ reducesMotion: Bool) -> Animation? {
        reducesMotion ? nil : .easeOut(duration: 0.22)
    }

    /// What a mark animates with as it turns into a check.
    static func pop(_ reducesMotion: Bool) -> Animation? {
        reducesMotion ? nil : .spring(duration: 0.4, bounce: 0.4)
    }

    /// Welcome and the screens after it are laid out differently, so one
    /// fades out before the other fades in, and neither is read through the
    /// other.
    static let fade = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.3).delay(0.14)),
        removal: .opacity.animation(.easeOut(duration: 0.14))
    )

    /// How far to the side a screen starts from.
    private static let travel: CGFloat = 32

    /// A screen fades out quickly where it is, and the next one comes in
    /// from the side setup is moving toward: the right going on, the left
    /// going back. Only the screen coming in knows the direction, since the
    /// one going out was drawn before the move.
    static func screen(goesBack: Bool, reducesMotion: Bool) -> AnyTransition {
        guard !reducesMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: goesBack ? -travel : travel)
                .combined(with: .opacity)
                .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42).delay(0.08)),
            removal: .opacity.animation(.easeOut(duration: 0.12))
        )
    }
}

extension View {
    /// Fades and lifts a part of a screen into place when the screen
    /// appears, each part a little after the one before it.
    func setupEntrance(_ isIn: Bool, order: Int) -> some View {
        modifier(SetupEntrance(isIn: isIn, order: order))
    }
}

private struct SetupEntrance: ViewModifier {
    let isIn: Bool
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    func body(content: Content) -> some View {
        content
            .opacity(isIn ? 1 : 0)
            .offset(y: isIn || reducesMotion ? 0 : 14)
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6).delay(0.1 + Double(order) * 0.07), value: isIn)
    }
}

// MARK: What the screens are made of

/// A screen's heading: a small word in orange, the heading itself, and a
/// sentence or two under it, all centered. It's the same height on every
/// screen, so that what's under it starts in the same place: the heading
/// keeps to one line, and the sentence has room for two.
struct SetupHead: View {
    let eyebrow: String
    let title: String
    let sub: String
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        VStack(spacing: 8) {
            Text(eyebrow.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(SetupColors.eyebrow)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.4)
                // A heading longer than the column gets smaller rather than
                // taking a second line.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.opacity)
                .animation(SetupMotion.change(reducesMotion), value: title)
                .accessibilityAddTraits(.isHeader)
            ZStack(alignment: .top) {
                // Two empty lines, which keep room for two.
                Text(verbatim: " \n ")
                    .hidden()
                    .accessibilityHidden(true)
                Text(sub)
                    .foregroundStyle(SetupColors.note)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
            }
            .font(.system(size: 14))
            .lineSpacing(4)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }
}

/// The buttons under a screen, in one row as wide as the column, so that
/// each kind is in the same place on every screen. Back is at the left edge.
/// The rest are at the right, in one order: what helps, such as Look Again,
/// then the answer that declines, then the one that goes on.
struct SetupActions<Answers: View>: View {
    /// What Back does.
    let back: () -> Void
    /// Whether Back waits for something that's running.
    var backIsDisabled = false
    @ViewBuilder var answers: Answers

    var body: some View {
        HStack(spacing: 8) {
            Button("Back", action: back)
                .buttonStyle(.setup(.ghost))
                .disabled(backIsDisabled)
            Spacer(minLength: 0)
            answers
        }
        .padding(.top, 8)
    }
}

/// Setup's buttons, which are larger than a dialog's: solid ink for the one
/// that goes on, the brand's orange for the one that opens Roga at the end,
/// soft gray for the other answers, and words alone for going back.
struct SetupButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        /// The last button of setup, which opens Roga.
        case brand
        case secondary
        case ghost
    }

    var kind = Kind.secondary

    func makeBody(configuration: Configuration) -> some View {
        SetupButtonBody(configuration: configuration, kind: kind, foreground: foreground, background: background)
    }

    private var foreground: Color {
        switch kind {
        case .primary: DialogColors.onInk
        case .brand: .white
        case .secondary: .primary
        case .ghost: SetupColors.note
        }
    }

    private var background: Color {
        switch kind {
        case .primary: SetupColors.ink
        case .brand: Palette.actionFill
        case .secondary: SettingsColors.secondaryButton
        case .ghost: .clear
        }
    }
}

/// A setup button as it's drawn, which keeps whether the pointer is over it.
/// Back, which is words alone, gets the fill every borderless button has
/// under the pointer, and a stronger one while it's pressed.
private struct SetupButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SetupButtonStyle.Kind
    let foreground: Color
    let background: Color
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .lineLimit(1)
            // Its words in full, whatever room a row of buttons offers it.
            .fixedSize()
            .padding(.horizontal, kind == .ghost ? 12 : 18)
            .frame(minWidth: kind == .primary || kind == .brand ? SetupLayout.mainButton : nil)
            .frame(height: 36)
            .foregroundStyle(foreground)
            .background(fill, in: shape)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed && kind != .ghost ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reducesMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(SetupMotion.change(reducesMotion), value: isEnabled)
            .contentShape(shape)
            .onHover { isHovering = $0 }
    }

    private var fill: Color {
        guard kind == .ghost else { return background }
        guard isEnabled else { return .clear }
        return configuration.isPressed ? Palette.buttonPressed : isHovering ? Palette.buttonHover : .clear
    }
}

extension ButtonStyle where Self == SetupButtonStyle {
    static func setup(_ kind: SetupButtonStyle.Kind = .secondary) -> SetupButtonStyle {
        SetupButtonStyle(kind: kind)
    }
}

/// A small button inside a card, such as Change beside what a step set.
struct SetupSmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(SetupColors.surface, in: shape)
            .overlay {
                shape.strokeBorder(SetupColors.line, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(shape)
    }
}

/// Gray words centered under a card, a line to each.
struct SetupNote: View {
    let lines: [String]
    var size: CGFloat = 12.5

    var body: some View {
        VStack(spacing: 2) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: size))
        .foregroundStyle(SetupColors.note)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// A sentence that says what the dark button does, which starts with the
/// button's name in bold.
struct SetupSay: View {
    var button: String?
    let words: String

    var body: some View {
        Group {
            if let button {
                Text("\(Text(button).fontWeight(.semibold)) \(words)")
            } else {
                Text(words)
            }
        }
        .font(.system(size: 13.5))
        .lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small mark before a line: a green check, the amber circle, a gray dash
/// for what isn't used, the ring while something runs, or a dot for what
/// hasn't started.
struct SetupGlyph: View {
    enum Kind: Equatable {
        case ok
        case warn
        case off
        case spinner
        case waiting
    }

    let kind: Kind
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch kind {
            case .ok:
                Icon.check.image
                    .font(.system(size: size * 0.82, weight: .bold))
                    .foregroundStyle(AgentColors.ok)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            case .warn:
                Icon.circleAlert.image
                    .font(.system(size: size * 0.82, weight: .medium))
                    .foregroundStyle(AgentColors.warn)
            case .off:
                Icon.minus.image
                    .font(.system(size: size * 0.82, weight: .bold))
                    .foregroundStyle(SetupColors.note)
            case .spinner:
                AgentMark(state: .working, size: size)
            case .waiting:
                Circle()
                    .fill(SetupColors.line)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
