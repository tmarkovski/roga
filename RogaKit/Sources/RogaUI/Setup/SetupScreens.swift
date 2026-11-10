import AgentEngine
import AgentHooks
import AppKit
import GitRunner
import IconUI
import SwiftUI

// MARK: Menus

extension ProgramMenu {
    /// Git's menu: every git Roga found. Choosing the one Roga recommends
    /// goes back to finding git itself, so that Roga follows a newer one.
    static func git(_ provider: GitProvider) -> ProgramMenu? {
        guard let survey = provider.survey else { return nil }
        let recommended = survey.recommended?.executable
        return ProgramMenu(
            id: "git",
            label: "Git installations",
            choices: ProgramChoices.git(
                survey,
                chosenPath: provider.chosenPath,
                current: provider.git?.installation,
                failure: provider.failure
            ),
            checked: provider.chosenPath ?? recommended,
            choose: { provider.choose($0.executable == recommended ? nil : $0.executable) },
            chooseAnother: {
                if let path = ProgramPanel.choose("git", startingAt: provider.git?.installation.executable) {
                    provider.choose(path)
                }
            }
        )
    }

    /// An agent's menu: every copy Roga found.
    ///
    /// - Parameters:
    ///   - isOn: Whether Roga uses the agent, which says whether a copy or
    ///     not using it has the check.
    ///   - choose: Makes a path the program Roga runs, or goes back to the
    ///     one Roga finds for nil.
    ///   - skip: What not using the agent does, where the menu offers it.
    static func agent(
        _ kind: AgentKind,
        agents: AgentProvider,
        isOn: Bool = true,
        choose: @escaping (String?) -> Void,
        skip: (() -> Void)? = nil
    ) -> ProgramMenu? {
        guard let survey = agents.surveys[kind] else { return nil }
        let program = agents.settings[kind]?.program
        let recommended = survey.recommended?.executable
        return ProgramMenu(
            id: "agent-\(kind.rawValue)",
            label: "\(kind.name) installations",
            choices: ProgramChoices.agent(survey, program: program, lookup: agents.lookups[kind]),
            checked: program ?? recommended,
            choose: { choose($0.executable == recommended ? nil : $0.executable) },
            chooseAnother: {
                if let path = ProgramPanel.choose(kind.executableName, startingAt: agents.installation(kind)?.executable) {
                    choose(path)
                }
            },
            skip: skip.map { Skip(title: "Don't use \(kind.name)", isOn: !isOn, action: $0) }
        )
    }
}

// MARK: Welcome

/// The first screen: room for the house, the wordmark, what Roga is for, and
/// one button in the middle, since there's nothing to go back to. Its parts
/// come in one after another when it appears.
struct SetupWelcome: View {
    let setup: SetupModel
    /// Tells setup where the house goes. `SetupHouseLayer` draws it there,
    /// so that the same house can go down to the floor.
    let house: (SetupHouseSpot) -> Void
    @State private var isIn = false

    var body: some View {
        VStack(spacing: 14) {
            Color.clear
                .frame(width: SetupLayout.welcomeHouse * HouseRig.frame.width / HouseRig.frame.height, height: SetupLayout.welcomeHouse)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SetupLayout.space)) } action: { frame in
                    house(SetupHouseSpot(foot: CGPoint(x: frame.midX, y: frame.maxY), height: frame.height))
                }
            Wordmark(width: 132)
                .padding(.top, 6)
                .setupEntrance(isIn, order: 1)
            Text("RATHER OPINIONATED GIT APP")
                .font(.system(size: 11.5, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(SetupColors.note)
                .setupEntrance(isIn, order: 2)
            Text("A native Git client for reviewing code and monitoring coding agents.")
                .font(.system(size: 17))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 10)
                .setupEntrance(isIn, order: 3)
            Button("Get Started") { setup.start() }
                .buttonStyle(.setup(.primary))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
                .setupEntrance(isIn, order: 4)
            Text("Configure Git and optional coding agents. You can change these preferences in Settings.")
                .font(.system(size: 12.5))
                .foregroundStyle(SetupColors.note)
                .setupEntrance(isIn, order: 5)
        }
        .frame(maxWidth: .infinity)
        .onAppear { isIn = true }
    }
}

