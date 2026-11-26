import IconUI
import SwiftUI

/// A button that has the default agent do a job, cut in two by a thin line,
/// with a chevron that opens the agent popover under it for choosing the
/// agent, its model and its effort (decision 91). Resolve in the diff's header
/// and Fix in a dialog use it, as Generate's button does in the message box,
/// and all three open the same popover.
///
/// It has the orange line around it that marks an agent's command
/// (decision 68), which lights while the popover is open.
struct AgentSplitButton: View {
    enum Look {
        /// Plain words in the diff's header, as tall as the buttons beside them.
        case header
        /// A dialog's secondary button.
        case dialog
    }

    let title: String
    let look: Look
    let choice: AgentChoice
    /// What the main part's tooltip says, if anything.
    var help: String = ""
    var isEnabled = true
    let action: () -> Void
    @Environment(AgentProvider.self) private var agents: AgentProvider?
    @Environment(\.openSettings) private var openSettings
    @State private var isChoosing = false
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        HStack(spacing: 0) {
            Button {
                // A click while the popover is open runs what was just picked
                // there, and closes it.
                isChoosing = false
                action()
            } label: {
                Text(title)
                    .padding(.leading, look == .dialog ? 12 : 8)
                    .padding(.trailing, look == .dialog ? 10 : 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .help(help)
            .accessibilityLabel(title)
            Rectangle()
                .fill(SettingsColors.line)
                .frame(width: 1)
            Button {
                isChoosing.toggle()
            } label: {
                Icon.dropdown.image
                    .font(.system(size: 11 / 1.128, weight: .medium))
                    .foregroundStyle(DialogColors.note)
                    .padding(.horizontal, look == .dialog ? 7 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .opensOnPress($isChoosing)
            .help("Choose an Agent")
            .accessibilityLabel("Choose an Agent")
            .popover(isPresented: $isChoosing, arrowEdge: .bottom) {
                if let agents {
                    AgentPopover(
                        agents: agents,
                        job: choice.job,
                        worktree: choice.worktree,
                        openAgentSettings: opensSettings ? { id in
                            isChoosing = false
                            openSettings(.agent(id))
                        } : nil
                    ) {
                        isChoosing = false
                    }
                }
            }
        }
        .buttonStyle(AgentSplitPartStyle())
        .font(look == .dialog ? .system(size: 13, weight: .medium) : .system(size: 12))
        .lineLimit(1)
        .foregroundStyle(Color.primary)
        .frame(height: look == .dialog ? 28 : 24)
        .background {
            if look == .dialog { shape.fill(DialogColors.secondaryButton) }
        }
        .clipShape(shape)
        .overlay {
            AgentOutline(shape: .outline(cornerRadius: cornerRadius), isEnabled: isEnabled, isHovering: isHovering, isLit: isChoosing)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .fixedSize()
    }

    private var cornerRadius: CGFloat {
        look == .dialog ? 9 : 6
    }

    /// Settings is a sheet on the window, which can't open over a dialog's, so
    /// the popover in a dialog leaves the agents' pages out of its ⋯ menus.
    private var opensSettings: Bool {
        look == .header
    }
}

/// Either half of an agent's split button, which only dims while it's pressed.
private struct AgentSplitPartStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    /// Hands `agents` to what a sheet shows, so that a dialog's agent button
    /// can open the agent popover, without depending on the sheet inheriting
    /// the window's environment.
    @ViewBuilder func agentProvider(_ agents: AgentProvider?) -> some View {
        if let agents {
            environment(agents)
        } else {
            self
        }
    }
}
