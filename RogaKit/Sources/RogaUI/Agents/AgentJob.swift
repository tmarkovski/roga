import AgentEngine

/// What Roga asks an agent to do: write the commit message (decision 41),
/// resolve a file's conflicts (decision 60), or suggest a fix for what git
/// refused (decision 63). All three run the default agent with the same flags,
/// each with its own prompt and its own data on standard input, so the agent
/// popover shows the command of the job it was opened for (decision 91).
enum AgentJob: Hashable, Sendable {
    /// Writing the commit message, which rewrites the box's words when it has
    /// some.
    case generate(hasDraft: Bool)
    case resolve
    case fix

    /// The line under the agent popover's rows: that what's picked is stored,
    /// and that the other two jobs run the same agent (decision 89).
    var sharedNote: String {
        switch self {
        case .generate: "Selection saved automatically. Resolve and Fix use the same agent."
        case .resolve: "Selection saved automatically. Generate and Fix use the same agent."
        case .fix: "Selection saved automatically. Generate and Resolve use the same agent."
        }
    }

    /// The first line of the job's command block, which says what goes on
    /// standard input. A custom agent reads its instructions there too.
    func input(isCustom: Bool) -> String {
        let data = switch self {
        case .generate: "staged diff"
        case .resolve: "conflicts"
        case .fix: "Git output and diagnostics"
        }
        if isCustom { return "Instructions and \(data) supplied via standard input" }
        return data.prefix(1).uppercased() + data.dropFirst() + " supplied via standard input"
    }
}

/// What the chevron of an agent's split button opens the popover for: the job,
/// and the worktree whose folder its command runs in.
struct AgentChoice: Hashable, Sendable {
    var job: AgentJob
    var worktree: String
}

extension GenerationSetup {
    /// The command `job` runs with this agent, as a command block shows it:
    /// what goes on standard input, and then the command.
    func terminal(for job: AgentJob, worktree: String) -> [TerminalLine] {
        let command = switch job {
        case .generate(let hasDraft): command(worktree: worktree, hasDraft: hasDraft)
        case .resolve: ConflictResolutionWriter.command(for: agent, worktree: worktree)
        case .fix: GitFixWriter.command(for: agent, worktree: worktree)
        }
        return [.comment(job.input(isCustom: agent.kind == nil)), .program(command, showsPath: showsPath)]
    }
}
