/// The agent that writes a commit message, resolves conflicts or fixes what
/// git refused, and how to run it (decisions 41 and 89): Claude Code or Codex,
/// with the flags Roga knows for each, or a command someone added in Settings.
public struct CommitMessageAgent: Sendable, Hashable {
    /// How Roga starts the agent.
    public enum Program: Sendable, Hashable {
        /// Claude Code or Codex, by the absolute path of its command-line
        /// tool.
        case known(AgentKind, executable: String)
        /// A command someone added, such as `ollama run qwen2.5-coder:7b`,
        /// which the shell runs. It reads Roga's instructions and the data
        /// on standard input, and prints its answer.
        case custom(name: String, command: String)
    }

    public var program: Program
    /// The model, such as `haiku`, or nil for the agent's own default. A
    /// custom agent has none.
    public var model: String?
    /// How hard the model thinks, such as `low`, `medium` or `high`, or nil
    /// for the agent's own default. A custom agent has none.
    public var effort: String?
    /// How long the agent may take before Roga stops it.
    public var timeLimit: Duration
    /// Codex's MCP servers, which the run turns off one by one, since Codex
    /// has no flag that turns them all off (see `CodexConfiguration`).
    public var mcpServers: [String]
    /// Codex's `config.toml`, which the run reads again for its MCP servers
    /// just before it starts, or nil to go by `mcpServers` alone. Codex
    /// refuses to start when told to turn off a server it no longer has, as
    /// after `codex mcp remove`, so the names have to be the file's as it is.
    public var codexConfigurationFile: String?

    /// Claude Code or Codex.
    public init(
        kind: AgentKind,
        executable: String,
        model: String? = nil,
        effort: String? = nil,
        timeLimit: Duration = .seconds(60),
        mcpServers: [String] = [],
        codexConfigurationFile: String? = nil
    ) {
        self.program = .known(kind, executable: executable)
        self.model = model
        self.effort = effort
        self.timeLimit = timeLimit
        self.mcpServers = mcpServers
        self.codexConfigurationFile = codexConfigurationFile
    }

    /// A command someone added.
    public init(name: String, command: String, timeLimit: Duration = .seconds(60)) {
        self.program = .custom(name: name, command: command)
        self.timeLimit = timeLimit
        self.mcpServers = []
    }

    /// Claude Code or Codex, or nil for a custom agent.
    public var kind: AgentKind? {
        if case .known(let kind, _) = program { kind } else { nil }
    }

    /// What people call it, as messages name it.
    public var name: String {
        switch program {
        case .known(let kind, _): kind.name
        case .custom(let name, _): name
        }
    }

    /// The name in a button's few words, as in Resolve with Claude.
    public var shortName: String {
        switch program {
        case .known(let kind, _): kind.shortName
        case .custom(let name, _): name
        }
    }

    /// The path of Claude Code's or Codex's command-line tool, or nil for a
    /// custom agent, which the shell finds.
    public var executable: String? {
        if case .known(_, let executable) = program { executable } else { nil }
    }
}
