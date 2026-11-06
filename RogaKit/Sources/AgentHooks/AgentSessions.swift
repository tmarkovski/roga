import Foundation

/// Names one agent session. Session IDs are only unique within one agent, so
/// the key includes which agent it is.
public struct SessionKey: Hashable, Sendable {
    public var host: AgentHost
    public var id: String

    public init(host: AgentHost, id: String) {
        self.host = host
        self.id = id
    }
}

/// What a session is doing, as far as the sidebar's marks go (decision 41).
public enum AgentPhase: Sendable, Hashable {
    /// The session is there, between turns, with nothing new to look at.
    case idle
    case working
    /// The agent can't go on until the person does something.
    case waiting(WaitReason)
    /// The agent's turn ended. Whether the person has looked at it since is
    /// the app's business, not this one's.
    case finished(failed: Bool)

    var isWaiting: Bool {
        if case .waiting = self { true } else { false }
    }
}

/// Why a session is waiting for the person.
public enum WaitReason: Sendable, Hashable {
    /// It wants to be allowed to do something, such as run a command.
    case permission
    /// It asked a question, or wants a plan approved.
    case question
}

/// One agent session that Roga knows about.
public struct AgentSession: Sendable, Hashable {
    public var key: SessionKey
    /// The folder the agent last said it was working in, which says which
    /// worktree the session belongs to.
    public var cwd: String?
    /// The agent's process, so that the app can end the session when it exits.
    public var pid: Int32?
    /// When that process started, in seconds since 1970.
    public var processStart: Double?
    public var phase: AgentPhase
    /// When the phase began: when it started working, when it finished, and
    /// so on.
    public var phaseSince: Date
    /// When Roga last heard about the session, which is how it notices a
    /// session that has said it's working for a suspiciously long time.
    public var lastEvent: Date
    /// How many of the agent's subagents are running.
    public var subagents: Int
    /// What the agent is doing, as the helper's short line says it
    /// (decision 43): the tool it started last or wants to be allowed, or
    /// once it finished, the first line of its reply. It's nil when no line
    /// came since the turn began.
    public var activity: String?

    public init(
        key: SessionKey,
        cwd: String? = nil,
        pid: Int32? = nil,
        processStart: Double? = nil,
        phase: AgentPhase,
        phaseSince: Date,
        lastEvent: Date,
        subagents: Int = 0,
        activity: String? = nil
    ) {
        self.key = key
        self.cwd = cwd
        self.pid = pid
        self.processStart = processStart
        self.phase = phase
        self.phaseSince = phaseSince
        self.lastEvent = lastEvent
        self.subagents = subagents
        self.activity = activity
    }

    mutating func enter(_ phase: AgentPhase, at time: Date) {
        guard phase != self.phase else { return }
        self.phase = phase
        phaseSince = time
    }
}

/// What the hook events mean: every session Roga knows about and what each
/// one is doing (decision 41).
///
/// It's a plain value that the app feeds with the events the listener
/// decodes, with the processes it sees exit, and with what it asks the agent
/// itself, so every rule here can be tested without sockets or clocks. The
/// rules follow the agents' hooks, which leave gaps that only the app can
/// close: Claude Code sends nothing when someone presses Esc, nothing when a
/// permission prompt is answered, and nothing at all when it crashes.
public struct AgentSessions: Sendable, Hashable {
    public private(set) var sessions: [SessionKey: AgentSession] = [:]

    /// What Roga keeps about each session's hook events beyond what the
    /// session shows, so it can tell which of two events, or of an event and
    /// an answer from the agent, came last.
    private var heard: [SessionKey: Heard] = [:]

    private struct Heard: Sendable, Hashable {
        /// The time of the newest hook event that said what the session is
        /// doing, whether or not that changed the phase. An event from before
        /// it arrived late, and no longer changes the phase.
        var phase: Date?
        /// When the session last started, so that an end from before then,
        /// such as one that /resume has undone, doesn't end it.
        var started: Date?
    }

    /// Sessions that ended recently, so that an event from one that arrives
    /// after its end doesn't bring it back.
    private var endings: [Ending] = []

    private struct Ending: Sendable, Hashable {
        var key: SessionKey
        /// When the session ended, for a session the agent ended. Events
        /// from before then belong to it.
        var time: Date?
        /// The process that exited, for a session whose process did. Its
        /// events can still be on their way.
        var pid: Int32?
        var processStart: Double?
    }

    /// How much older than the last event an event has to be before Roga
    /// takes it as the clock having been set back rather than as a late
    /// event. A hook can't be later than its time limit, which is seconds.
    static let clockChange: TimeInterval = 30
    /// How many ended sessions to remember.
    static let endingsKept = 64

    public init() {}

