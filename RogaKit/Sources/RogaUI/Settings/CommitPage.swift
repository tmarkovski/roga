import AgentEngine
import Foundation
import GitRunner
import SwiftUI

/// Settings › Commit, which has the one section that's built so far: how
/// Generate writes a commit message (decision 41). It shows and changes the
/// same agent, model and effort as the Generate popover, which remembers them,
/// so there's one place they're kept, and it ends with the exact command.
///
/// Search shows it too, with only the settings it found.
struct CommitSection: View {
    /// The settings to show, which search narrows.
    var items = SettingsGroup.generate.items
    /// Whether the page's name goes beside the heading, as in search.
    var namesPage = false
    /// Goes to another page of Settings.
    let show: (SettingsDestination) -> Void

    @Environment(AgentProvider.self) private var agents
    @AppStorage(AgentPreferences.showsGenerateButtonKey) private var showsButton = true
    @AppStorage(AgentPreferences.matchesStyleKey) private var matchesStyle = true
    /// The instructions someone wrote, or nil for Roga's own. Resetting
    /// removes them rather than storing a copy of Roga's, so that the default
    /// can improve in a later version.
    @AppStorage(AgentPreferences.instructionsKey) private var storedInstructions: String?

    private var instructions: Binding<String> {
        Binding {
            storedInstructions ?? CommitMessagePrompt.defaultStyle
        } set: {
            storedInstructions = $0
        }
    }

    var body: some View {
        let kind = GenerateChoices.shownAgent(agents)
        SettingsSection(title: SettingsGroup.generate.title) {
            if namesPage {
                Text(SettingsPage.commit.title)
                    .foregroundStyle(SettingsColors.note)
            }
        } content: {
            ForEach(items, id: \.self) { item in
                row(item, kind: kind)
            }
        }
    }

    @ViewBuilder private func row(_ item: SettingsItem, kind: AgentKind) -> some View {
        switch item {
        case .showsGenerateButton:
            SettingsRow(title: item.title, help: item.help) {
                Toggle(item.title, isOn: $showsButton)
                    .toggleStyle(.settings)
            }
        case .generateAgent:
            SettingsRow(title: item.title, help: item.help) {
                SettingsSelect(
                    selection: Binding { agents.generateAgent ?? kind } set: { agents.setGenerateAgent($0) },
                    options: agents.usableAgents.map { (value: $0, title: $0.name) },
                    emptyTitle: GenerateChoices.noAgentTitle(agents)
                )
            }
        case .generateModel:
            SettingsRow(title: item.title, help: GenerateChoices.modelHelp(kind, onAgentPage: false, agents: agents)) {
                AgentModelControl(kind: kind, typesName: false) {
                    show(.agent(kind))
                }
                .id(kind)
            }
        case .generateEffort:
            SettingsRow(title: item.title, help: nil) {
                AgentEffortControl(kind: kind, isSegmented: true)
                    .id(kind)
            }
        case .matchesStyle:
            SettingsRow(title: item.title, help: item.help) {
                Toggle(item.title, isOn: $matchesStyle)
                    .toggleStyle(.settings)
            }
        case .instructions:
            SettingsBlock {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Reset to Roga's") {
                            storedInstructions = nil
                        }
                        .buttonStyle(SettingsLinkStyle())
                        .disabled(storedInstructions == nil)
                        .help("Puts back the instructions Roga came with")
                    }
                    SettingsTextArea(text: instructions, label: item.title)
                }
            }
        case .generateCommand:
            SettingsBlock {
                VStack(alignment: .leading, spacing: 7) {
                    SettingsCommand(lines: GenerateChoices.terminal(for: kind, agents: agents, style: instructions.wrappedValue))
                    Text(item.help)
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .foregroundStyle(SettingsColors.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        default:
            EmptyView()
        }
    }
}

/// The model an agent writes messages with, which Settings and the Generate
/// popover keep in one place: a popup of the models it knows, or a field to
/// type one for Codex on its own page, since Codex's models depend on the
/// account.
struct AgentModelControl: View {
    let kind: AgentKind
    /// Whether it's a field to type the model's name in, rather than a popup.
    let typesName: Bool
    /// Goes where a model that isn't in the popup can be typed.
    var another: (() -> Void)?

    @Environment(AgentProvider.self) private var agents
    @AppStorage private var model: String

    init(kind: AgentKind, typesName: Bool, another: (() -> Void)? = nil) {
        self.kind = kind
        self.typesName = typesName
        self.another = another
        _model = AppStorage(wrappedValue: kind.recommendedModel, AgentPreferences.modelKey(kind))
    }

    var body: some View {
        if typesName {
            SettingsTextField(text: $model, placeholder: "Default", width: 170)
        } else {
            SettingsPopup(
                selection: $model,
                options: GenerateChoices.models(for: kind, stored: model).map { (value: $0, title: AgentKind.modelTitle($0)) },
                detail: { model in model.isEmpty && kind == .codex ? agents.codexDefaultModel : nil },
                // Codex's names come from the account, so they're typed on its page.
                more: kind == .codex ? another.map { (title: "Another Model…", action: $0) } : nil
            )
        }
    }
}

