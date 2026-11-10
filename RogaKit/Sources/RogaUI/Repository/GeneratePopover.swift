import AgentEngine
import SwiftUI

/// What the Generate button's chevron opens: which agent writes the message,
/// with which model and effort, and the exact command that runs (decision 41).
///
/// Each agent is a row with its model and effort on a second line, and a check
/// before the picked one, as setup's menus mark a choice. On the picked
/// agent's row those two words are menus, so what's changed is plainly that
/// agent's, and the other rows say theirs in gray. It's laid out as Roga's
/// dialogs are (decision 29), with the command along its bottom edge. Every
/// pick is stored as it's made, the same values the Commit page in Settings
/// shows, so the next click of Generate uses them. It has no Generate of its
/// own: the button it hangs from runs what's picked, and says which agent.
///
/// It's the same size whichever agent is picked. The popover hangs from the
/// button under it, so a change in its height would move every row above the
/// command, and the row about to be clicked with it.
struct GeneratePopover: View {
    let agents: AgentProvider
    /// The worktree's folder and whether the box has words in it, which the
    /// command shows.
    let worktree: String
    let hasDraft: Bool
    /// Shows an agent's page in Settings, where a model the menu doesn't offer
    /// can be typed, as Codex's are.
    let openAgentSettings: (AgentKind) -> Void
    let close: () -> Void

    /// Wide enough for the command to take fewer lines.
    static var width: CGFloat { 400 }

