import GitRunner
import Testing
@testable import AgentEngine

/// The exact commands that ask Claude Code and Codex for a commit message,
/// which were checked against the real tools (decision 41).
@Suite(.timeLimit(.minutes(1)))
struct CommitMessageCommandTests {
    let instructions = CommitMessagePrompt.rules + "\n\nBe brief."
    let task = "Write the commit message for the staged changes in the diff block."
    let draftTask = "Write the commit message for the staged changes in the diff block, starting from the author's draft in the draft block."

    @Test func asksClaudeCodeWithItsOwnDefaults() {
        let agent = CommitMessageAgent(kind: .claude, executable: "/Users/ana/.local/bin/claude")
        let command = CommitMessageCommand.command(for: agent, worktree: "/repository", style: "Be brief.", hasDraft: false)
        #expect(command.executable == "/Users/ana/.local/bin/claude")
        #expect(command.arguments == [
            "-p", "--safe-mode", "--setting-sources", "user", "--tools=", "--no-session-persistence", "--output-format", "json",
            "--system-prompt", instructions, "--", task,
        ])
        #expect(command.directory == "/repository")
        #expect(command.environment == ["ROGA_GENERATING": "1"])
        #expect(command.timeout == .seconds(60))
        #expect(command.priority == .normal)
    }

    @Test func asksClaudeCodeWithAModelAnEffortAndADraft() {
        let agent = CommitMessageAgent(
            kind: .claude,
            executable: "/opt/homebrew/bin/claude",
            model: "haiku",
            effort: "low",
            timeLimit: .seconds(90)
        )
        let command = CommitMessageCommand.command(for: agent, worktree: "/repository", style: "Be brief.", hasDraft: true)
        #expect(command.arguments == [
            "-p", "--safe-mode", "--setting-sources", "user", "--model", "haiku", "--effort", "low", "--tools=", "--no-session-persistence",
            "--output-format", "json", "--system-prompt", instructions, "--", draftTask,
        ])
        #expect(command.timeout == .seconds(90))
        #expect(command.description.hasPrefix("/opt/homebrew/bin/claude -p --safe-mode --setting-sources user --model haiku --effort low --tools= "))
    }

    @Test func leavesTheWorktreesOwnClaudeSettingsOut() {
        // `claude -p` doesn't ask whether to trust the folder, so a cloned
        // repository's settings could run a helper or move the request.
        for agent in [
            CommitMessageAgent(kind: .claude, executable: "/bin/claude"),
            CommitMessageAgent(kind: .claude, executable: "/bin/claude", model: "haiku"),
        ] {
            let arguments = CommitMessageCommand.command(for: agent, worktree: "/r", style: "", hasDraft: false).arguments
            let sources = arguments.firstIndex(of: "--setting-sources")
            #expect(sources.map { arguments[$0 + 1] } == "user")
            // Before the task.
            #expect(sources.map { $0 < arguments.firstIndex(of: "--tools=")! } == true)
        }
    }

    @Test func turnsOffEachOfCodexsMCPServers() {
        let agent = CommitMessageAgent(kind: .codex, executable: "/opt/homebrew/bin/codex", mcpServers: ["node_repl", "docs"])
        let command = CommitMessageCommand.command(for: agent, worktree: "/repository", style: "Be brief.", hasDraft: false)
        #expect(command.arguments == [
            "exec", "--ephemeral", "--sandbox", "read-only", "--color", "never", "--skip-git-repo-check",
            "--disable", "hooks", "--disable", "plugins", "--disable", "apps", "--disable", "shell_tool",
            "-c", "notify=[]", "-c", "web_search=disabled",
            "-c", "mcp_servers.node_repl.enabled=false", "-c", "mcp_servers.docs.enabled=false",
            instructions + "\n\n" + task,
        ])
        // Claude Code turns its own off with --safe-mode.
        let claude = CommitMessageAgent(kind: .claude, executable: "/bin/claude", mcpServers: ["docs"])
        #expect(!CommitMessageCommand.command(for: claude, worktree: "/r", style: "", hasDraft: false).arguments.contains { $0.contains("mcp_servers") })
    }

    @Test func asksCodexWithItsOwnDefaults() {
        let agent = CommitMessageAgent(kind: .codex, executable: "/opt/homebrew/bin/codex")
        let command = CommitMessageCommand.command(for: agent, worktree: "/repository", style: "Be brief.", hasDraft: false)
        #expect(command.executable == "/opt/homebrew/bin/codex")
        #expect(command.arguments == [
            "exec", "--ephemeral", "--sandbox", "read-only", "--color", "never", "--skip-git-repo-check",
            "--disable", "hooks", "--disable", "plugins", "--disable", "apps", "--disable", "shell_tool",
            "-c", "notify=[]", "-c", "web_search=disabled", instructions + "\n\n" + task,
        ])
        #expect(command.directory == "/repository")
        #expect(command.environment == ["ROGA_GENERATING": "1"])
        #expect(command.timeout == .seconds(60))
        #expect(command.priority == .normal)
    }

    @Test func asksCodexWithAModelAnEffortAndADraft() {
        let agent = CommitMessageAgent(
            kind: .codex,
            executable: "/opt/homebrew/bin/codex",
            model: "gpt-6-astra",
            effort: "low"
        )
        let command = CommitMessageCommand.command(for: agent, worktree: "/repository", style: "Be brief.", hasDraft: true)
        #expect(command.arguments == [
            "exec", "--ephemeral", "--sandbox", "read-only", "--color", "never", "--skip-git-repo-check",
            "--disable", "hooks", "--disable", "plugins", "--disable", "apps", "--disable", "shell_tool",
            "-c", "notify=[]", "-c", "web_search=disabled", "-m", "gpt-6-astra", "-c", "model_reasoning_effort=low",
            instructions + "\n\n" + draftTask,
        ])
    }

    @Test func treatsABlankModelOrEffortAsTheAgentsDefault() {
        for kind in AgentKind.allCases {
            let blank = CommitMessageAgent(kind: kind, executable: "/bin/agent", model: " ", effort: "")
            let plain = CommitMessageAgent(kind: kind, executable: "/bin/agent")
            #expect(
                CommitMessageCommand.command(for: blank, worktree: "/r", style: "", hasDraft: false)
                    == CommitMessageCommand.command(for: plain, worktree: "/r", style: "", hasDraft: false)
            )
        }
    }

    @Test func leavesTheStyleOutWhenItsBlank() {
        let agent = CommitMessageAgent(kind: .claude, executable: "/bin/claude")
        let command = CommitMessageCommand.command(for: agent, worktree: "/r", style: "\n", hasDraft: false)
        #expect(command.arguments.contains(CommitMessagePrompt.rules))
    }

    @Test func runsACustomAgentsCommandInTheShellAsTyped() {
        // Roga doesn't know its flags, so it adds none, and the instructions
        // go on standard input ahead of the data (decision 89).
        let agent = CommitMessageAgent(name: "Ollama", command: "ollama run qwen2.5-coder:7b")
        let command = CommitMessageCommand.command(for: agent, worktree: "/repository", style: "Be brief.", hasDraft: false)
        #expect(command.executable == "/bin/sh")
        #expect(command.arguments == ["-c", "ollama run qwen2.5-coder:7b"])
        #expect(command.directory == "/repository")
        #expect(command.environment == ["ROGA_GENERATING": "1"])
        #expect(command.timeout == .seconds(60))
        let input = CommitMessageCommand.standardInput(for: agent, instructions: instructions, task: task, data: "<diff-1>\n</diff-1>\n")
        #expect(String(decoding: input, as: UTF8.self) == instructions + "\n\n" + task + "\n\n<diff-1>\n</diff-1>\n")
    }

    @Test func givesClaudeCodeAndCodexTheDataAloneOnStandardInput() {
        for kind in AgentKind.allCases {
            let agent = CommitMessageAgent(kind: kind, executable: "/bin/agent")
            #expect(CommitMessageCommand.standardInput(for: agent, instructions: instructions, task: task, data: "data") == Array("data".utf8))
        }
    }
}