// MARK: Looking

/// What Roga looks at, as it looks: the login shell's `PATH`, git, and each
/// agent. Nothing here is a choice, so its button only goes on.
struct SetupLooking: View {
    let setup: SetupModel
    let found: [AgentKind]
    @Environment(GitProvider.self) private var gitProvider
    @Environment(AgentProvider.self) private var agents

    private static let shell = LoginShellPath.userShell

    var body: some View {
        let isDone = !gitProvider.isLooking && (gitProvider.git == nil || !agents.isLooking)
        VStack(spacing: SetupLayout.gap) {
            SetupHead(
                eyebrow: "Your Mac",
                title: isDone ? "Scan complete" : "Detecting installed tools",
                sub: "Check your login shell's PATH and installed tool versions. This scan makes no changes."
            )
            SetupCard {
                ForEach(looks) { look in
                    LookRow(look: look)
                }
            }
            SetupActions(back: back) {
                Button(isDone ? "Continue" : "Looking…") { setup.next(found: found) }
                    .buttonStyle(.setup(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDone)
            }
        }
    }

    private func back() {
        setup.back(found: found)
    }

    private var looks: [SetupWords.Look] {
        let hasGit = gitProvider.git != nil
        let gitFailed = gitProvider.failure != nil && !gitProvider.isLooking
        return [
            SetupWords.pathLook(gitProvider.searchPath, shell: Self.shell),
            SetupWords.gitLook(
                state: gitProvider.state,
                survey: gitProvider.survey,
                isLooking: gitProvider.isLooking,
                hasPath: gitProvider.searchPath != nil
            ),
        ] + AgentKind.allCases.map {
            SetupWords.agentLook($0, lookup: agents.lookups[$0], survey: agents.surveys[$0], hasGit: hasGit, gitFailed: gitFailed)
        }
    }
}

/// One thing Roga looks at. Its mark turns into a check, and its words
/// change, as the answer comes in.
private struct LookRow: View {
    let look: SetupWords.Look
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        HStack(spacing: 12) {
            SetupGlyph(kind: glyph)
                .animation(SetupMotion.pop(reducesMotion), value: look.state)
            Text(look.name)
                .fontWeight(.medium)
                .frame(width: 120, alignment: .leading)
            Text(look.detail)
                .foregroundStyle(look.state == .missing ? AgentColors.warn : SetupColors.note)
                .lineLimit(1)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(SetupMotion.change(reducesMotion), value: look.detail)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(look.name)
        .accessibilityValue(look.detail)
    }

    private var glyph: SetupGlyph.Kind {
        switch look.state {
        case .waiting: .waiting
        case .looking: .spinner
        case .found: .ok
        case .missing: .warn
        }
    }
}

// MARK: Git

/// Which git Roga will run, with a menu of the others on its row. When Roga
/// can't use any git, the screen says what to install instead, and setup
/// goes no further until there's one.
struct SetupGit: View {
    let setup: SetupModel
    let found: [AgentKind]
    @Environment(GitProvider.self) private var gitProvider
    @State private var offersTools = false

    var body: some View {
        Group {
            switch gitProvider.failure {
            case .notFound(let developerToolsMissing)?:
                none(developerToolsMissing: developerToolsMissing)
            case .unsupported(_, let developerToolsMissing)?:
                none(developerToolsMissing: developerToolsMissing)
            case .configuredGitMissing?, .configuredGitUnsupported?, nil:
                chosen
            }
        }
        // Whatever was installed in another app is there by the time
        // someone comes back to Roga.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if gitProvider.git == nil, !gitProvider.isLooking { gitProvider.lookAgain() }
        }
    }

