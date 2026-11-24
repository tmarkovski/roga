import AgentHooks
import Foundation

/// One session in the worktree a window shows, as the branch row and its
/// popover show it (decision 100).
struct WorktreeAgent: Equatable, Identifiable {
    var id: SessionKey
    var host: AgentHost
    var phase: AgentPhase
    /// When it started working, started waiting, or finished.
    var since: Date
    /// What it's doing, as the helper's line says it (decision 47), or once it
    /// finished, the first line of its reply.
    var activity: String?
}

/// What the branch row says about the agents in the worktree on screen
/// (decision 100): the sidebar's second line for them after a mark, and in the
/// popover behind it, a section for each session.
///
/// It speaks for the most urgent of them, as a sidebar row's mark does, and
/// keeps a finished session after someone has looked, since the worktree on
/// screen counts as seen at once. So a finished one gets a gray check rather
/// than the blue dot, which means that nobody has looked yet.
struct AgentLine: Equatable {
    /// What starts the line.
    enum Mark: Equatable {
        /// The sidebar's mark: the turning ring, or the amber circle.
        case agent(AgentSummary.State)
        /// A gray check in a circle, for a turn that ended.
        case finished
        /// A red cross in a circle, for a turn that ended with an error.
        case failed
    }

    /// The sessions, most urgent first, as the popover lists them: the ones
    /// waiting for you, then the ones at work, then the ones that finished,
    /// and among each the one that has been at it longest first.
    let agents: [WorktreeAgent]
    /// The most urgent state among them, which the mark and the words are
    /// about.
    let summary: AgentSummary

    /// The line for some sessions, or nil when none is working, waiting or
    /// finished, which leaves the row as it was.
    init?(_ agents: [WorktreeAgent]) {
        let shown = agents.filter { $0.phase != .idle }
        guard let summary = AgentSummary(shown.map { (host: $0.host, phase: $0.phase, since: $0.since, activity: $0.activity) }) else { return nil }
        self.summary = summary
        self.agents = shown.sorted { a, b in
            let (rankA, rankB) = (Self.rank(a.phase), Self.rank(b.phase))
            if rankA != rankB { return rankA < rankB }
            if a.since != b.since { return a.since < b.since }
            return a.id.id < b.id.id
        }
    }

    private static func rank(_ phase: AgentPhase) -> Int {
        switch phase {
        case .waiting: 0
        case .working: 1
        case .finished: 2
        case .idle: 3
        }
    }

    /// Whether an agent waits for you, which puts the words in amber.
    var isWaiting: Bool {
        if case .waiting = summary.state { true } else { false }
    }

    /// Whether any agent is at work, which is when history's row for
    /// uncommitted changes shimmers, since its files are still being made.
    /// One at work beside another that waits for you still counts, though
    /// the line speaks for the one that waits.
    var isWorking: Bool {
        agents.contains { $0.phase == .working }
    }

    /// Whether the line is about one session whose turn ended with an error.
    /// Claude Code's `StopFailure` leaves no line to show, so the line says
    /// that it stopped instead.
    var hasFailed: Bool {
        summary.state == .finished && summary.sessions == 1 && agents.first?.phase == .finished(failed: true)
    }

    var mark: Mark {
        switch summary.state {
        case .finished: hasFailed ? .failed : .finished
        case let state: .agent(state)
        }
    }

    /// The agent's name, or how many there are.
    private var agentName: String {
        summary.sessions == 1 ? summary.hosts.first?.name ?? "An agent" : "\(summary.sessions) agents"
    }

    /// What the line says, in two parts so that the words can be cut short and
    /// how long stays whole: the sidebar's second line, as in "Run the test
    /// suite" and "6 min", "Approval required: git push" or "2 agents
    /// working". When other sessions in the worktree are doing something else,
    /// it names the agent it's about, as the worktree menu does, as in "Codex
    /// needs approval: git push".
    func parts(now: Date) -> (words: String, time: String?) {
        if hasFailed { return ("\(agentName) stopped with an error", nil) }
        if agents.count > summary.sessions { return summary.menuParts(now: now) }
        return summary.rowParts(now: now)
    }

    /// The tooltip, which is the mark's from decision 47, as in "Claude Code
    /// is working: Run the test suite, for 6 minutes", and what VoiceOver
    /// reads.
    func help(now: Date) -> String {
        hasFailed ? "\(agentName) stopped with an error" : summary.help(now: now)
    }

    // MARK: The popover's sections

    /// The mark of one session in the popover.
    static func mark(of phase: AgentPhase) -> Mark {
        switch phase {
        case .waiting(let reason): .agent(.waiting(reason))
        case .finished(let failed): failed ? .failed : .finished
        case .working, .idle: .agent(.working)
        }
    }

    /// What one session is doing, in a word or two, for its section.
    static func state(of phase: AgentPhase) -> String {
        switch phase {
        case .working, .idle: "Working"
        case .waiting(.permission): "Approval required"
        case .waiting(.question): "Waiting for you"
        case .finished(failed: false): "Finished"
        case .finished(failed: true): "Stopped with an error"
        }
    }

    /// How long one session has been working or waiting, from a minute on,
    /// as in "6 min". A finished one says nothing.
    static func time(of agent: WorktreeAgent, now: Date) -> String? {
        if case .finished = agent.phase { return nil }
        let minutes = AgentSummary.minutes(from: agent.since, to: now)
        return minutes > 0 ? AgentSummary.shortDuration(minutes: minutes) : nil
    }

    /// One session's whole line, under its name: what it's doing or wants
    /// allowed, or the first line of its reply.
    static func detail(of agent: WorktreeAgent) -> String? {
        if agent.phase == .finished(failed: true) { return agent.activity ?? "Its turn ended with an error." }
        return agent.activity
    }

    /// The moments the popover's times change, which are those of every
    /// session that's working or waiting.
    var minutes: WholeMinutes {
        WholeMinutes(since: agents.compactMap { agent in
            if case .finished = agent.phase { nil } else { agent.since }
        })
    }
}
