#if DEBUG
import AgentEngine
import GitRunner
import SwiftUI

// Setup's screens on the made-up Mac in `PreviewMac`, each in a window the
// size Roga opens with. The previews are live: the buttons go from screen to
// screen, menus open, and Look Again finds the same gits again. Nothing runs
// a real git or agent, so Install Hooks does nothing, and what a preview
// chooses goes to UserDefaults of the previews' own.

#Preview("Welcome") {
    SetupPreview(step: .welcome)
}

#Preview("Looking") {
    // Roga has found git and is still looking for the agents.
    SetupPreview(step: .looking, agents: nil)
}

#Preview("Git") {
    SetupPreview(step: .git)
}

#Preview("Git, menu open") {
    SetupPreview(step: .git, openMenu: "git")
}

#Preview("Git, none found") {
    SetupPreview(step: .git, gits: PreviewMac.noGits)
}

#Preview("Agents") {
    SetupPreview(step: .agents)
}

#Preview("Agents, Claude Code's menu open") {
    SetupPreview(step: .agents, openMenu: "agent-claude")
}

#Preview("Agents, none found") {
    SetupPreview(step: .agents, agents: PreviewMac.noAgents)
}

#Preview("Hooks") {
    SetupPreview(step: .hooks, usesAgents: true, hooks: [.claude: .notInstalled, .codex: .notInstalled])
}

#Preview("Hooks, waiting for Codex") {
    SetupPreview(step: .hooks, usesAgents: true, hooks: [.claude: .installed, .codex: .needsTrust])
}

#Preview("Ready") {
    SetupPreview(step: .ready, usesAgents: true, hooks: [.claude: .installed, .codex: .needsTrust])
}

#Preview("Ready, without agents") {
    SetupPreview(step: .ready, usesAgents: false)
}

/// One of setup's screens, with what Roga found on the made-up Mac and the
/// answers given before it.
private struct SetupPreview: View {
    @State private var setup: SetupModel
    @State private var gitProvider: GitProvider
    @State private var agents: AgentProvider
    @State private var updates: Updates
    private let openMenu: String?

    /// - Parameters:
    ///   - step: The screen to show.
    ///   - gits: Every git on the Mac.
    ///   - surveys: Every copy of each agent on the Mac, or nil while Roga is
    ///     still looking for them.
    ///   - usesAgents: The answer on the Agents screen, or nil before it.
    ///   - hooks: What each agent says about Roga's hooks.
    ///   - openMenu: The row whose menu is open, as "git" or "agent-claude".
    init(
        step: SetupModel.Step,
        gits: GitSurvey = PreviewMac.gits,
        agents surveys: [AgentKind: AgentSurvey]? = PreviewMac.surveys,
        usesAgents: Bool? = nil,
        hooks: [AgentKind: HookStatus] = [:],
        openMenu: String? = nil
    ) {
        let defaults = PreviewMac.defaults()

        let setup = SetupModel(hasRepositories: false, defaults: defaults)
        setup.setStateForTests(step: step, usesAgents: .some(usesAgents))

        let gitProvider = GitProvider(defaults: defaults, finding: .preview(gits))
        let state: GitProvider.State = switch PreviewMac.locate(nil, in: gits) {
        case .success(let installation): .ready(Git(installation: installation))
        case .failure(let error): .failed(error)
        }
        gitProvider.setStateForTests(state: state, survey: .some(gits))

        // The provider is never started, so it has nothing to run the
        // agents with.
        let agents = AgentProvider(
            supportFolder: FileManager.default.temporaryDirectory.appending(path: "RogaPreviews", directoryHint: .isDirectory),
            helperPath: "/Applications/Roga.app/Contents/Helpers/roga",
            defaults: defaults,
            codexHome: nil,
            wellKnown: [:]
        )
        if let surveys {
            agents.setStateForTests(
                lookups: surveys.mapValues(\.lookup),
                surveys: surveys,
                hookStatus: hooks,
                installCommands: PreviewMac.installCommands(surveys)
            )
        }

        // As a release has it, where Sparkle checks for updates by itself.
        let updates = Updates()
        updates.controls = PreviewUpdater.shared
        updates.checksAutomatically = true

        _setup = State(initialValue: setup)
        _gitProvider = State(initialValue: gitProvider)
        _agents = State(initialValue: agents)
        _updates = State(initialValue: updates)
        self.openMenu = openMenu
    }

    var body: some View {
        SetupView(setup: setup, openMenu: openMenu)
            .environment(gitProvider)
            .environment(agents)
            .environment(updates)
            .frame(width: 1280, height: 800)
    }
}

extension GitProvider.Finding {
    /// Finds the gits in a survey a moment after it's asked, without reading
    /// the login shell or running any of them.
    nonisolated static func preview(_ survey: GitSurvey) -> Self {
        Self(
            searchPath: {
                try? await Task.sleep(for: PreviewMac.lookTime)
                return (survey.searchPath, true)
            },
            locate: { chosen, _ in PreviewMac.locate(chosen, in: survey) },
            survey: { _ in survey }
        )
    }
}

/// Stands in for Sparkle, so that Ready shows the switches for updates the
/// way a release does. `Updates` holds it weakly, so it's kept here.
private final class PreviewUpdater: UpdaterControls {
    static let shared = PreviewUpdater()

    func setChecksAutomatically(_ checks: Bool) {}
    func setDownloadsAutomatically(_ downloads: Bool) {}
    func showUpdate() {}
    func installNow() {}
}
#endif
