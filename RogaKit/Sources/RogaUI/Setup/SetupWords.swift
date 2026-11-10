import AgentEngine
import Foundation
import GitRunner

/// What setup's screens say, from what Roga found and what was answered,
/// kept apart from the views so that tests can check every case.
enum SetupWords {
    /// Names joined the way a sentence lists them: "A", "A and B", "A, B and
    /// C". Joined by hand rather than with a list format, which would follow
    /// the Mac's language while the rest of Roga is in English.
    static func and(_ names: [String]) -> String {
        names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "") : names.first ?? ""
    }

    // MARK: Looking

    /// One thing Roga looks at, on the Looking screen.
    struct Look: Equatable, Identifiable {
        enum State: Equatable {
            /// Not started, because it waits for something before it.
            case waiting
            case looking
            case found
            /// Looked, and there's nothing Roga can use, in amber.
            case missing
        }

        var name: String
        var state: State
        var detail: String

        var id: String { name }
    }

    /// What the login shell's `PATH` row says.
    static func pathLook(_ searchPath: (path: String, fromLoginShell: Bool)?, shell: String) -> Look {
        guard let searchPath else { return Look(name: "Shell PATH", state: .looking, detail: "Reading from \(shellName(shell))…") }
        let detail = searchPath.fromLoginShell
            ? "Read from your login shell, \(shellName(shell))"
            : "Login shell PATH unavailable; using Roga's environment"
        return Look(name: "Shell PATH", state: .found, detail: detail)
    }

    /// A shell's name, from its path, as in zsh.
    static func shellName(_ shell: String) -> String {
        (shell as NSString).lastPathComponent
    }

    /// What git's row says.
    static func gitLook(state: GitProvider.State, survey: GitSurvey?, isLooking: Bool, hasPath: Bool) -> Look {
        guard hasPath else { return Look(name: "Git", state: .waiting, detail: "") }
        guard !isLooking, let survey else { return Look(name: "Git", state: .looking, detail: "Looking…") }
        let found = count(survey.copies.count, "found")
        switch state {
        case .ready(let git):
            let source = ProgramSource.of(git.installation.executable, developerToolsFolder: survey.developerToolsFolder)
            return Look(name: "Git", state: .found, detail: "\(found) · \(git.installation.version) \(source.phrase)")
        case .failed, .locating:
            let detail = survey.copies.isEmpty ? "None found" : "\(found), none compatible"
            return Look(name: "Git", state: .missing, detail: detail)
        }
    }

    /// What an agent's row says. An agent Roga didn't find isn't a problem,
    /// so it reads as found out rather than as missing.
    static func agentLook(_ kind: AgentKind, lookup: AgentLookup?, survey: AgentSurvey?, hasGit: Bool, gitFailed: Bool) -> Look {
        guard hasGit else {
            return Look(name: kind.name, state: .waiting, detail: gitFailed ? "After Git" : "")
        }
        guard let lookup else { return Look(name: kind.name, state: .looking, detail: "Looking…") }
        let found = count(survey?.copies.count ?? 1, "found")
        switch lookup {
        case .found(let installation):
            return Look(name: kind.name, state: .found, detail: "\(found) · \(installation.version)")
        case .notFound:
            return Look(name: kind.name, state: .found, detail: "Not found")
        case .unusable, .configuredUnusable, .configuredMissing:
            return Look(name: kind.name, state: .missing, detail: "\(found), none compatible")
        }
    }

    private static func count(_ number: Int, _ word: String) -> String {
        "\(number) \(word)"
    }

    // MARK: Git

    /// The heading names the version and leaves where the Git is from to its
    /// row, so that it's one line whichever Git it is.
    static func gitHeading(_ installation: GitInstallation) -> String {
        "Roga will use Git \(installation.version)"
    }

    static let gitSub = "Roga runs the Git on your Mac, with your own configuration, and needs \(minimumGit) or newer."

    /// The oldest git Roga runs, as people say it: 2.44.
    static var minimumGit: String {
        "\(GitVersion.minimumSupported.major).\(GitVersion.minimumSupported.minor)"
    }

    /// Under git's row: how many gits there are and which one Roga
    /// recommends, and what the terminal runs when Roga can't use it.
    static func gitNote(_ survey: GitSurvey, home: String = NSHomeDirectory()) -> [String] {
        guard let recommended = survey.recommended else { return [] }
        var lines: [String] = []
        if survey.copies.count == 1 {
            lines.append("It's the only Git Roga found.")
        } else {
            let which = ProgramSource.isInPath(recommended.executable, searchPath: survey.searchPath)
                ? "the first one in your PATH that's new enough"
                : "the first one it can use, which isn't in your PATH"
            lines.append("Roga found \(survey.copies.count) Gits, and recommends \(which).")
        }
        if let first = survey.copies.first(where: { $0.executable == survey.firstInPath }), !first.isUsable {
            let source = ProgramSource.of(first.executable, developerToolsFolder: survey.developerToolsFolder, home: home)
            if let version = first.version {
                lines.append("Your terminal runs the one \(source.phrase), which is \(version.major).\(version.minor) and too old.")
            } else {
                lines.append("Your terminal runs the one \(source.phrase), which didn't say its version.")
            }
        }
        return lines
    }

    /// What the screen says when Roga can't use any git it found.
    struct NoGit: Equatable {
        var heading: String
        var sub: String
        /// What the dark button does, before the command it runs, or nil
        /// when there's nothing to install.
        var say: String?
        var note: String
        /// Whether the dark button installs the Command Line Tools. When it
        /// doesn't, Look Again is the dark one.
        var offersTools: Bool
    }

    static func noGit(found: Int, developerToolsMissing: Bool) -> NoGit {
        let foundWords = switch found {
        case 0: "it didn't find one"
        case 1: "the only one it found is older than that"
        default: "the ones it found are older than that"
        }
        if developerToolsMissing {
            return NoGit(
                heading: "Roga needs Git \(minimumGit) or newer",
                sub: "Roga runs the Git on your Mac, and \(foundWords). Apple's comes with the Command Line Tools, which take a few minutes to install.",
                say: "opens Apple's installer using this command:",
                note: "Homebrew Git is also supported. Install Git or select an existing installation, then Rescan.",
                offersTools: true
            )
        }
        return NoGit(
            heading: "Roga needs Git \(minimumGit) or newer",
            sub: "Roga runs the Git on your Mac, and \(foundWords).",
            say: nil,
            note: "Install a compatible Git version with Homebrew or select an existing installation, then Rescan.",
            offersTools: false
        )
    }

    // MARK: Agents

    static let agentsSub = "Generate commit messages, resolve conflicts and troubleshoot Git errors with a coding agent. Agents run only when requested."
    static let noAgentsHeading = "No coding agents found"
    static let noAgentsSub = "No Claude Code or Codex installations were detected in PATH or standard installation locations. Agents are optional and can be configured later in Settings › Agents."

    /// The question, which names the agents Roga would use: the ones it
    /// found and that their rows leave on, or all it found when none is on.
    static func agentsHeading(found: [AgentKind], on: [AgentKind]) -> String {
        let asked = on.isEmpty ? found : on
        guard !asked.isEmpty else { return noAgentsHeading }
        return "Use \(and(asked.map(\.name))) in Roga?"
    }

    /// Under the agents' rows: how many copies of each Roga found, when any
    /// has more than one, since that's what the menus are for.
    static func copiesHint(_ counts: [(kind: AgentKind, copies: Int)]) -> String? {
        guard counts.contains(where: { $0.copies > 1 }) else { return nil }
        let words = counts.enumerated().map { index, count in
            index == 0
                ? "\(count.copies) \(count.copies == 1 ? "copy" : "copies") of \(count.kind.name)"
                : "\(count.copies) of \(count.kind.name)"
        }
        return "Roga found \(and(words)). \(counts.count > 1 ? "Each menu lists them all" : "The menu lists them all")."
    }

    // MARK: Hooks

    static let hooksHeading = "Agent status"
    static let hooksSub = "Install hooks to show working, waiting and finished states beside each worktree in the sidebar."
    static let hooksInstalled = "The roga-hooks plugin is installed. Manage hooks in Settings › Agents."
    static let noHelper = "Hook installation unavailable: roga helper missing."

    /// What an agent's row on the Hooks screen says.
    struct HookRow: Equatable {
        enum Mark: Equatable {
            case none
            case spinner
            case ok
            case warn
        }

        var status: String
        var mark = Mark.none
        /// Gray words beside the agent's name.
        var aside: String?
        /// Gray lines under the name.
        var notes: [String] = []
        /// What failed, in the agent's own words, in red.
        var problems: [String] = []
        /// Whether the row offers Check Again, for something only the
        /// person can put right, in the agent.
        var checksAgain = false

        /// All of it in words, for VoiceOver.
        var spoken: String {
            ([status + "."] + [aside].compactMap(\.self) + notes + problems).joined(separator: " ")
        }
    }

    static func hookRow(_ kind: AgentKind, status: HookStatus?, work: AgentProvider.HookWork?) -> HookRow {
        var row: HookRow
        switch status {
        case nil:
            row = HookRow(status: "Checking…", mark: .spinner)
        case .notInstalled?:
            row = HookRow(status: "Not installed")
            if kind == .codex { row.aside = "asks you to trust the hooks before it runs them" }
        case .installed?:
            let works = switch kind {
            case .claude: "Active in new sessions."
            case .codex: "Codex trusts Roga's hooks."
            }
            row = HookRow(status: "Installed", mark: .ok, notes: [works])
        case .needsTrust?:
            row = HookRow(
                status: "Approval required",
                mark: .warn,
                notes: ["Codex won't run a new hook until you trust it. Run /hooks in Codex, or use Review hooks in the Codex app."],
                checksAgain: true
            )
        case .disabled?:
            row = HookRow(
                status: "Disabled in \(kind.name)",
                mark: .warn,
                notes: ["Enable the installed plugin in \(kind.name), then check again."],
                checksAgain: true
            )
        case .anotherCopy(let folder)?:
            let fix = switch kind {
            case .claude: "Install Hooks to use this copy instead."
            case .codex: "Remove hooks from that copy of Roga first; Codex supports one installation."
            }
            row = HookRow(
                status: "Installed by another copy of Roga",
                mark: .warn,
                notes: ["\(kind.name) runs the hooks of another copy of Roga, from \(AgentSummaries.abbreviated(folder)). \(fix)"],
                checksAgain: kind == .codex
            )
        case .unknown(let words)?:
            row = HookRow(status: "Status unavailable", mark: .warn, notes: [AgentSummaries.sentence(words)], checksAgain: true)
        }
        switch work {
        case .installing?:
            row = HookRow(status: "Installing…", mark: .spinner)
        case .removing?:
            row = HookRow(status: "Removing…", mark: .spinner)
        case .failed(_, let words)?:
            row.problems = [words]
        case nil:
            break
        }
        return row
    }

    /// Where the Hooks screen is, which decides what it says and its buttons.
    enum HooksPhase: Equatable {
        /// Roga is still asking the agents whether they have its hooks.
        case checking
        /// There's something to install, in these agents.
        case pending([AgentKind])
        case installing
        /// Nothing left to install, or nothing Roga can install.
        case done
    }

    /// - Parameters:
    ///   - usable: The agents in use, in order.
    ///   - canInstall: Whether this copy of Roga has the helper its hooks run.
    static func hooksPhase(
        usable: [AgentKind],
        status: [AgentKind: HookStatus],
        work: [AgentKind: AgentProvider.HookWork],
        canInstall: Bool
    ) -> HooksPhase {
        if usable.contains(where: { work[$0] == .installing }) { return .installing }
        if usable.contains(where: { status[$0] == nil }) { return .checking }
        let toInstall = usable.filter { kind in
            status[kind].map { AgentProvider.offeredAction($0, for: kind) == .install } ?? false
        }
        return toInstall.isEmpty || !canInstall ? .done : .pending(toInstall)
    }

    // MARK: Ready

    /// A line of What you chose on the Ready screen.
    struct Chosen: Equatable {
        enum Mark: Equatable {
            case ok
            case warn
            /// Not used, or not installed, which is fine too.
            case off
        }

        var mark: Mark
        var value: String
        /// A gray line under the value, or a path.
        var detail: String?
        var detailIsPath = false

        /// All of it in words, for VoiceOver.
        var spoken: String {
            [value, detail].compactMap(\.self).joined(separator: ". ")
        }
    }

    static func chosenGit(_ installation: GitInstallation?, developerToolsFolder: String?, home: String = NSHomeDirectory()) -> Chosen {
        guard let installation else {
            return Chosen(mark: .warn, value: "No compatible installation", detail: "Requires Git \(minimumGit) or later.")
        }
        let source = ProgramSource.of(installation.executable, developerToolsFolder: developerToolsFolder, home: home)
        return Chosen(
            mark: .ok,
            value: "Git \(installation.version) \(source.phrase)",
            detail: ProgramSource.abbreviated(installation.executable, home: home),
            detailIsPath: true
        )
    }

    /// - Parameters:
    ///   - found: The agents Roga found, each with the version it would run.
    ///   - usable: The ones in use.
    ///   - declined: Whether Don't Use Agents was the answer.
    static func chosenAgents(found: [(kind: AgentKind, version: String)], usable: [AgentKind], declined: Bool) -> Chosen {
        guard !found.isEmpty else {
            return Chosen(mark: .off, value: "None found", detail: "Roga looked for Claude Code and Codex.")
        }
        guard !usable.isEmpty else {
            return Chosen(mark: .off, value: "Not used", detail: "Roga hides its agent commands and the Generate button.")
        }
        let names = found.filter { usable.contains($0.kind) }.map { "\($0.kind.name) \($0.version)" }
        let leftOut = found.filter { !usable.contains($0.kind) }.map(\.kind.name)
        return Chosen(
            mark: .ok,
            value: and(names),
            detail: leftOut.isEmpty || declined ? nil : "\(and(leftOut)) \(leftOut.count == 1 ? "isn't" : "aren't") used."
        )
    }

    /// What the hooks came to in the agents in use: where they're installed,
    /// where they wait to be trusted, and where they aren't.
    static func chosenHooks(usable: [AgentKind], status: [AgentKind: HookStatus]) -> Chosen {
        var installed: [String] = []
        var waiting: [String] = []
        var missing: [String] = []
        for kind in usable {
            switch status[kind] {
            case .installed?: installed.append(kind.name)
            case .needsTrust?: waiting.append(kind.name)
            default: missing.append(kind.name)
            }
        }
        guard !installed.isEmpty || !waiting.isEmpty else {
            return Chosen(mark: .off, value: "Not installed", detail: "Agent status updates are disabled.")
        }
        var details: [String] = []
        if !waiting.isEmpty {
            details.append(installed.isEmpty && waiting.count == 1
                ? "Hook approval required."
                : "Hook approval required in \(and(waiting)).")
        }
        if !missing.isEmpty { details.append("Not installed in \(and(missing)).") }
        return Chosen(
            mark: waiting.isEmpty ? .ok : .warn,
            value: "Installed in \(and(installed + waiting))",
            detail: details.isEmpty ? nil : details.joined(separator: " ")
        )
    }
}
