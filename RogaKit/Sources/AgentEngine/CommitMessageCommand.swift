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
        let model = nonEmpty(agent.model)
        let effort = nonEmpty(agent.effort)
        let instructions = CommitMessagePrompt.instructions(style: style)
        let task = CommitMessagePrompt.task(hasDraft: hasDraft)

        var arguments: [String]
        switch agent.kind {
        case .claude:
            // `--safe-mode` turns off CLAUDE.md, skills, plugins, hooks and MCP
            // servers while signing in still works, which `--bare` doesn't. The
            // empty `--tools=` turns off every tool, and the system prompt
            // replaces Claude Code's own, which is about writing code. The task
            // goes after `--`, so nothing in it can be read as an option.
            arguments = ["-p", "--safe-mode"]
            if let model { arguments += ["--model", model] }
            if let effort { arguments += ["--effort", effort] }
            arguments += [
                "--tools=", "--no-session-persistence", "--output-format", "json",
                "--system-prompt", instructions,
            ]
            arguments += agent.extraArguments
            arguments += ["--", task]
        case .codex:
            // Codex has no system prompt to set from the command line, so the
            // instructions and the task are its prompt, and it adds standard
            // input after them in a block of its own. Without its shell tool,
            // it answers in one turn instead of running commands first.
            arguments = [
                "exec", "--ephemeral", "--sandbox", "read-only", "--color", "never", "--skip-git-repo-check",
                "--disable", "hooks", "--disable", "plugins", "--disable", "apps", "--disable", "shell_tool",
                "-c", "notify=[]", "-c", "web_search=disabled",
            ]
            if let model { arguments += ["-m", model] }
            if let effort { arguments += ["-c", "model_reasoning_effort=" + effort] }
            arguments += agent.extraArguments
            arguments.append(instructions + "\n\n" + task)
        }

        var command = ProgramCommand(agent.executable, arguments, in: worktree)
        command.environment = [generatingVariable: "1"]
        command.timeout = agent.timeLimit
        command.priority = .normal
        return command
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = CommitMessageText.trimmed(value)
        return trimmed.isEmpty ? nil : trimmed
    }
}
