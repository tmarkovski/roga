import AgentEngine
import IconUI
import SwiftUI

/// What the chevron beside Generate, Resolve and Fix opens: which agent runs,
/// with which model and effort, and the exact command the job runs
/// (decisions 41 and 91).
///
/// Each agent is a card with a radio, its name, and its model and effort, its
/// command or why it can't be used under the name. The default agent's card
/// has an ink edge. A ⋯ at the right of each card's first line opens the
/// agent's models and efforts, and its page in Settings, so a row looks the
/// same whether or not it's picked, and picking one moves nothing. Custom
/// agents come after Claude Code and Codex, with their command on the second
/// line, since they have no model or effort. It's laid out as Roga's dialogs
/// are (decision 29), with the job's command along its bottom edge.
///
/// Every pick is stored as it's made: the agent is the default agent of
/// Settings › Agents, which Generate, Resolve and Fix all run, and the model
/// and effort are the ones on that agent's page (decision 89). It has no button
/// of its own to run anything: the button it hangs from runs what's picked,
/// and says which agent.
///
/// It's the same size whichever agent is picked. It hangs from a button, so a
/// change in its height would move every card, and the one about to be clicked
/// with it.
struct AgentPopover: View {
    let agents: AgentProvider
    let job: AgentJob
    /// The worktree's folder, which the command shows.
    let worktree: String
    /// Shows an agent's page in Settings, where a model the menu doesn't offer
    /// can be typed, as Codex's are. Nil inside a dialog, which Settings can't
    /// open over, so the ⋯ menus leave it out.
    let openAgentSettings: ((AgentID) -> Void)?
    let close: () -> Void

    /// Wide enough for the command to take fewer lines.
    static var width: CGFloat { 400 }

