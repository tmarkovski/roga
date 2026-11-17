import GitRunner

/// The command that asks an agent for a commit message (decision 41). It's
/// also what Settings and the Generate popover show, so what people see is
/// what runs (decision 29).
///
/// Both commands turn off everything the agent could do besides answer: its
/// tools, the user's and the repository's hooks, plugins and MCP servers, and
/// saving the session. Without that, a click on Generate would run the
/// repository's hooks, and Roga's own hooks would show the run in the sidebar
/// as an agent at work. The `ROGA_GENERATING` variable is a second guard: a hook
/// inherits it, and Roga's hook helper drops its event when it sees it.
///
/// A worktree's own settings are left out too. `claude -p` never asks
/// whether to trust a folder, so a repository's `.claude/settings.json`
/// could otherwise run its `apiKeyHelper` or set variables that send the
/// request elsewhere, just because someone pressed Generate in a clone.
public enum CommitMessageCommand {
    /// The variable every run sets, which tells Roga's hook helper the run is
    /// Roga's own.
    public static let generatingVariable = "ROGA_GENERATING"

    /// The exact command for an agent.
    ///
    /// - Parameters:
    ///   - worktree: The worktree's folder, which the agent runs in.
    ///   - style: The editable instructions, which go after the fixed rules.
    ///   - hasDraft: Whether the input has a draft, which changes what the
    ///     agent is asked to do.
    public static func command(for agent: CommitMessageAgent, worktree: String, style: String, hasDraft: Bool) -> ProgramCommand {
        command(
            for: agent,
            worktree: worktree,
            instructions: CommitMessagePrompt.instructions(style: style),
            task: CommitMessagePrompt.task(hasDraft: hasDraft)
        )
    }

    /// The command for any request that an agent answers with text alone, such as
    /// resolving conflicts (decision 60), with the same flags that keep the run
    /// small.
    ///
    /// A custom agent's command runs in the shell as someone typed it, with
    /// nothing added, since Roga doesn't know its flags (decision 89). Its
    /// instructions and task go on standard input instead, ahead of the data,
    /// as `standardInput` puts them.
    public static func command(for agent: CommitMessageAgent, worktree: String, instructions: String, task: String) -> ProgramCommand {
        let model = nonEmpty(agent.model)
        let effort = nonEmpty(agent.effort)

        let executable: String
        var arguments: [String]
        switch agent.program {
        case .custom(_, let line):
            executable = shell
            arguments = ["-c", line]
        case .known(.claude, let path):
            executable = path
            // `--safe-mode` turns off CLAUDE.md, skills, plugins, hooks and MCP
            // servers while signing in still works, which `--bare` doesn't.
            // It still reads the worktree's own settings, with their helpers
            // and variables, so `--setting-sources user` keeps only the
            // person's. The empty `--tools=` turns off every tool, and the
            // system prompt replaces Claude Code's own, which is about writing
            // code. The task goes after `--`, so nothing in it can be read as
            // an option.
            arguments = ["-p", "--safe-mode", "--setting-sources", "user"]
            if let model { arguments += ["--model", model] }
            if let effort { arguments += ["--effort", effort] }
            arguments += [
                "--tools=", "--no-session-persistence", "--output-format", "json",
                "--system-prompt", instructions,
            ]
            arguments += ["--", task]
        case .known(.codex, let path):
            executable = path
            // Codex has no system prompt to set from the command line, so the
            // instructions and the task are its prompt, and it adds standard
            // input after them in a block of its own. Without its shell tool,
            // it answers in one turn instead of running commands first. Its
            // MCP servers run outside the sandbox, and nothing turns them all
            // off at once, so each is turned off by name.
            arguments = [
                "exec", "--ephemeral", "--sandbox", "read-only", "--color", "never", "--skip-git-repo-check",
                "--disable", "hooks", "--disable", "plugins", "--disable", "apps", "--disable", "shell_tool",
                "-c", "notify=[]", "-c", "web_search=disabled",
            ]
            for server in agent.mcpServers {
                arguments += ["-c", "mcp_servers.\(server).enabled=false"]
            }
            if let model { arguments += ["-m", model] }
            if let effort { arguments += ["-c", "model_reasoning_effort=" + effort] }
            arguments.append(instructions + "\n\n" + task)
        }

        var command = ProgramCommand(executable, arguments, in: worktree)
        command.environment = [generatingVariable: "1"]
        command.timeout = agent.timeLimit
        command.priority = .normal
        return command
    }

    /// The shell that runs a custom agent's command, which finds its program
    /// in the same `PATH` as git's.
    public static let shell = "/bin/sh"

    /// What goes on the agent's standard input: the data alone for Claude Code
    /// and Codex, which take the instructions and the task on the command
    /// line, and for a custom agent, the instructions and the task first.
    public static func standardInput(for agent: CommitMessageAgent, instructions: String, task: String, data: String) -> [UInt8] {
        guard agent.kind == nil else { return Array(data.utf8) }
        return Array((instructions + "\n\n" + task + "\n\n" + data).utf8)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = CommitMessageText.trimmed(value)
        return trimmed.isEmpty ? nil : trimmed
    }
}