    /// Applies one hook event. Returns whether any session changed.
    ///
    /// Hook events come from separate helper processes, so two close
    /// together can arrive in either order, and the listener can drain
    /// several connections at once in any order. So an event from before the
    /// last one that said what the session is doing never changes the phase
    /// or the line: a tool's late PostToolUse can't undo the Stop that came
    /// after it. A late event still fills in a folder or a process Roga
    /// doesn't know yet, and still counts its subagent.
    @discardableResult
    public mutating func apply(_ event: HookEvent) -> Bool {
        guard let id = event.session, !id.isEmpty else { return false }
        let key = SessionKey(host: event.host, id: id)
        let time = Date(timeIntervalSince1970: event.time)
        guard !hasEnded(key, sentBy: event, at: time) else { return false }
        let before = sessions

        if event.event == "SessionEnd" {
            // Nothing follows a session's end, so it ends the session however
            // late it arrives, unless it's from before the session last
            // started, as when /resume brought it back.
            if sessions[key] != nil, Self.isLate(time, after: heard[key]?.started) {
                return false
            }
            end(key, at: time)
            return sessions != before
        }

        let known = sessions[key]
        var session = known ?? AgentSession(key: key, phase: .idle, phaseSince: time, lastEvent: time)
        var heard = self.heard[key] ?? Heard()
        let isNewest = !Self.isLate(time, after: known?.lastEvent)

        // Subagents start and stop in any order relative to everything else,
        // so the count changes whenever their events arrive. Claude also sends
        // SubagentStop for its own small agents, such as prompt suggestions,
        // which never sent a SubagentStart.
        switch event.event {
        case "SubagentStart": session.subagents += 1
        case "SubagentStop": session.subagents = max(0, session.subagents - 1)
        default: break
        }

        if isNewest {
            if let pid = event.pid {
                session.pid = pid
                session.processStart = event.processStart
            }
            if let cwd = event.cwd, Self.movesTheFolder(event) {
                session.cwd = cwd
            }
        } else {
            if session.pid == nil, let pid = event.pid {
                session.pid = pid
                session.processStart = event.processStart
            }
            if session.cwd == nil, let cwd = event.cwd, Self.movesTheFolder(event) {
                session.cwd = cwd
            }
        }
        if !Self.isLate(time, after: heard.phase), let phase = Self.phase(after: event, from: known?.phase) {
            session.enter(phase, at: time)
            if event.subagent == nil {
                session.activity = Self.activity(after: event, from: session.activity)
            }
            // A subagent's own event only guesses at a session Roga hadn't
            // heard of, so it doesn't hold back the main agent's late ones.
            if event.subagent == nil || event.event == "SubagentStart" {
                heard.phase = time
            }
        }
        // A subagent keeps a working session from looking quiet, but its
        // events say nothing else about the main agent.
        if isNewest, event.subagent == nil || session.phase == .working {
            session.lastEvent = time
        }
        if event.event == "SessionStart" {
            heard.started = max(heard.started ?? time, time)
        }
        sessions[key] = session
        self.heard[key] = heard

        if event.event == "SessionStart" {
            endRotated(from: session, at: time)
        }
        return sessions != before
    }

    /// Ends every session whose agent process ended. When `processStart` is
    /// given, a session whose process started at another time is left alone,
    /// because that was another process that had the same ID.
    @discardableResult
    public mutating func processEnded(pid: Int32, processStart: Double? = nil) -> Bool {
        let ended = sessions.values.filter { session in
            session.pid == pid && Self.sameStart(session.processStart, processStart)
        }
        for session in ended {
            sessions[session.key] = nil
            heard[session.key] = nil
            remember(Ending(key: session.key, pid: pid, processStart: session.processStart ?? processStart))
        }
        return !ended.isEmpty
    }

    /// What `claude agents --json`, or anything else that asks the agent
    /// itself, says about a session.
    public enum Observed: Sendable, Hashable {
        case busy
        case waiting
        case idle
    }