    var body: some View {
        let picked = agents.defaultAgent
        let setup = picked.flatMap { agents.generation(with: $0) }
        VStack(alignment: .leading, spacing: 0) {
            Text("Default agent")
                .font(.system(size: 13, weight: .semibold))
                .padding(EdgeInsets(top: 13, leading: 16, bottom: 8, trailing: 16))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 6) {
                ForEach(AgentKind.allCases, id: \.self) { kind in
                    AgentPopoverRow(kind: kind, agents: agents, isPicked: .known(kind) == picked, openSettings: settings(for: .known(kind)))
                }
                ForEach(agents.customAgents) { custom in
                    AgentCard(
                        name: custom.shownName,
                        detail: custom.command,
                        isMonospaced: true,
                        isPicked: .custom(custom.id) == picked,
                        isUsable: true,
                        hasOptions: openAgentSettings != nil,
                        pick: { agents.setDefaultAgent(.custom(custom.id)) }
                    ) {
                        if let open = settings(for: .custom(custom.id)) {
                            Button("\(custom.shownName) Settings…", action: open)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            // Picking is all there is to do here, so this says there's nothing
            // to confirm, and that the pick is the other jobs' too.
            Text(job.sharedNote)
                .font(.system(size: 12.5))
                .foregroundStyle(DialogColors.note)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            if let setup {
                CommandBlock(
                    lines: setup.terminal(for: job, worktree: worktree),
                    isCompact: true,
                    // Room for the other agents' commands, which wrap onto
                    // more or fewer lines.
                    reserving: agents.availableAgents.filter { $0 != setup.id }.compactMap {
                        agents.generation(with: $0)?.terminal(for: job, worktree: worktree)
                    }
                )
            }
        }
        .frame(width: Self.width)
        .font(.system(size: 13))
        // Over Generate, the popover's arrow points down at the chevron from
        // under the command, so it's the command's color, as the canvas draws
        // it. Under Resolve and Fix, the arrow is at the top and this is clipped
        // away: the system clips what's drawn past the popover's edges to its
        // shape, arrow included.
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

    /// Shows `id`'s page in Settings, when the popover can.
    private func settings(for id: AgentID) -> (() -> Void)? {
        openAgentSettings.map { open in { open(id) } }
    }
}

extension AgentPopover {
    /// Why an agent can't be picked, for the second line of its card, or nil
    /// when it can.
    static func unusableReason(_ kind: AgentKind, in agents: AgentProvider) -> String? {
        guard let lookup = agents.lookups[kind] else { return "Searching…" }
        switch lookup {
        case .found:
            return nil
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
        return isTooOld ? "Unsupported version" : "Unable to run"
    }

    /// The second line of a usable agent's card: its model and its effort, as
    /// in "haiku · low effort".
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

/// Claude Code or Codex in the popover, with its model and effort under its
/// name, or why it can't be used. Its ⋯ menu has the models and efforts, with
/// a check on the ones chosen, and its page in Settings. Changing them doesn't
/// pick the agent, so another agent's model can change without making it the
/// default.
struct AgentPopoverRow: View {
    let kind: AgentKind
    let agents: AgentProvider
    let isPicked: Bool
    let openSettings: (() -> Void)?
    @AppStorage private var model: String
    @AppStorage private var effort: String

    init(kind: AgentKind, agents: AgentProvider, isPicked: Bool, openSettings: (() -> Void)? = nil) {
        self.kind = kind
        self.agents = agents
        self.isPicked = isPicked
        self.openSettings = openSettings
        _model = AppStorage(wrappedValue: kind.recommendedModel, AgentPreferences.modelKey(kind))
        _effort = AppStorage(wrappedValue: AgentPreferences.recommendedEffort, AgentPreferences.effortKey(kind))
    }

    var body: some View {
        let reason = AgentPopover.unusableReason(kind, in: agents)
        let codexDefault = agents.codexDefaultModel
        AgentCard(
            name: kind.name,
            detail: reason ?? AgentPopover.detail(kind, model: model, effort: effort, codexDefaultModel: codexDefault),
            isMonospaced: false,
            isPicked: isPicked,
            isUsable: reason == nil,
            hasOptions: reason == nil || openSettings != nil,
            pick: { agents.setDefaultAgent(.known(kind)) }
        ) {
            if reason == nil {
                Section("Model") {
                    SettingsChoices(
                        selection: $model,
                        options: GenerateChoices.models(for: kind, stored: model).map {
                            (value: $0, title: AgentPopover.modelTitle($0, kind: kind, codexDefaultModel: codexDefault))
                        }
                    )
                    // Codex's models come from the account, so they're typed on its page.
                    if kind == .codex, let openSettings {
                        Button("Another Model…", action: openSettings)
                    }
                }
                Section("Effort") {
                    SettingsChoices(
                        selection: $effort,
                        options: GenerateChoices.efforts(stored: effort).map { (value: $0, title: AgentKind.effortTitle($0)) }
                    )
                }
            }
            if let openSettings {
                if reason == nil { Divider() }
                Button("\(kind.name) Settings…", action: openSettings)
            }
        }
    }
}

/// One agent in the popover, as a card: a radio, the agent's name, and a second
/// line under it, with a ⋯ at the right of the name's line for `options`. The
/// default agent's card has an ink edge twice as thick as the others' line. One
/// that can't be picked is gray, its radio too, and says why.
private struct AgentCard<Options: View>: View {
    let name: String
    let detail: String
    /// Whether the second line is a command, in the code font.
    let isMonospaced: Bool
    let isPicked: Bool
    let isUsable: Bool
    /// Whether it has a ⋯, which it doesn't when there's nothing in its menu.
    let hasOptions: Bool
    let pick: () -> Void
    @ViewBuilder let options: () -> Options
    @State private var isHovering = false

    /// How tall the second line is, whether it's words or a command.
    private static var secondLineHeight: CGFloat { 17 }
    /// The ⋯'s square.
    private static var optionsSize: CGFloat { 24 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: pick) {
            HStack(alignment: .top, spacing: 10) {
                AgentRadio(isOn: isPicked)
                    .opacity(isUsable ? 1 : 0.45)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .foregroundStyle(isUsable ? Color.primary : DialogColors.note)
                        .lineLimit(1)
                    Text(detail)
                        .font(isMonospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                        .foregroundStyle(DialogColors.note)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(height: Self.secondLineHeight)
                }
                Spacer(minLength: 0)
                // Room for the ⋯, which goes over the card rather than in it,
                // since a menu inside a button's label can't be clicked.
                if hasOptions {
                    Color.clear.frame(width: Self.optionsSize, height: 18)
                }
            }
            .padding(.vertical, 7)
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // As in setup's menus, the pointer over a card that can be
                // picked shades it, which says it can be clicked.
                if isHovering, !isPicked, isUsable {
                    shape.fill(SettingsColors.hover)
                }
            }
            .overlay {
                shape.strokeBorder(isPicked ? DialogColors.ink : SettingsColors.line, lineWidth: isPicked ? 2 : 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(AgentCardStyle())
        .disabled(!isUsable)
        .onHover { isHovering = $0 }
        .accessibilityLabel(name)
        .accessibilityValue(detail)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .overlay(alignment: .topTrailing) {
            if hasOptions {
                Menu(content: options) {
                    Icon.ellipsis.image
                }
                .menuStyle(.button)
                .buttonStyle(.icon(size: Self.optionsSize))
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 6))
                .help("\(name) Options")
                .accessibilityLabel("\(name) Options")
            }
        }
    }
}

/// The ring of a choice of one: hollow, or ink with a white middle once it's
/// the default agent. The popover is a panel rather than a menu, so it marks
/// its choice as a panel's radio buttons do, where a menu has a check.
private struct AgentRadio: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .strokeBorder(isOn ? DialogColors.ink : DialogColors.note, lineWidth: isOn ? 4.5 : 1)
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}

/// An agent's card. One that can't be picked is already gray, and says why, so
/// unlike the plain style it isn't dimmed again, which would make the why hard
/// to read.
private struct AgentCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
