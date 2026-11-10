import AgentEngine
import IconUI
import SwiftUI

/// The Generate button at the bottom right of the message box (decision 41).
/// It says Generate with the agent's name while the box is empty, and Rewrite
/// once the box has words for the agent to start from, with a chevron beside it
/// that opens the popover for choosing the agent, its model and its effort.
///
/// It's a gray tile cut in two by a thin line, with the orange line around it
/// that marks an agent's command (decision 68).
struct GenerateButton<Choices: View>: View {
    /// The agent a click runs.
    let agent: AgentKind
    /// Whether the box has text, which the agent then rewrites rather than
    /// starting afresh.
    let rewrites: Bool
    let readiness: MessageGenerator.Readiness
    @Binding var isChoosing: Bool
    let generate: () -> Void
    @ViewBuilder let choices: () -> Choices
    @State private var isHovering: Bool

    /// - Parameter isHovering: Whether it starts out with the pointer over it,
    ///   for pictures of it.
    init(
        agent: AgentKind,
        rewrites: Bool,
        readiness: MessageGenerator.Readiness,
        isChoosing: Binding<Bool>,
        isHovering: Bool = false,
        generate: @escaping () -> Void,
        @ViewBuilder choices: @escaping () -> Choices
    ) {
        self.agent = agent
        self.rewrites = rewrites
        self.readiness = readiness
        _isChoosing = isChoosing
        _isHovering = State(initialValue: isHovering)
        self.generate = generate
        self.choices = choices
    }

    /// How tall it is, which the box leaves room for under its text.
    static var height: CGFloat { 24 }

    private var isEnabled: Bool { readiness == .ready }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: generate) {
                Text(rewrites ? Self.rewriteTitle : Self.title(agent: agent))
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            // The tooltip goes outside what's disabled, since it's what says
            // why the button can't be pressed.
            .disabled(!isEnabled)
            .help(Self.help(agent: agent, rewrites: rewrites, readiness: readiness))
            .accessibilityLabel(rewrites ? "Rewrite with \(agent.name)" : Self.title(agent: agent))
            Rectangle()
                .fill(SettingsColors.line)
                .frame(width: 1)
            Button {
                isChoosing.toggle()
            } label: {
                Icon.dropdown.image
                    .font(.system(size: Self.iconFontSize(11), weight: .medium))
                    .foregroundStyle(DialogColors.note)
                    .padding(.horizontal, 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .disabled(!isEnabled)
            .help("Choose an Agent")
            .accessibilityLabel("Choose an Agent")
            .popover(isPresented: $isChoosing, arrowEdge: .top) {
                choices()
            }
        }
        .buttonStyle(GenerateButtonPartStyle())
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isEnabled ? Color.primary : DialogColors.note)
        .frame(height: Self.height)
        .background(DialogColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            AgentOutline(shape: .outline(cornerRadius: 7), isEnabled: isEnabled, isHovering: isHovering, isLit: isChoosing)
        }
        .onHover { isHovering = $0 }
        .fixedSize()
    }

    /// The font size that draws one of Roga's icons `width` points wide, since
    /// its 24-point grid comes to 1.128 times the font's size.
    private static func iconFontSize(_ width: CGFloat) -> CGFloat {
        width / 1.128
    }
}

extension GenerateButton {
    /// What the main button says while the box is empty, which names the agent a
    /// click runs, since the popover is the only other place that says.
    static func title(agent: AgentKind) -> String {
        "Generate with \(agent.shortName)"
    }

    /// What it says once the box has words, where the chevron beside it and its
    /// tooltip say which agent, and the box is short of room for more.
    static var rewriteTitle: String { "Rewrite" }

    /// What the main button's tooltip says: why it can't run when nothing's
    /// staged or a rebase has stopped, and otherwise what a click does. While
    /// the box is busy for a while, as when a commit is being made, it leaves
    /// out the shortcut, which can't run yet either.
    static func help(agent: AgentKind, rewrites: Bool, readiness: MessageGenerator.Readiness) -> String {
        let words = rewrites ? "Rewrite the commit message with \(agent.name) using the current draft" : "Generate a commit message with \(agent.name)"
        switch readiness {
        case .ready:
            return "\(words) (\(RepositoryCommands.generateMessageShortcut.symbols))"
        case .nothingStaged:
            return "Stage changes to generate a commit message"
        case .rebasing:
            return "Finish the rebase to generate a commit message"
        case .busy:
            return words
        }
    }
}

/// Either half of the Generate button. Its colors already say when it can't be
/// pressed, gray as the canvas draws it, so unlike the plain style it doesn't
/// dim it again.
private struct GenerateButtonPartStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Whether the message box shows the Generate button, and how (decision 41).
enum GenerateButtonState: Equatable {
    /// It's turned off in Settings, no agent can be used, or an agent is
    /// writing already, which the line under the box says instead.
    case hidden
    case shown(agent: AgentKind, rewrites: Bool, readiness: MessageGenerator.Readiness)

    init(showsButton: Bool, agent: AgentKind?, hasText: Bool, isWriting: Bool, readiness: MessageGenerator.Readiness) {
        guard showsButton, let agent, !isWriting else {
            self = .hidden
            return
        }
        self = .shown(agent: agent, rewrites: hasText, readiness: readiness)
    }
}
