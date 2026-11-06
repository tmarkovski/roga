/// An agent whose command-line tool Roga can run, to write commit messages and
/// to install the hooks that tell Roga what the agent is doing (decision 41).
public enum AgentKind: String, Sendable, Hashable, CaseIterable, Codable, Identifiable {
    case claude
    case codex

    public var id: Self { self }

    /// What people call it.
    public var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}
