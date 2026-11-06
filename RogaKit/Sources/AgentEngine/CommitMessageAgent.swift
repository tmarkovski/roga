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

    public init(
        kind: AgentKind,
        executable: String,
        model: String? = nil,
        effort: String? = nil,
        extraArguments: [String] = [],
        timeLimit: Duration = .seconds(60)
    ) {
        self.kind = kind
        self.executable = executable
        self.model = model
        self.effort = effort
        self.extraArguments = extraArguments
        self.timeLimit = timeLimit
    }
}
