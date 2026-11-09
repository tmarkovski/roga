import AgentEngine
import IconUI
import SwiftUI

/// Setup, in the whole window: one centered column with a heading, what Roga
/// found, and the buttons that answer the screen, as the design canvas's
/// First run boards draw it. Dots at the top say how far along it is, and the
/// house walks along a floor at the bottom as it goes, and waddles while
/// Roga is busy.
struct SetupView: View {
    let setup: SetupModel
    /// The row whose menu is open when the view appears, for drawing a
    /// screen with its menu open in a test.
    var openMenu: String?
    @Environment(GitProvider.self) private var gitProvider
    @Environment(AgentProvider.self) private var agents
    /// How tall the screen that shows is, once it's laid out, which says
    /// whether the floor fits under it.
    @State private var screenHeight: CGFloat = 0

    /// The agents Roga found and can run.
    private var found: [AgentKind] {
        AgentKind.allCases.filter { agents.installation($0) != nil }
    }

    var body: some View {
        let steps = setup.steps(found: found)
        let isWelcome = setup.step == .welcome
        GeometryReader { proxy in
            // The window's title row is empty during setup, and the dots sit
            // in it. A view with no title row over it, as in a test, keeps
            // room for one at its top instead.
            let titleRow = proxy.safeAreaInsets.top
            let ownRow = titleRow > 0 ? 0 : SetupLayout.titleRow
            ScrollView(.vertical) {
                if isWelcome {
                    // Welcome sits in the middle of the window, a little
                    // above it.
                    screen
                        .frame(width: SetupLayout.column)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height - 40)
                } else {
                    // The other screens start at the top, and the floor is
                    // at the bottom of the window. A screen that leaves no
                    // room for the floor goes without it, and scrolls if it
                    // has to, so the house never stands on a button.
                    let top = ownRow + SetupLayout.top
                    let hasFloor = top + screenHeight + SetupLayout.floorGap + SetupFloor.height <= proxy.size.height
                    VStack(spacing: 0) {
                        screen
                            .frame(width: SetupLayout.column)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }
                            .frame(maxWidth: .infinity)
                            .padding(.top, top)
                        if hasFloor {
                            Spacer(minLength: SetupLayout.floorGap)
                            SetupFloor(
                                position: Double(steps.firstIndex(of: setup.step) ?? 0) / Double(max(1, steps.count - 1)),
                                isBusy: isBusy
                            )
                        } else {
                            Color.clear
                                .frame(height: SetupLayout.floorGap)
                        }
                    }
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .overlay(alignment: .top) {
                if !isWelcome {
                    SetupDots(steps: steps, current: setup.step)
                        .offset(y: titleRow > 0 ? -titleRow / 2 - 3 : ownRow / 2 - 3)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SetupColors.surface
                .ignoresSafeArea()
        }
        .font(.system(size: 13))
        .programMenus(open: openMenu)
        // The same title row as the app's own window, with nothing in it,
        // so that the window's buttons stay where they are when setup ends.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .navigationTitle("Roga")
        // Settings… does nothing during setup, which sets the same things,
        // rather than opening another window to show Settings on.
        .focusedSceneValue(\.showsSettings, .constant(false))
    }

    @ViewBuilder private var screen: some View {
        switch setup.step {
        case .welcome: SetupWelcome(setup: setup)
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
    /// How wide the column is.
    static let column: CGFloat = 620
    /// How tall the window's title row is on the boards, which a view with
    /// no title row over it keeps room for.
    static let titleRow: CGFloat = 52
    /// The room between the title row and where a screen starts.
    static let top: CGFloat = 20
    /// The space between a screen's parts.
    static let gap: CGFloat = 14
    /// The least room between a screen's buttons and the floor under them.
    static let floorGap: CGFloat = 20
    /// The size of a command in a card, at which each of the commands that
    /// install the hooks fits on one line of the column.
    static let commandFontSize: CGFloat = 11
}

// MARK: Dots and the house

/// A dot for each screen: gray for the ones still to come, darker for the
/// ones done, and a wide ink one for where setup is.
private struct SetupDots: View {
    let steps: [SetupModel.Step]
    let current: SetupModel.Step
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        let index = steps.firstIndex(of: current) ?? 0
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.element) { place, _ in
                Capsule()
                    .fill(place == index ? SetupColors.ink : place < index ? SetupColors.note : SetupColors.line)
                    .frame(width: place == index ? 20 : 6, height: 6)
            }
        }
        .animation(reducesMotion ? nil : .easeOut(duration: 0.3), value: index)
        .animation(reducesMotion ? nil : .easeOut(duration: 0.3), value: steps.count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of \(steps.count)")
    }
}

/// A thin floor near the bottom of the window, with the house standing on it
/// as far along as setup is. It walks to its next place when the screen
/// changes, and waddles on the spot while Roga is busy.
private struct SetupFloor: View {
    /// How far along the floor the house stands, from 0 to 1.
    let position: Double
    let isBusy: Bool
    /// Whether the house is on its way to a new place.
    @State private var isWalking = false
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    private static let houseHeight: CGFloat = 46
    private static let houseWidth = houseHeight * HouseRig.frame.width / HouseRig.frame.height
    /// How far the floor is from the bottom of the window, and how much
    /// room the house and that take together.
    private static let fromBottom: CGFloat = 30
    static let height = houseHeight + fromBottom
    /// How far from each edge of the window the house's walk starts and ends.
    private static let inset: CGFloat = 64
    private static let walk = 0.8

    var body: some View {
        GeometryReader { proxy in
            let room = max(0, proxy.size.width - 2 * Self.inset - Self.houseWidth)
            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(SetupColors.hairline)
                    .frame(height: 1)
                SetupHouse(isMoving: isBusy || isWalking, height: Self.houseHeight)
                    .offset(x: Self.inset + room * position)
                    .animation(reducesMotion ? nil : .timingCurve(0.3, 0.7, 0.3, 1, duration: Self.walk), value: position)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: Self.houseHeight)
        .padding(.bottom, Self.fromBottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: position) {
            guard !reducesMotion else { return }
            isWalking = true
        }
        .task(id: position) {
            // Its feet stop once it's there.
            guard isWalking, (try? await Task.sleep(for: .seconds(Self.walk))) != nil else { return }
            isWalking = false
        }
    }
}

/// The house standing as the mark draws it, or waddling.
private struct SetupHouse: View {
    let isMoving: Bool
    let height: CGFloat

    var body: some View {
        if isMoving {
            HouseAnimationView(animation: .waddle, height: height)
        } else {
            HouseFigure(pose: .mark)
                .frame(width: height * HouseRig.frame.width / HouseRig.frame.height, height: height)
        }
    }
}

// MARK: What the screens are made of

/// A screen's heading: a small word in orange, the heading itself, and a
/// sentence or two under it, all centered.
struct SetupHead: View {
    let eyebrow: String
    let title: String
    let sub: String

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
                .lineSpacing(1)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(sub)
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(SetupColors.note)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }
}

/// The buttons that answer a screen, centered under it, with the dark one
/// last.
struct SetupActions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

/// Setup's buttons, which are larger than a dialog's: solid ink for the one
/// that answers the screen, soft gray for the other answer, and words alone
/// for going back.
struct SetupButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case ghost
    }

    var kind = Kind.secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .lineLimit(1)
            // Its words in full, whatever room a row of buttons offers it.
            .fixedSize()
            .padding(.horizontal, kind == .ghost ? 12 : 18)
            .frame(minWidth: kind == .primary ? 168 : nil)
            .frame(height: 36)
            .foregroundStyle(foreground)
            .background(background, in: shape)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
            .contentShape(shape)
    }

    private var foreground: Color {
        switch kind {
        case .primary: DialogColors.onInk
        case .secondary: .primary
        case .ghost: SetupColors.note
        }
    }

    private var background: Color {
        switch kind {
        case .primary: SetupColors.ink
        case .secondary: SettingsColors.secondaryButton
        case .ghost: .clear
        }
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