    var body: some View {
        let picked = agents.generateAgent
        let setup = picked.flatMap { agents.generation(with: $0) }
        VStack(alignment: .leading, spacing: 0) {
            Text("Write the message with")
                .font(.system(size: 13, weight: .semibold))
                .padding(EdgeInsets(top: 13, leading: 16, bottom: 8, trailing: 16))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 2) {
                ForEach(AgentKind.allCases, id: \.self) { kind in
                    GeneratePopoverAgentRow(kind: kind, agents: agents, isPicked: kind == picked) {
                        openAgentSettings(kind)
                    }
                }
            }
            .padding(.horizontal, 6)
            // Picking is all there is to do here, so this says there's
            // nothing to confirm.
            Text("Remembered for next time")
                .font(.system(size: 12.5))
                .foregroundStyle(DialogColors.note)
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            if let setup {
                CommandBlock(
                    lines: setup.terminal(worktree: worktree, hasDraft: hasDraft),
                    isCompact: true,
                    // Room for the other agents' commands, which wrap onto
                    // more or fewer lines.
                    reserving: AgentKind.allCases.filter { $0 != setup.kind }.compactMap {
                        agents.generation(with: $0)?.terminal(worktree: worktree, hasDraft: hasDraft)
                    }
                )
            }
        }
        .frame(width: Self.width)
        .font(.system(size: 13))
        // The popover's arrow points down at the chevron from under the command,
        // so it's the command's color, as the canvas draws it. The system clips
        // what's drawn past the popover's edges to its shape, arrow included.
        .background(alignment: .bottom) {
            if setup != nil {
                DialogColors.terminal
                    .frame(height: 24)
                    .offset(y: 24)
            }
        }
        // A plain surface over the system's material, like a dialog's.
        .background {
            DialogColors.surface
                .padding(-24)
        }
        .background {
            // Escape closes it, as it does a menu.
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

extension GeneratePopover {
    /// Why an agent can't be picked, for the second line of its row, or nil
    /// when it can.
    static func unusableReason(_ kind: AgentKind, in agents: AgentProvider) -> String? {
        guard let lookup = agents.lookups[kind] else { return "Looking for it…" }
        switch lookup {
        case .found:
            return agents.settings[kind]?.isEnabled == false ? "Turned off" : nil
        case .notFound, .configuredMissing:
            return "Not found"
        case .unusable(let skipped):
            return reason(skipped)
        case .configuredUnusable(let skipped):
            return reason([skipped])
        }
    }

    private static func reason(_ skipped: [SkippedAgent]) -> String {
        let isTooOld = skipped.contains { if case .tooOld = $0.reason { true } else { false } }
        return isTooOld ? "Too old to use" : "Couldn't run it"
    }

    /// The second line of a usable agent's row: its model and its effort, as in
    /// "haiku · low effort".
    static func detail(_ kind: AgentKind, model: String, effort: String, codexDefaultModel: String?) -> String {
        "\(modelWords(kind, model: model, codexDefaultModel: codexDefaultModel)) · \(effortWords(effort))"
    }

    /// The model's half of an agent's second line, as in "haiku". Codex's own
    /// default model is named when its configuration says which it is.
    static func modelWords(_ kind: AgentKind, model: String, codexDefaultModel: String?) -> String {
        guard model.isEmpty else { return model }
        return (kind == .codex ? codexDefaultModel : nil) ?? "default model"
    }

    /// The effort's half of an agent's second line, as in "low effort".
    static func effortWords(_ effort: String) -> String {
        effort.isEmpty ? "default effort" : "\(effort) effort"
    }

    /// What a model is called in its menu: Default for the agent's own, with
    /// Codex's model from its configuration when that's known.
    static func modelTitle(_ model: String, kind: AgentKind, codexDefaultModel: String?) -> String {
        if model.isEmpty, kind == .codex, let codexDefaultModel { return "Default · \(codexDefaultModel)" }
        return AgentKind.modelTitle(model)
    }
}

/// One agent in the popover, with its model and effort under its name, or why
/// it can't be used, dimmed. The picked agent's model and effort are menus.
/// That second line is as tall as the menus on every row, so that picking
/// another agent moves nothing.
struct GeneratePopoverAgentRow: View {
    let kind: AgentKind
    let agents: AgentProvider
    let isPicked: Bool
    /// Shows the agent's page in Settings, for a model its menu doesn't offer.
    var openSettings: () -> Void = {}
    @AppStorage private var model: String
    @AppStorage private var effort: String
    @State private var isHovering = false

    /// How tall the second line is, which is how tall its menus are.
    static let secondLineHeight: CGFloat = 22

    init(kind: AgentKind, agents: AgentProvider, isPicked: Bool, openSettings: @escaping () -> Void = {}) {
        self.kind = kind
        self.agents = agents
        self.isPicked = isPicked
        self.openSettings = openSettings
        _model = AppStorage(wrappedValue: kind.recommendedModel, AgentPreferences.modelKey(kind))
        _effort = AppStorage(wrappedValue: AgentPreferences.recommendedEffort, AgentPreferences.effortKey(kind))
    }

    var body: some View {
        let reason = GeneratePopover.unusableReason(kind, in: agents)
        Group {
            if isPicked {
                // It's picked already, so the row itself does nothing, and the
                // menus in it can be clicked, which they can't inside a button.
                row(reason: reason)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(kind.name)
                    .accessibilityAddTraits(.isSelected)
            } else {
                Button {
                    agents.setGenerateAgent(kind)
                } label: {
                    row(reason: reason)
                }
                .buttonStyle(GeneratePopoverRowStyle())
                .disabled(reason != nil)
                // As in setup's menus, the pointer over a row that can be
                // picked shades it, which says it can be clicked.
                .onHover { isHovering = $0 && reason == nil }
            }
        }
        // The button that tracks the pointer goes once the row is picked, and
        // with it the pointer's leaving, so a row starts unshaded each time.
        .onChange(of: isPicked) { isHovering = false }
    }

    private func row(reason: String?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return HStack(alignment: .top, spacing: 6) {
            ChoiceCheck(isChecked: isPicked)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.name)
                    .foregroundStyle(reason == nil ? Color.primary : DialogColors.note)
                Group {
                    if isPicked, reason == nil {
                        choices
                    } else {
                        Text(reason ?? GeneratePopover.detail(kind, model: model, effort: effort, codexDefaultModel: agents.codexDefaultModel))
                            .font(.system(size: 12))
                            .foregroundStyle(DialogColors.note)
                    }
                }
                .frame(height: Self.secondLineHeight)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .background {
            if isPicked {
                shape.fill(DialogColors.card)
            } else if isHovering {
                shape.fill(SettingsColors.hover)
            }
        }
        .contentShape(shape)
    }

    /// The picked agent's second line, where its model and effort open menus.
    private var choices: some View {
        HStack(spacing: 5) {
            GeneratePopoverMenu(
                title: GeneratePopover.modelWords(kind, model: model, codexDefaultModel: agents.codexDefaultModel),
                name: "Model",
                selection: $model,
                options: GenerateChoices.models(for: kind, stored: model).map {
                    (value: $0, title: GeneratePopover.modelTitle($0, kind: kind, codexDefaultModel: agents.codexDefaultModel))
                },
                // Codex's models come from the account, so they're typed on its page.
                more: kind == .codex ? (title: "Another model…", action: openSettings) : nil
            )
            Text("·")
                .font(.system(size: 12))
                .foregroundStyle(DialogColors.note)
                .accessibilityHidden(true)
            GeneratePopoverMenu(
                title: GeneratePopover.effortWords(effort),
                name: "Effort",
                selection: $effort,
                options: GenerateChoices.efforts(stored: effort).map { (value: $0, title: AgentKind.effortTitle($0)) }
            )
        }
    }
}

/// A word on the picked agent's second line that opens a menu of the other
/// choices: the word and a chevron in a white box with a line around it, which
/// says it can be clicked without a label beside it. The tooltip names it.
private struct GeneratePopoverMenu: View {
    let title: String
    /// What it chooses, for the tooltip and VoiceOver.
    let name: String
    @Binding var selection: String
    let options: [(value: String, title: String)]
    /// A command after the choices, for a value that isn't one of them.
    var more: (title: String, action: () -> Void)?
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Menu {
            SettingsChoices(selection: $selection, options: options)
            if let more {
                Divider()
                Button(more.title, action: more.action)
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                SettingsChevron()
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .padding(.leading, 7)
            .padding(.trailing, 5)
            .frame(height: 22)
            .background {
                shape.fill(DialogColors.surface)
                if isHovering { shape.fill(SettingsColors.hover) }
            }
            .overlay { shape.strokeBorder(SettingsColors.line, lineWidth: 1) }
            .contentShape(shape)
            .onHover { isHovering = $0 }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(name)
        .accessibilityLabel(name)
        .accessibilityValue(title)
    }
}

/// An agent's row. One that can't be picked is already gray, and says why, so
/// unlike the plain style it isn't dimmed again, which would make the why hard
/// to read.
private struct GeneratePopoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
