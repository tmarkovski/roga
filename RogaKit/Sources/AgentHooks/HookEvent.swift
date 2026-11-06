/// The agents whose hooks report to Roga (decision 41). The helper is told
/// which one ran it, with `--host`, because a plugin folder that serves both
/// agents can't tell from the payload alone, and GitKraken's single plugin
/// labels Codex sessions as Claude's for exactly that reason.
public enum AgentHost: String, Codable, Sendable, Hashable, CaseIterable {
    case claude
    case codex
}

/// What the helper tells Roga about one hook event, as one line of JSON on
/// the socket (decision 41).
///
/// It carries only what Roga needs to know what a session is doing and
/// where. Prompts, tool input and tool output never leave the helper, so a
/// line stays small enough to fit in the socket's buffer at once.
public struct HookEvent: Codable, Sendable, Hashable {
    /// Which version of this format the helper wrote. It's 1.
    public var version: Int
    public var host: AgentHost
    /// The hook's event name, such as `PreToolUse` or `Stop`.
    public var event: String
    /// The agent's session ID. Events without one tell Roga nothing.
    public var session: String?
    /// The folder the agent says it's working in.
    public var cwd: String?
    /// The agent's process, found by walking up from the helper past any
    /// shells, so Roga can tell when it exits.
    public var pid: Int32?
    /// When that process started, in seconds since 1970, so that a process
    /// that later gets the same ID isn't taken for it.
    public var processStart: Double?
    /// The tool, for tool events.
    public var tool: String?
    /// The kind of notification, such as `permission_prompt`.
    public var notification: String?
    /// Why a session started, such as `startup`, `clear` or `compact`.
    public var source: String?
    /// Why a session ended, such as `clear` or `logout`.
    public var reason: String?
    /// The subagent that sent the event, when it wasn't the main agent.
    public var subagent: String?
    /// How many background tasks were still running when Claude stopped.
    public var backgroundTasks: Int?
    /// What kind of error ended a Claude turn, such as `rate_limit`.
    public var error: String?
    /// When the helper ran, in seconds since 1970.
    public var time: Double

    public init(
        version: Int = 1,
        host: AgentHost,
        event: String,
        session: String? = nil,
        cwd: String? = nil,
        pid: Int32? = nil,
        processStart: Double? = nil,
        tool: String? = nil,
        notification: String? = nil,
        source: String? = nil,
        reason: String? = nil,
        subagent: String? = nil,
        backgroundTasks: Int? = nil,
        error: String? = nil,
        time: Double
    ) {
        self.version = version
        self.host = host
        self.event = event
        self.session = session
        self.cwd = cwd
        self.pid = pid
        self.processStart = processStart
        self.tool = tool
        self.notification = notification
        self.source = source
        self.reason = reason
        self.subagent = subagent
        self.backgroundTasks = backgroundTasks
        self.error = error
        self.time = time
    }
}
