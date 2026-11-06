import AgentEngine
import GitRunner
import SwiftUI

/// Installing or removing Roga's hooks in an agent, as a Roga dialog
/// (decision 29): what the hooks do, what changes, and the exact commands
/// along the bottom edge, which are the agent's own plugin commands
/// (decision 41).
///
/// It stays open while the commands run, and if one fails, it says so in the
/// agent's own words where the card of what changes was, since a sheet keeps
/// the size it opened at.
struct HooksDialog: View {
    enum Action: Hashable {
        case install
        case remove
    }

    /// What someone asked for: which agent, and whether to install or
    /// remove. `offers` is the other agent, when Install also offers to
    /// install there, which is decided when the dialog opens so that it
    /// doesn't change while the dialog shows.
    struct Request: Identifiable, Hashable {
        var kind: AgentKind
        var action: Action
        var offers: AgentKind?

        var id: Self { self }
    }

    /// An agent whose commands failed, and how, in its own words.
    struct Failure: Hashable {
        var kind: AgentKind
        var words: String
    }

    let request: Request
    @Environment(AgentProvider.self) private var agents
    /// Where the Settings sheet keeps what it ran, so that its rows know
    /// which action a failure belongs to.
    @Environment(HookAttempts.self) private var attempts: HookAttempts?
    @Environment(\.dismiss) private var dismiss
    /// Whether to install in the agent `offers` names too.
    @State private var alsoOther = true
    @State private var isWorking = false
    /// What went wrong, in each agent's own words, after the commands ran.
    @State private var failures: [Failure] = []

    var body: some View {
        DialogSheet(content: content) {
            VStack(alignment: .leading, spacing: 12) {
                changes
                if let other = request.offers {
                    alsoRow(other)
                }
            }
        }
    }

    private var content: DialogContent {
        let runs = Self.kinds(for: request, alsoOther: alsoOther)
        let canRun = Self.canRun(request, agents: agents)
        return DialogContent(
            id: "hooks-\(request.kind.rawValue)",
            title: Self.title(request),
            message: DialogText(stringLiteral: Self.message(request)),
            terminal: Self.terminal(for: request, alsoOther: alsoOther, agents: agents),
            buttons: [
                DialogButton(title: "Cancel", kind: .secondary, isEnabled: !isWorking, action: close),
                DialogButton(
                    title: Self.buttonTitle(request.action, isWorking: isWorking),
                    kind: request.action == .install ? .primary : .destructive,
                    isEnabled: !isWorking && canRun
                ) {
                    run(runs)
                },
            ],
            dismiss: close
        )
    }

    /// The card of what changes, or how the commands failed in its place.
    private var changes: some View {
        SettingsCard {
            ForEach(Array(Self.facts(request, agents: agents).enumerated()), id: \.offset) { _, fact in
                // Wide enough for ~/.claude/settings.json on one line.
                SettingsCardRow(fact.name, nameWidth: 168, fact.what)
            }
        }
        .opacity(failures.isEmpty ? 1 : 0)
        .overlay {
            if !failures.isEmpty {
                HookFailures(action: request.action, failures: failures)
            }
        }
    }