    private var chosen: some View {
        VStack(spacing: SetupLayout.gap) {
            SetupHead(eyebrow: "Git", title: heading, sub: SetupWords.gitSub)
            SetupCard {
                ProgramRow(
                    icon: .branch,
                    content: .git(state: gitProvider.state, survey: gitProvider.survey),
                    menu: .git(gitProvider),
                    choose: chooseAnother
                )
            }
            if let survey = gitProvider.survey {
                SetupNote(lines: SetupWords.gitNote(survey))
            }
            SetupActions(back: back) {
                Button("Continue") { setup.next(found: found) }
                    .buttonStyle(.setup(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(gitProvider.git == nil)
            }
        }
    }

    private var heading: String {
        switch gitProvider.state {
        case .locating: "Looking for Git"
        case .ready(let git): SetupWords.gitHeading(git.installation)
        case .failed: "Roga can't use the Git you chose"
        }
    }

    private func back() {
        setup.back(found: found)
    }

    private func none(developerToolsMissing: Bool) -> some View {
        let copies = gitProvider.survey?.copies ?? []
        let words = SetupWords.noGit(found: copies.count, developerToolsMissing: developerToolsMissing)
        return VStack(spacing: SetupLayout.gap) {
            SetupHead(eyebrow: "Git", title: words.heading, sub: words.sub)
            if let say = words.say {
                SetupSay(button: "Install Command Line Tools", words: say)
            }
            SetupCard(clips: true) {
                ForEach(copies, id: \.executable) { copy in
                    ProgramRow(icon: .branch, content: ProgramRowContent(
                        name: "Git",
                        version: copy.version?.description,
                        status: .warning(copy.version == nil ? "No version" : "Too old"),
                        line: ProgramSource.abbreviated(copy.executable)
                    ))
                }
                if developerToolsMissing {
                    ProgramRow(icon: .branch, content: ProgramRowContent(
                        name: "Git from Apple",
                        line: "It comes with the Command Line Tools, which aren't installed.",
                        tone: .plain,
                        isDimmed: true
                    ))
                }
                if words.offersTools {
                    CommandBlock(lines: [.program(Self.installTools, showsPath: false)], isCompact: true, fontSize: SetupLayout.commandFontSize)
                }
            }
            SetupNote(lines: [words.note])
            SetupActions(back: back) {
                Button("Choose Another…", action: chooseAnother)
                    .buttonStyle(.setup(.secondary))
                Button(gitProvider.isLooking ? "Scanning…" : "Rescan") { gitProvider.lookAgain() }
                    .buttonStyle(.setup(words.offersTools ? .secondary : .primary))
                    .disabled(gitProvider.isLooking)
                if words.offersTools {
                    Button("Install Command Line Tools") {
                        Task { await GitInstallation.offerDeveloperTools() }
                    }
                    .buttonStyle(.setup(.primary))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private static let installTools = ProgramCommand(
        GitInstallation.developerToolsInstallCommand[0],
        Array(GitInstallation.developerToolsInstallCommand.dropFirst())
    )

    private func chooseAnother() {
        if let path = ProgramPanel.choose("git", startingAt: gitProvider.git?.installation.executable) {
            gitProvider.choose(path)
        }
    }
}

// MARK: Agents

/// Whether to use the agents Roga found, which the buttons answer. Each
/// agent's row has a menu of its copies, where one agent can be left out.
struct SetupAgents: View {
    let setup: SetupModel
    let found: [AgentKind]
    @Environment(AgentProvider.self) private var agents

    var body: some View {
        let on = found.filter { setup.isOn[$0] != false }
        VStack(spacing: SetupLayout.gap) {
            SetupHead(eyebrow: "Agents", title: heading(on: on), sub: sub)
            SetupCard {
                ForEach(AgentKind.allCases) { kind in
                    ProgramRow(
                        icon: .squareTerminal,
                        content: .agent(kind, lookup: agents.lookups[kind], isOn: setup.isOn[kind] != false),
                        menu: .agent(
                            kind,
                            agents: agents,
                            isOn: setup.isOn[kind] != false,
                            choose: { setup.chooseProgram(kind, $0) },
                            skip: { setup.setOn(kind, false) }
                        ),
                        choose: { choose(kind) }
                    )
                }
            }
            if agents.isLooking {
                SetupActions(back: back) {
                    Button("Looking…") {}
                        .buttonStyle(.setup(.primary))
                        .disabled(true)
                }
            } else if found.isEmpty {
                SetupActions(back: back) {
                    Button("Rescan") { agents.lookAgain() }
                        .buttonStyle(.setup(.secondary))
                    Button("Continue") { setup.continueWithoutAgents() }
                        .buttonStyle(.setup(.primary))
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                let hint = SetupWords.copiesHint(found.map { (kind: $0, copies: agents.surveys[$0]?.copies.count ?? 1) })
                SetupNote(lines: [hint, "You can change this later in Settings › Agents."].compactMap(\.self))
                SetupActions(back: back) {
                    Button("Don't Use Agents") { setup.dontUseAgents() }
                        .buttonStyle(.setup(.secondary))
                    Button("Use Agents") { setup.useAgents(found: found) }
                        .buttonStyle(.setup(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(on.isEmpty)
                }
            }
        }
    }

    private func back() {
        setup.back(found: found)
    }

    /// Whether Roga found copies of an agent and can't use any of them,
    /// which isn't the same as finding none.
    private var foundOnlyUnusable: Bool {
        found.isEmpty && AgentKind.allCases.contains { agents.surveys[$0]?.copies.isEmpty == false }
    }

    private func heading(on: [AgentKind]) -> String {
        if agents.isLooking { return "Detecting coding agents" }
        if foundOnlyUnusable { return "No compatible coding agents" }
        return SetupWords.agentsHeading(found: found, on: on)
    }

    private var sub: String {
        if agents.isLooking || !found.isEmpty { return SetupWords.agentsSub }
        if foundOnlyUnusable {
            return "Detected installations are outdated or could not report a version. Update an agent or select another executable, then Rescan. Agents are optional."
        }
        return SetupWords.noAgentsSub
    }

    private func choose(_ kind: AgentKind) {
        if let path = ProgramPanel.choose(kind.executableName, startingAt: nil) {
            setup.chooseProgram(kind, path)
        }
    }
}

// MARK: Hooks

/// Why hooks, what Install Hooks does, and how: a picture of the sidebar's
/// marks, a sentence, and a card with each agent's status that ends in the
/// exact commands (decision 29). After Install, the commands give way to
/// what happened in each agent.
struct SetupHooks: View {
    let setup: SetupModel
    let found: [AgentKind]
    @Environment(AgentProvider.self) private var agents
    /// The agents Install Hooks is running in, so that their commands stay
    /// while it does.
    @State private var installing: [AgentKind] = []
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        let usable = setup.usable(found: found)
        let phase = SetupWords.hooksPhase(
            usable: usable,
            status: agents.hookStatus,
            work: agents.hookWork,
            canInstall: agents.helperPath != nil
        )
        let commandKinds = commandKinds(phase, usable: usable)
        VStack(spacing: SetupLayout.gap) {
            SetupHead(eyebrow: "Hooks", title: SetupWords.hooksHeading, sub: SetupWords.hooksSub)
            MarksFigure()
            if !commandKinds.isEmpty {
                SetupSay(
                    button: "Install Hooks",
                    words: "installs the roga-hooks plugin in \(SetupWords.and(commandKinds.map(\.name))) using the commands below. Hooks report session activity without changing agent behavior."
                )
            } else if usable.contains(where: { agents.hookStatus[$0] == .installed || agents.hookStatus[$0] == .needsTrust }) {
                SetupSay(words: SetupWords.hooksInstalled)
            }
            SetupCard(clips: true) {
                ForEach(AgentKind.allCases) { kind in
                    if usable.contains(kind) {
                        HookStatusRow(
                            kind: kind,
                            row: SetupWords.hookRow(kind, status: agents.hookStatus[kind], work: agents.hookWork[kind])
                        ) {
                            agents.refreshHookStatus()
                        }
                    } else {
                        HookStatusRow(
                            kind: kind,
                            row: SetupWords.HookRow(status: found.contains(kind) ? "Disabled" : "Not found"),
                            isDimmed: true
                        ) {}
                    }
                }
                if !commandKinds.isEmpty {
                    CommandBlock(lines: commands(for: commandKinds), isCompact: true, fontSize: SetupLayout.commandFontSize)
                }
            }
            if agents.helperPath == nil {
                Text(SetupWords.noHelper)
                    .font(.system(size: 12.5))
                    .foregroundStyle(AgentColors.warn)
            }
            if let error = agents.pluginFilesError {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsColors.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            SetupActions(back: { setup.back(found: found) }, backIsDisabled: phase == .installing) {
                switch phase {
                case .pending(let kinds):
                    Button("Not Now") { setup.next(found: found) }
                        .buttonStyle(.setup(.secondary))
                    Button("Install Hooks") { install(kinds) }
                        .buttonStyle(.setup(.primary))
                        .keyboardShortcut(.defaultAction)
                case .installing:
                    Button("Installing…") {}
                        .buttonStyle(.setup(.primary))
                        .disabled(true)
                case .checking:
                    Button("Checking…") {}
                        .buttonStyle(.setup(.primary))
                        .disabled(true)
                case .done:
                    Button("Continue") { setup.next(found: found) }
                        .buttonStyle(.setup(.primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        // What the screen says and how tall its card is change as the hooks
        // go in, and the buttons with them.
        .animation(SetupMotion.change(reducesMotion), value: phase)
        .animation(SetupMotion.change(reducesMotion), value: agents.hookStatus)
        // Trusting Roga's hooks or turning them on happens in the agent, so
        // Roga asks again when someone comes back from there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let waits = usable.contains { kind in
                agents.hookStatus[kind].map { SetupWords.hookRow(kind, status: $0, work: nil).checksAgain } ?? false
            }
            if waits, phase != .installing { agents.refreshHookStatus() }
        }
    }

    /// The agents whose commands show: the ones Install Hooks would run in,
    /// or is running in. While Roga is still asking, they're the agents in
    /// use, so that the card doesn't grow once the answers are in.
    private func commandKinds(_ phase: SetupWords.HooksPhase, usable: [AgentKind]) -> [AgentKind] {
        switch phase {
        case .pending(let kinds): return kinds
        case .installing: return installing
        case .checking:
            guard installing.isEmpty, agents.helperPath != nil else { return [] }
            return usable.filter { kind in
                agents.hookStatus[kind].map { AgentProvider.offeredAction($0, for: kind) == .install } ?? true
            }
        case .done: return []
        }
    }

    private func commands(for kinds: [AgentKind]) -> [TerminalLine] {
        kinds.flatMap { kind in
            (agents.installCommands(kind) ?? []).map { TerminalLine.program($0, showsPath: agents.showsPath($0.executable)) }
        }
    }

    private func install(_ kinds: [AgentKind]) {
        installing = kinds
        Task {
            await agents.installHooks(kinds)
            installing = []
        }
    }
}

/// An agent on the Hooks screen: its name, what its hooks need or did under
/// it, and their status at the right.
private struct HookStatusRow: View {
    let kind: AgentKind
    let row: SetupWords.HookRow
    var isDimmed = false
    let checkAgain: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(kind.name)
                        .font(.system(size: 13.5, weight: isDimmed ? .medium : .semibold))
                        .foregroundStyle(isDimmed ? SetupColors.note : .primary)
                    if let aside = row.aside {
                        Text(aside)
                            .font(.system(size: 12))
                            .foregroundStyle(SetupColors.note)
                    }
                }
                .frame(minHeight: 19)
                ForEach(row.notes, id: \.self) { note in
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(SetupColors.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(row.problems, id: \.self) { problem in
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsColors.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 5) {
                    switch row.mark {
                    case .none: EmptyView()
                    case .spinner: SetupGlyph(kind: .spinner, size: 13)
                    case .ok: SetupGlyph(kind: .ok, size: 13)
                    case .warn: SetupGlyph(kind: .warn, size: 13)
                    }
                    Text(row.status)
                        .font(.system(size: 12.5, weight: row.mark == .ok || row.mark == .warn ? .medium : .regular))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                .frame(minHeight: 19)
                if row.checksAgain {
                    Button("Check Again", action: checkAgain)
                        .buttonStyle(SetupSmallButtonStyle())
                        .accessibilityLabel("Check \(kind.name)'s hooks again")
                }
            }
            .fixedSize()
        }
        .padding(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.name)
        .accessibilityValue(row.spoken)
    }

    private var statusColor: Color {
        switch row.mark {
        case .ok: AgentColors.ok
        case .warn: AgentColors.warn
        case .none, .spinner: SetupColors.note
        }
    }
}

/// Three rows of the sidebar, as it draws a worktree an agent is in, each
/// with a line out to what its mark means, so that it reads as a picture of
/// what hooks are for and not as a list.
private struct MarksFigure: View {
    private struct Row {
        var name: String
        var words: String
        var howLong: String
        var count: String
        var state: AgentSummary.State
        var title: String
        var meaning: String
    }

    private static let rows = [
        Row(name: "agent/fix-login", words: "Editing LoginView.swift", howLong: "2 min", count: "3", state: .working,
            title: "Working", meaning: "Agent active in this worktree."),
        Row(name: "agent/billing", words: "Approval required: git push", howLong: "1 min", count: "1", state: .waiting(.permission),
            title: "Waiting", meaning: "Approval or response required."),
        Row(name: "agent/search-index", words: "Finished", howLong: "4 min", count: "7", state: .finished,
            title: "Finished", meaning: "Session finished, changes not yet reviewed."),
    ]

    private static let rowHeight: CGFloat = 52

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                    sidebarRow(row, isSelected: index == 0)
                }
            }
            .padding(6)
            .frame(width: 276)
            .background(SettingsColors.sidebar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(SetupColors.rule, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 3, y: 2)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                    callout(row)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Worktree status indicators. Ring: working. Amber circle: waiting for approval or a response. Blue dot: finished, unread.")
    }

    /// A worktree's row with a second line, as the sidebar draws one
    /// (decisions 51 and 58): its name, how many files are uncommitted and
    /// the mark on the first line, and what the agent is doing and for how
    /// long on the second.
    private func sidebarRow(_ row: Row, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(verbatim: row.name)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(verbatim: row.count)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                AgentMark(state: row.state, size: 14)
                    .frame(width: 24)
            }
            .frame(height: 30)
            HStack(spacing: 0) {
                Text(row.words)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(row.howLong)
                    .monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(row.state == .waiting(.permission) ? AnyShapeStyle(AgentColors.warn) : AnyShapeStyle(SetupColors.note))
            .padding(.trailing, 5)
            .frame(height: 16)
        }
        .font(.system(size: 13))
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .frame(height: Self.rowHeight, alignment: .top)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(SettingsColors.selectedPage)
            }
        }
    }

    /// A line from a row's mark out to what the mark means.
    private func callout(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(SetupColors.note.opacity(0.45))
                .frame(width: 30, height: 1)
                .padding(.top, 15)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .fontWeight(.semibold)
                    .frame(height: 20)
                Text(row.meaning)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SetupColors.note)
                    .frame(height: 18)
            }
            .padding(.top, 5)
        }
        .frame(height: Self.rowHeight, alignment: .top)
    }
}

// MARK: Ready

/// What was chosen, with Change to go back to the step that set each line,
/// and one more thing that only setup asks about here: updates.
struct SetupReady: View {
    let setup: SetupModel
    let found: [AgentKind]
    @Environment(GitProvider.self) private var gitProvider
    @Environment(AgentProvider.self) private var agents
    @Environment(Updates.self) private var updates: Updates?
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    /// Whether the screen has appeared, after which the marks beside what
    /// was chosen come in one after another.
    @State private var isIn = false

    var body: some View {
        let usable = setup.usable(found: found)
        VStack(spacing: SetupLayout.gap) {
            SetupHead(eyebrow: "Ready", title: "Setup complete", sub: "Review your configuration. You can change these preferences in Settings.")
            section("Configuration") {
                SetupCard {
                    ChosenRow(
                        name: "Git",
                        chosen: SetupWords.chosenGit(gitProvider.git?.installation, developerToolsFolder: gitProvider.survey?.developerToolsFolder),
                        isIn: isIn,
                        order: 0
                    ) {
                        setup.go(to: .git)
                    }
                    ChosenRow(
                        name: "Agents",
                        chosen: SetupWords.chosenAgents(
                            found: found.compactMap { kind in
                                agents.installation(kind).map { (kind: kind, version: $0.version.description) }
                            },
                            usable: usable,
                            declined: setup.usesAgents == false
                        ),
                        isIn: isIn,
                        order: 1
                    ) {
                        setup.go(to: .agents)
                    }
                    if !usable.isEmpty {
                        ChosenRow(name: "Hooks", chosen: SetupWords.chosenHooks(usable: usable, status: agents.hookStatus), isIn: isIn, order: 2) {
                            setup.go(to: .hooks)
                        }
                    }
                }
            }
            section("Updates") {
                SetupCard {
                    updateRow(
                        "Check for updates automatically",
                        help: SettingsItem.checksForUpdates.help,
                        isOn: Binding {
                            updates?.checksAutomatically ?? false
                        } set: {
                            updates?.setChecksAutomatically($0)
                        },
                        isEnabled: updates?.canUpdate == true
                    )
                    updateRow(
                        "Download updates automatically",
                        help: nil,
                        isOn: Binding {
                            updates?.downloadsAutomatically ?? false
                        } set: {
                            updates?.setDownloadsAutomatically($0)
                        },
                        // Sparkle downloads only what its daily check finds.
                        isEnabled: updates?.canUpdate == true && updates?.checksAutomatically == true
                    )
                }
                if updates?.canUpdate != true {
                    Text(GeneralSection.cantUpdateNotice)
                        .font(.system(size: 12))
                        .foregroundStyle(SetupColors.note)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                }
            }
            SetupActions(back: { setup.back(found: found) }) {
                // In the house's orange, since it's where setup was going.
                Button("Open Roga") {
                    withAnimation(.easeOut(duration: reducesMotion ? 0.2 : 0.35)) { setup.finish() }
                }
                .buttonStyle(.setup(.brand))
                .keyboardShortcut(.defaultAction)
                .disabled(gitProvider.git == nil)
            }
        }
        .onAppear { isIn = true }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(SetupColors.note)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func updateRow(_ title: String, help: String?, isOn: Binding<Bool>, isEnabled: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                if let help {
                    Text(help)
                        .font(.system(size: 12))
                        .foregroundStyle(SetupColors.note)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn)
                .toggleStyle(.settings)
                .accessibilityHint(help ?? "")
        }
        .padding(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 14))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A line of What you chose: a mark, what the line is about, what was
/// chosen, and Change. The mark pops in a little after the screen appears,
/// each line's after the one over it.
private struct ChosenRow: View {
    let name: String
    let chosen: SetupWords.Chosen
    let isIn: Bool
    let order: Int
    let change: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SetupGlyph(kind: glyph, size: 16)
                .frame(height: 19)
                .scaleEffect(isIn || reducesMotion ? 1 : 0.3)
                .opacity(isIn || reducesMotion ? 1 : 0)
                .animation(SetupMotion.pop(reducesMotion)?.delay(0.3 + Double(order) * 0.1), value: isIn)
            Text(name)
                .fontWeight(.semibold)
                .frame(width: 58, height: 19, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(chosen.value)
                    .frame(minHeight: 19)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = chosen.detail {
                    if chosen.detailIsPath {
                        Text(verbatim: detail)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(SetupColors.note)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(SetupColors.note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Change", action: change)
                .buttonStyle(SetupSmallButtonStyle())
                .accessibilityLabel("Change \(name)")
        }
        .padding(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityValue(chosen.spoken)
    }

    private var glyph: SetupGlyph.Kind {
        switch chosen.mark {
        case .ok: .ok
        case .warn: .warn
        case .off: .off
        }
    }
}
