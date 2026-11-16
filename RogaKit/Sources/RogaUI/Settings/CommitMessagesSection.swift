import AgentEngine
import Foundation
import SwiftUI

/// Settings › Git › Commit messages: how Generate writes a commit message
/// (decision 41). It used to be a page of its own, and folded into Git once
/// the agent and its model moved to the Agents page (decision 89). It shows
/// only while Roga uses agents.
///
/// Search shows it too, with only the settings it found.
struct CommitSection: View {
    /// The settings to show, which search narrows.
    var items = SettingsGroup.generate.items
    /// Whether the page's name goes beside the heading, as in search.
    var namesPage = false

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
        SettingsSection(title: SettingsGroup.generate.title) {
            if namesPage {
                Text(SettingsPage.git.title)
                    .foregroundStyle(SettingsColors.note)
            }
        } content: {
            ForEach(items, id: \.self) { item in
                row(item)
            }
        }
    }

    @ViewBuilder private func row(_ item: SettingsItem) -> some View {
        switch item {
        case .showsGenerateButton:
            SettingsRow(title: item.title, help: item.help) {
                Toggle(item.title, isOn: $showsButton)
                    .toggleStyle(.settings)
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
                        Button("Restore Defaults") {
                            storedInstructions = nil
                        }
                        .buttonStyle(SettingsLinkStyle())
                        .disabled(storedInstructions == nil)
                        .help("Restore the default commit message instructions")
                    }
                    SettingsTextArea(text: instructions, label: item.title)
                }
            }
        default:
            EmptyView()
        }
    }
}

/// The model Claude Code or Codex runs with, on its own page, which the
/// Generate popover changes too: a popup of the models Claude Code knows, or
/// a field to type one for Codex, since Codex's models depend on the account.
struct AgentModelControl: View {
    let kind: AgentKind
    @Environment(AgentProvider.self) private var agents
    @AppStorage private var model: String

    init(kind: AgentKind) {
        self.kind = kind
        _model = AppStorage(wrappedValue: kind.recommendedModel, AgentPreferences.modelKey(kind))
    }

    var body: some View {
        if kind == .codex {
            SettingsTextField(text: $model, placeholder: GenerateChoices.codexModelPlaceholder(agents.codexDefaultModel), width: 170)
        } else {
            SettingsPopup(
                selection: $model,
                options: GenerateChoices.models(for: kind, stored: model).map { (value: $0, title: AgentKind.modelTitle($0)) }
            )
        }
    }
}

/// How hard an agent's model thinks, on its own page, as a popup.
struct AgentEffortControl: View {
    let kind: AgentKind
    @AppStorage private var effort: String

    init(kind: AgentKind) {
        self.kind = kind
        _effort = AppStorage(wrappedValue: AgentPreferences.recommendedEffort, AgentPreferences.effortKey(kind))
    }

    var body: some View {
        SettingsPopup(selection: $effort, options: GenerateChoices.efforts(stored: effort).map { (value: $0, title: AgentKind.effortTitle($0)) })
    }
}

/// What the agents' pages and the Generate popover offer for a model and an
/// effort, kept apart from the views so that tests can check it.
enum GenerateChoices {
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

    /// What Codex's model field says while it's empty: Default, with the
    /// model in Codex's own configuration when Roga knows it.
    static func codexModelPlaceholder(_ codexDefaultModel: String?) -> String {
        codexDefaultModel.map { "Default · \($0)" } ?? "Default"
    }

    /// Codex's `config.toml`, as people would type its path.
    static func codexConfiguration(_ agents: AgentProvider) -> String {
        let home = agents.installer?.codexHome ?? NSHomeDirectory() + "/.codex"
        return (home as NSString).abbreviatingWithTildeInPath + "/config.toml"
    }
}
