import AgentEngine
import IconUI
import SwiftUI

/// The Generate button at the left of the row inside the message box
/// (decisions 41 and 98). It says Generate with the agent's name while the box
/// is empty, or Generate alone when the row is short of room, and Rewrite once
/// the box has words for the agent to start from, with a chevron beside it that
/// opens the popover for choosing the agent, its model and its effort.
///
/// It's a gray tile cut in two by a thin line, with the orange line around it
/// that marks an agent's command (decision 68).
struct GenerateButton<Choices: View>: View {
    /// The agent a click runs.
    let agent: NamedAgent
    /// Whether the box has text, which the agent then rewrites rather than
    /// starting afresh.
    let rewrites: Bool
    /// Whether it leaves out the agent's name, for a row that's short of room.
    var isCompact = false
    let readiness: MessageGenerator.Readiness
    @Binding var isChoosing: Bool
    let generate: () -> Void
    @ViewBuilder let choices: () -> Choices
    @State private var isHovering: Bool

    /// - Parameter isHovering: Whether it starts out with the pointer over it,
    ///   for pictures of it.
    init(
        agent: NamedAgent,
        rewrites: Bool,
        isCompact: Bool = false,
        readiness: MessageGenerator.Readiness,
        isChoosing: Binding<Bool>,
        isHovering: Bool = false,
        generate: @escaping () -> Void,
        @ViewBuilder choices: @escaping () -> Choices
    ) {
        self.agent = agent
        self.rewrites = rewrites
        self.isCompact = isCompact
        self.readiness = readiness
        _isChoosing = isChoosing
        _isHovering = State(initialValue: isHovering)
        self.generate = generate
        self.choices = choices
    }

    /// How tall it is, as tall as Commit beside it in the box's row.
    static var height: CGFloat { 26 }

    private var isEnabled: Bool { readiness == .ready }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: generate) {
                Text(Self.title(agent: agent, rewrites: rewrites, isCompact: isCompact))
                    .padding(.horizontal, 7)
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
                    .padding(.horizontal, 4)
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
    static func title(agent: NamedAgent) -> String {
        "Generate with \(agent.shortName)"
    }

    /// What it says once the box has words, where the chevron beside it and its
    /// tooltip say which agent, and the box is short of room for more.
    static var rewriteTitle: String { "Rewrite" }

    /// What the main button says: Rewrite once the box has words, and
    /// otherwise Generate, with the agent's name unless the row is short of room.
    static func title(agent: NamedAgent, rewrites: Bool, isCompact: Bool) -> String {
        if rewrites { return rewriteTitle }
        return isCompact ? "Generate" : title(agent: agent)
    }

    /// How wide the button is with those words: the words and their padding,
    /// the thin line, and the chevron with its own.
    static func width(agent: NamedAgent, rewrites: Bool, isCompact: Bool) -> CGFloat {
        RowWords.width(title(agent: agent, rewrites: rewrites, isCompact: isCompact), size: 12) + 14 + 1 + 19
    }

    /// What the main button's tooltip says: why it can't run when nothing's
    /// staged or a rebase has stopped, and otherwise what a click does. While
    /// the box is busy for a while, as when a commit is being made, it leaves
    /// out the shortcut, which can't run yet either.
    static func help(agent: NamedAgent, rewrites: Bool, readiness: MessageGenerator.Readiness) -> String {
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
    /// writing already, and Stop is in its place.
    case hidden
    case shown(agent: NamedAgent, rewrites: Bool, readiness: MessageGenerator.Readiness)

    init(showsButton: Bool, agent: NamedAgent?, hasText: Bool, isWriting: Bool, readiness: MessageGenerator.Readiness) {
        guard showsButton, let agent, !isWriting else {
            self = .hidden
            return
        }
        self = .shown(agent: agent, rewrites: hasText, readiness: readiness)
    }
}