    /// Applies what the agent itself says about a session. It seeds sessions
    /// that Roga missed while it was closed, and it corrects ones that the
    /// hooks left wrong, such as a session still shown working after someone
    /// pressed Esc.
    ///
    /// Status comes from the hooks (decision 41), and this only clears what
    /// they leave stale. The agent calls a finished session idle, so idle
    /// leaves a finished one alone, and busy leaves a waiting one alone, so
    /// that only a hook event ends a wait. That holds only while hooks speak
    /// for the session, though: one that started before the hooks were
    /// installed never loads them, so for a session no hook event has come
    /// from, the agent's word is all there is, and busy ends its wait too.
    ///
    /// Asking the agent takes a moment, and hook events keep arriving
    /// meanwhile. When one of them said what the session is doing after the
    /// agent was asked, it knows more than the answer, so the answer leaves
    /// the phase alone and only fills in what Roga doesn't know yet. That
    /// keeps a Stop that came in during the question from being turned back
    /// into working. In the same way, a session that ended after the agent
    /// was asked, or whose process Roga has seen exit, stays ended.
    ///
    /// - Parameter time: When the agent was asked. The session doesn't count
    ///   as quiet again until `quiet` after it.
    @discardableResult
    public mutating func observe(_ key: SessionKey, _ observed: Observed, cwd: String?, pid: Int32?, at time: Date) -> Bool {
        let before = sessions
        guard var session = sessions[key] else {
            guard !hasEnded(key, since: time, pid: pid) else { return false }
            let phase: AgentPhase = switch observed {
            case .busy: .working
            case .waiting: .waiting(.permission)
            case .idle: .idle
            }
            sessions[key] = AgentSession(key: key, cwd: cwd, pid: pid, phase: phase, phaseSince: time, lastEvent: time)
            return true
        }
        let hooksKnowMore = Self.isLate(time, after: heard[key]?.phase)
        let phaseBefore = session.phase
        if !hooksKnowMore {
            let isActive = session.phase == .working || session.phase.isWaiting
            let hooksEndItsWait = heardFromHooks(key)
            switch observed {
            case .busy where !isActive || (session.phase.isWaiting && !hooksEndItsWait):
                session.enter(.working, at: time)
            case .waiting where !session.phase.isWaiting:
                session.enter(.waiting(.permission), at: time)
            case .idle where isActive:
                session.enter(.idle, at: time)
            default:
                break
            }
        }
        // The answer says nothing about what the agent is doing, so a line
        // from before it no longer fits.
        if session.phase != phaseBefore {
            session.activity = nil
        }
        if session.cwd == nil {
            session.cwd = cwd
        }
        if let pid, pid != session.pid, session.pid == nil || !hooksKnowMore {
            session.pid = pid
            session.processStart = nil
        }
        session.lastEvent = max(session.lastEvent, time)
        sessions[key] = session
        return sessions != before
    }

    /// Whether any hook event has come from a session, which shows that its
    /// agent runs Roga's hooks. A session Roga knows only from asking the
    /// agent may have started before the hooks were installed, and then no
    /// hook will ever say what it does next, so the app has to keep asking.
    public func heardFromHooks(_ key: SessionKey) -> Bool {
        heard[key] != nil
    }

    /// The sessions that have shown working for at least `quiet` without any
    /// event, which is when the app asks Claude whether they really are,
    /// since pressing Esc sends no event at all.
    public func quietWorking(for quiet: Duration, now: Date) -> [SessionKey] {
        let seconds = Double(quiet.components.seconds) + Double(quiet.components.attoseconds) * 1e-18
        return sessions.values
            .filter { $0.phase == .working && now.timeIntervalSince($0.lastEvent) >= seconds }
            .map(\.key)
            .sorted { ($0.host.rawValue, $0.id) < ($1.host.rawValue, $1.id) }
    }

    // MARK: - The rules

    /// Whether something from `time` comes from before `last`, so that it
    /// arrived late. Something much older than `last` is new instead,
    /// because the clock must have been set back, and nothing is late when
    /// there's no `last`. It's public so that the app orders what it keeps
    /// about events in the same way.
    public static func isLate(_ time: Date, after last: Date?) -> Bool {
        guard let last else { return false }
        let age = last.timeIntervalSince(time)
        return age > 0 && age <= clockChange
    }

    /// The phase an event puts a session in, or nil when it says nothing
    /// about it. `current` is nil for a session Roga hasn't heard of before.
    static func phase(after event: HookEvent, from current: AgentPhase?) -> AgentPhase? {
        switch event.event {
        // A subagent starts during the main agent's turn. Its stop changes
        // nothing, since the main agent may still be going, or may have
        // finished already.
        case "SubagentStart": return .working
        case "SubagentStop": return nil
        default: break
        }
        // A subagent's own events say nothing about the main agent, except
        // that its turn is still going when Roga first hears of it.
        if event.subagent != nil {
            return current == nil ? .working : nil
        }
        switch event.event {
        case "SessionStart":
            // Compacting happens in the middle of a turn.
            if event.source == "compact" {
                return current == nil ? .working : nil
            }
            // Claude runs this hook in the background when it starts, so it
            // can arrive after the first prompt's, and then it's late.
            return .idle
        case "UserPromptSubmit":
            return .working
        case "PreToolUse":
            return asksAQuestion(event) ? .waiting(.question) : .working
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied", "ElicitationResult", "PreCompact", "PostCompact":
            return .working
        case "PermissionRequest", "Elicitation":
            return .waiting(.permission)
        case "Notification":
            // Notifications come late by design, and like any late event
            // they never override anything newer.
            switch event.notification {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog":
                return .waiting(.permission)
            case "idle_prompt":
                // Claude has sat idle for a minute. That also clears a
                // session that someone stopped with Esc.
                return current == .working ? .idle : nil
            default:
                return nil
            }
        case "Stop":
            // With background tasks still running, the session is waiting
            // for them rather than done.
            return (event.backgroundTasks ?? 0) > 0 ? .working : .finished(failed: false)
        case "StopFailure":
            return .finished(failed: true)
        case "Interrupt":
            return .idle
        default:
            return nil
        }
    }

