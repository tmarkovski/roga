/// The agent that writes a commit message, and how to run it (decision 41).
/// The model and effort are the ones the Generate popover remembers, which the
/// Commit page of Settings shows and edits too.
public struct CommitMessageAgent: Sendable, Hashable {
    public var kind: AgentKind
    /// The absolute path of the agent's command-line tool.
    public var executable: String
    /// The model, such as `haiku`, or nil for the agent's own default.
    public var model: String?
    /// How hard the model thinks, such as `low`, `medium` or `high`, or nil
    /// for the agent's own default.
    public var effort: String?
    /// Arguments someone added in Settings, which go after Roga's own so that
    /// they can override them.
    public var extraArguments: [String]
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

    public init(
        kind: AgentKind,
        executable: String,
        model: String? = nil,
        effort: String? = nil,
        extraArguments: [String] = [],
        timeLimit: Duration = .seconds(60),
        mcpServers: [String] = [],
        codexConfigurationFile: String? = nil
    ) {
        self.kind = kind
        self.executable = executable
        self.model = model
        self.effort = effort
        self.extraArguments = extraArguments
        self.timeLimit = timeLimit
        self.mcpServers = mcpServers
        self.codexConfigurationFile = codexConfigurationFile
    }
}