    private func alsoRow(_ other: AgentKind) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Install in \(other.name) too")
                    .fontWeight(.medium)
                Text("\(other.name) was found, and its hooks work the same way.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsColors.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Install in \(other.name) too", isOn: $alsoOther)
                .toggleStyle(.settings)
                .disabled(isWorking)
        }
        .padding(EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
        .background(SettingsColors.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func close() {
        // The commands go on whatever the dialog does, so it stays until
        // they're done.
        guard !isWorking else { return }
        dismiss()
    }

    private func run(_ kinds: [AgentKind]) {
        isWorking = true
        failures = []
        attempts?.record(request.action, for: kinds)
        Task {
            let worked: Bool
            switch request.action {
            case .install: worked = await agents.installHooks(kinds)
            case .remove: worked = await agents.removeHooks(request.kind)
            }
            isWorking = false
            if worked {
                dismiss()
            } else {
                failures = Self.failed(kinds, agents: agents)
            }
        }
    }

    // MARK: What it says

    static func title(_ request: Request) -> String {
        switch request.action {
        case .install: "Install Roga's hooks in \(request.kind.name)"
        case .remove: "Remove Roga's hooks from \(request.kind.name)"
        }
    }

    static func message(_ request: Request) -> String {
        let name = request.kind.name
        switch request.action {
        case .install:
            let trust = request.kind == .codex ? " Codex asks you to trust them the first time they run." : ""
            return "\(name) will tell Roga when a session starts, works, asks you something and stops, and in which folder. The hooks only report, so they never change what \(name) does.\(trust)"
        case .remove:
            return "\(name) will stop telling Roga what its sessions are doing, so the sidebar won't mark the worktrees it works in. Nothing of Roga's stays behind in \(name)."
        }
    }

    /// What changes, for the card: the plugin, the agent's file it's
    /// recorded in, and how to undo it.
    static func facts(_ request: Request, agents: AgentProvider) -> [(name: String, what: String)] {
        let name = request.kind.name
        let file = switch request.kind {
        case .claude: "~/.claude/settings.json"
        case .codex: GenerateChoices.codexConfiguration(agents)
        }
        switch request.action {
        case .install:
            let removal = switch request.kind {
            case .claude: "claude plugin uninstall"
            case .codex: "codex plugin remove"
            }
            return [
                ("roga-hooks", "A plugin, kept with Roga's files in Application Support."),
                (file, "Gets the plugin's folder and turns it on, through \(name)'s own commands."),
                ("Remove", "Runs \(removal), and leaves nothing behind."),
            ]
        case .remove:
            return [
                ("roga-hooks", "Comes out of \(name), and stays with Roga's files in Application Support."),
                (file, "Loses the plugin and its folder, through \(name)'s own commands."),
                ("Install…", "Puts them back whenever you want the sidebar's marks again."),
            ]
        }
    }

    static func buttonTitle(_ action: Action, isWorking: Bool) -> String {
        switch action {
        case .install: isWorking ? "Installing…" : "Install"
        case .remove: isWorking ? "Removing…" : "Remove"
        }
    }

    /// The heading over what failed, which names the agents whose commands
    /// failed. With two agents, that may not be the one the dialog is for.
    static func failureHeading(_ action: Action, failed: [AgentKind]) -> String {
        let names = failed.map(\.name)
        // Joined by hand rather than with a list format, which would follow
        // the Mac's language while the rest of Roga is in English.
        let agents = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "") : names.first ?? ""
        switch action {
        case .install: return "\(agents) didn't install Roga's hooks"
        case .remove: return "\(agents) didn't remove Roga's hooks"
        }
    }

    /// The other agent, when Install should offer to install there too:
    /// Roga found it, and it says Roga's hooks aren't installed.
    static func otherAgent(for kind: AgentKind, action: Action, agents: AgentProvider) -> AgentKind? {
        guard action == .install, let other = AgentKind.allCases.first(where: { $0 != kind }),
              agents.installation(other) != nil, agents.hookStatus[other] == .notInstalled
        else { return nil }
        return other
    }

    /// The agents the commands run in, in the order they run.
    static func kinds(for request: Request, alsoOther: Bool) -> [AgentKind] {
        guard request.action == .install, alsoOther, let other = request.offers else { return [request.kind] }
        return [request.kind, other]
    }

    /// Whether the button can run anything: the agent is found, and for
    /// Install, this copy of Roga has the helper its hooks run.
    static func canRun(_ request: Request, agents: AgentProvider) -> Bool {
        guard agents.installation(request.kind) != nil else { return false }
        return request.action == .remove || agents.helperPath != nil
    }

    /// The exact commands the button runs (decision 29). With the other
    /// agent turned off, its commands still take up their room, hidden, so
    /// that the dialog stays the size it opened at.
    static func terminal(for request: Request, alsoOther: Bool, agents: AgentProvider) -> [TerminalLine] {
        func commands(_ kind: AgentKind) -> [ProgramCommand] {
            switch request.action {
            case .install: agents.installCommands(kind) ?? []
            case .remove: agents.removeCommands(kind) ?? []
            }
        }
        var lines = commands(request.kind).map { TerminalLine.program($0, showsPath: agents.showsPath($0.executable)) }
        if request.action == .install, let other = request.offers {
            for command in commands(other) {
                let showsPath = agents.showsPath(command.executable)
                lines.append(alsoOther ? .program(command, showsPath: showsPath) : .room(ShellCommand.tokens(command, showsPath: showsPath).map(\.text)))
            }
        }
        return lines
    }

    /// The agents whose commands failed, in the order they ran, and how.
    static func failed(_ kinds: [AgentKind], agents: AgentProvider) -> [Failure] {
        kinds.compactMap { kind in
            guard case .failed(let words)? = agents.hookWork[kind] else { return nil }
            return Failure(kind: kind, words: words)
        }
    }

    /// Each failure in its agent's own words, naming the agent when more
    /// than one failed, since the heading names it when only one did.
    static func failureLines(_ failures: [Failure]) -> [String] {
        failures.map { failures.count > 1 ? "\($0.kind.name): \($0.words)" : $0.words }
    }
}

/// How Install or Remove failed, in the dialog where the card of what
/// changes was: a heading that names the agents that failed, and their own
/// words, which scroll when they're long, since a sheet keeps the size it
/// opened at.
struct HookFailures: View {
    let action: HooksDialog.Action
    let failures: [HooksDialog.Failure]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
                Text(HooksDialog.failureHeading(action, failed: failures.map(\.kind)))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsColors.danger)
                ForEach(HooksDialog.failureLines(failures), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(SettingsColors.note)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(SettingsColors.danger, lineWidth: 1)
        }
    }
}

/// What Install or Remove last ran for each agent from one Settings sheet.
///
/// The provider keeps how an agent's last Install or Remove failed, but not
/// which of the two it was. The rows ask here, so that a failure goes once
/// the agent's status no longer offers the action that failed, as when
/// someone fixed it in Terminal, and when someone looks again. A sheet that
/// opens afresh has run nothing, so it doesn't show an older sheet's
/// failures; the dialog that ran the commands showed them.
@MainActor @Observable
final class HookAttempts {
    private(set) var actions: [AgentKind: HooksDialog.Action] = [:]

    /// Notes that `action` is about to run in each of `kinds`.
    func record(_ action: HooksDialog.Action, for kinds: [AgentKind]) {
        for kind in kinds { actions[kind] = action }
    }

    /// Forgets what ran, so that the rows stop showing how it failed.
    func forget() {
        actions = [:]
    }
}