    /// The line a session shows after an event from its main agent that says
    /// what it's doing (decision 43). A tool that starts or asks to be
    /// allowed brings its own line, and a tool that only keeps the agent's
    /// task list, which has none, leaves the one before. A tool that ends
    /// leaves its line until the next one starts, so the line doesn't come
    /// and go between tools, except a question that has been answered, whose
    /// line no longer holds once the agent works on. A denied tool's line
    /// goes too, since the agent goes on without it. `Stop` brings the first
    /// line of the reply, and a new turn, a new session, a failure or an
    /// interrupt clears it.
    static func activity(after event: HookEvent, from current: String?) -> String? {
        switch event.event {
        case "PreToolUse", "PermissionRequest": event.activity ?? current
        case "PostToolUse", "PostToolUseFailure": asksAQuestion(event) ? nil : current
        case "Stop": event.activity
        case "UserPromptSubmit", "StopFailure", "Interrupt", "PermissionDenied": nil
        case "SessionStart": event.source == "compact" ? current : nil
        default: current
        }
    }

    /// Whether a `PreToolUse` is the agent asking the person something: a
    /// question with choices or a plan to approve in Claude Code, or Codex
    /// asking for input.
    static func asksAQuestion(_ event: HookEvent) -> Bool {
        switch event.host {
        case .claude: event.tool == "AskUserQuestion" || event.tool == "ExitPlanMode"
        case .codex: event.tool == "request_user_input"
        }
    }

    /// Whether an event's `cwd` says where the session is. Since Codex 0.166,
    /// the tool events' `cwd` is the folder the command runs in, which can be
    /// anywhere. A subagent can work in a worktree of its own, which doesn't
    /// move the session. It's public so that the app can tell where an event
    /// came from in the same way, for one that names no session it knows.
    public static func movesTheFolder(_ event: HookEvent) -> Bool {
        guard event.subagent == nil else { return false }
        if event.host == .codex {
            return !["PreToolUse", "PostToolUse", "PermissionRequest"].contains(event.event)
        }
        return true
    }

    private static func sameStart(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return true }
        return a == b
    }

    // MARK: - Ending sessions

    private mutating func end(_ key: SessionKey, at time: Date) {
        sessions[key] = nil
        heard[key] = nil
        remember(Ending(key: key, time: time))
    }

    /// When Claude Code clears or resumes a conversation, the same process
    /// starts a new session, and the one it replaced is gone even when its
    /// SessionEnd didn't make it within Claude's short time limit. Codex is
    /// left out: its desktop app runs many sessions in one process, so a
    /// process starting a session doesn't mean another one ended.
    private mutating func endRotated(from session: AgentSession, at time: Date) {
        guard session.key.host == .claude, let pid = session.pid else { return }
        let rotated = sessions.values.filter { other in
            other.key != session.key && other.key.host == session.key.host
                && other.pid == pid && Self.sameStart(other.processStart, session.processStart)
        }
        for other in rotated {
            end(other.key, at: time)
        }
    }

    private func hasEnded(_ key: SessionKey, sentBy event: HookEvent, at time: Date) -> Bool {
        endings.contains { ending in
            guard ending.key == key else { return false }
            // An event from long before the end can't be on its way still,
            // so the clock must have been set back, and it's a new event.
            if let ended = ending.time, time <= ended, ended.timeIntervalSince(time) <= Self.clockChange {
                return true
            }
            if let pid = ending.pid, event.pid == pid, Self.sameStart(ending.processStart, event.processStart) {
                return true
            }
            return false
        }
    }

    /// Whether a session the agent says it has, asked at `time`, has ended
    /// since: the agent ended it after it was asked, or the process the
    /// agent names for it is one Roga has seen exit. An answer can't name a
    /// process's start time, so the process ID alone decides.
    private func hasEnded(_ key: SessionKey, since time: Date, pid: Int32?) -> Bool {
        endings.contains { ending in
            guard ending.key == key else { return false }
            if let ended = ending.time, Self.isLate(time, after: ended) {
                return true
            }
            if let ended = ending.pid, ended == pid {
                return true
            }
            return false
        }
    }

    private mutating func remember(_ ending: Ending) {
        endings.append(ending)
        if endings.count > Self.endingsKept {
            endings.removeFirst(endings.count - Self.endingsKept)
        }
    }
}