/// How hard an agent's model thinks while it writes a message: segments on
/// the Commit page, as on the canvas, and a popup on the agent's own page.
struct AgentEffortControl: View {
    let kind: AgentKind
    let isSegmented: Bool
    @AppStorage private var effort: String

    init(kind: AgentKind, isSegmented: Bool) {
        self.kind = kind
        self.isSegmented = isSegmented
        _effort = AppStorage(wrappedValue: AgentPreferences.recommendedEffort, AgentPreferences.effortKey(kind))
    }

    var body: some View {
        let options = GenerateChoices.efforts(stored: effort).map { (value: $0, title: AgentKind.effortTitle($0)) }
        if isSegmented {
            SettingsSegments(selection: $effort, options: options)
        } else {
            SettingsPopup(selection: $effort, options: options)
        }
    }
}

/// What the Commit page and the agents' pages offer and say about writing a
/// message, kept apart from the views so that tests can check it.
enum GenerateChoices {
    /// The agent whose model and effort the Commit page shows: the one
    /// Generate runs, or else the first Roga found, or else Claude Code, so
    /// that the page shows what it would run once there is one.
    static func shownAgent(_ agents: AgentProvider) -> AgentKind {
        agents.generateAgent ?? AgentKind.allCases.first { agents.installation($0) != nil } ?? .claude
    }

    /// What the Agent popup says when there's no agent to choose.
    static func noAgentTitle(_ agents: AgentProvider) -> String {
        if agents.isLooking { return "Looking…" }
        return AgentKind.allCases.contains { agents.installation($0) != nil } ? "Turned off" : "None found"
    }

    /// The models a picker offers, with the stored one added when it's
    /// another, such as a model typed on Codex's page.
    static func models(for kind: AgentKind, stored: String) -> [String] {
        kind.modelChoices.contains(stored) ? kind.modelChoices : kind.modelChoices + [stored]
    }

    /// The efforts a picker offers, with the stored one added when it's
    /// another, such as one set with `defaults write`.
    static func efforts(stored: String) -> [String] {
        AgentKind.effortChoices.contains(stored) ? AgentKind.effortChoices : AgentKind.effortChoices + [stored]
    }

    /// What a time limit popup offers, in seconds.
    static func timeLimits(stored: Int) -> [Int] {
        AgentPreferences.timeLimits.contains(stored) ? AgentPreferences.timeLimits : (AgentPreferences.timeLimits + [stored]).sorted()
    }

    /// The help under Model, which on an agent's own page says how Roga
    /// passes it on, and for Codex where its Default comes from.
    static func modelHelp(_ kind: AgentKind, onAgentPage: Bool, agents: AgentProvider) -> String {
        switch (kind, onAgentPage) {
        case (.claude, false):
            return "Something fast is plenty for a commit message."
        case (.claude, true):
            return "Passed as --model. Default leaves it to Claude Code's own settings."
        case (.codex, false):
            return "Something fast is plenty for a commit message. Default is the one in \(codexConfiguration(agents))."
        case (.codex, true):
            let model = agents.codexDefaultModel.map { " (\($0))" } ?? ""
            return "Passed as -m. Default is the model in \(codexConfiguration(agents))\(model)."
        }
    }

    /// The help under Effort on an agent's own page.
    static func effortHelp(_ kind: AgentKind, agents: AgentProvider) -> String {
        switch kind {
        case .claude: "Passed as --effort. Default leaves it to Claude Code's own settings."
        case .codex: "Passed as -c model_reasoning_effort. Default is the one in \(codexConfiguration(agents))."
        }
    }

    /// Codex's `config.toml`, as people would type its path.
    static func codexConfiguration(_ agents: AgentProvider) -> String {
        let home = agents.installer?.codexHome ?? NSHomeDirectory() + "/.codex"
        return (home as NSString).abbreviatingWithTildeInPath + "/config.toml"
    }

    /// The command Generate runs with an agent and what's chosen for it, as a
    /// command block shows it (decision 29): a line that says the staged
    /// changes go to its standard input, then the command. While Roga hasn't
    /// found the agent, it's the command by the program's name, so the page
    /// still says what would run.
    static func terminal(for kind: AgentKind, agents: AgentProvider, style: String) -> [TerminalLine] {
        let found = agents.commitMessageAgent(kind)
        let settings = agents.settings[kind] ?? AgentSettings.read(kind, from: .standard)
        let agent = found ?? CommitMessageAgent(
            kind: kind,
            executable: kind.executableName,
            model: settings.model.isEmpty ? nil : settings.model,
            effort: settings.effort.isEmpty ? nil : settings.effort,
            extraArguments: settings.extraArguments,
            timeLimit: settings.timeLimit
        )
        let command = CommitMessageCommand.command(for: agent, worktree: NSHomeDirectory(), style: style, hasDraft: false)
        let showsPath = found != nil && agents.showsPath(agent.executable)
        return [.comment("The staged changes go to its standard input"), .program(command, showsPath: showsPath)]
    }
}
