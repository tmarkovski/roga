import Foundation
import Testing
@testable import AgentHooks

/// A hook event for session "a" of Claude Code, unless it says otherwise.
private func hook(
    _ event: String,
    session: String? = "a",
    host: AgentHost = .claude,
    at time: Double,
    cwd: String? = nil,
    pid: Int32? = nil,
    processStart: Double? = nil,
    tool: String? = nil,
    notification: String? = nil,
    source: String? = nil,
    subagent: String? = nil,
    backgroundTasks: Int? = nil,
    activity: String? = nil
) -> HookEvent {
    HookEvent(
        host: host, event: event, session: session, cwd: cwd, pid: pid, processStart: processStart, tool: tool,
        notification: notification, source: source, subagent: subagent, backgroundTasks: backgroundTasks,
        activity: activity, time: time
    )
}

private let a = SessionKey(host: .claude, id: "a")
private let b = SessionKey(host: .claude, id: "b")

extension AgentSessions {
    fileprivate func phase(_ key: SessionKey = a) -> AgentPhase? {
        sessions[key]?.phase
    }

    fileprivate func activity(_ key: SessionKey = a) -> String? {
        sessions[key]?.activity
    }

    /// Sessions that have each been through `events`.
    fileprivate init(_ events: HookEvent...) {
        self.init()
        for event in events {
            apply(event)
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AgentSessionsTests {
    // MARK: - Starting and ending

    @Test func ignoresEventsWithoutASessionID() {
        var sessions = AgentSessions()
        var changed = sessions.apply(hook("UserPromptSubmit", session: nil, at: 1))
        #expect(!changed)
        changed = sessions.apply(hook("UserPromptSubmit", session: "", at: 1))
        #expect(!changed)
        #expect(sessions.sessions.isEmpty)
    }

    @Test func aSessionStartsIdle() throws {
        var sessions = AgentSessions()
        let changed = sessions.apply(hook("SessionStart", at: 10, cwd: "/w", pid: 42, processStart: 5, source: "startup"))
        #expect(changed)
        let session = try #require(sessions.sessions[a])
        #expect(
            session
                == AgentSession(
                    key: a, cwd: "/w", pid: 42, processStart: 5, phase: .idle, phaseSince: date(10), lastEvent: date(10)
                )
        )
    }

    @Test func sessionsOfTheTwoAgentsAreApartEvenWithTheSameID() {
        let sessions = AgentSessions(
            hook("UserPromptSubmit", at: 1),
            hook("SessionStart", host: .codex, at: 2)
        )
        #expect(sessions.phase(a) == .working)
        #expect(sessions.phase(SessionKey(host: .codex, id: "a")) == .idle)
    }

    @Test func compactingLeavesThePhaseAlone() throws {
        let sessions = AgentSessions(
            hook("UserPromptSubmit", at: 10),
            hook("SessionStart", at: 11, source: "compact")
        )
        let session = try #require(sessions.sessions[a])
        #expect(session.phase == .working)
        #expect(session.phaseSince == date(10))
        // Roga first hears of a session in the middle of a turn.
        #expect(AgentSessions(hook("SessionStart", at: 11, source: "compact")).phase() == .working)
    }

    @Test func aNewSessionInTheSameProcessReplacesTheOneItCleared() {
        var sessions = AgentSessions(
            hook("SessionStart", at: 1, pid: 42, processStart: 5, source: "startup"),
            hook("Stop", at: 2)
        )
        // /clear sends SessionEnd for the old session, but it can miss
        // Claude's time limit.
        let changed = sessions.apply(hook("SessionStart", session: "b", at: 3, pid: 42, processStart: 5, source: "clear"))
        #expect(changed)
        #expect(sessions.sessions.keys.sorted { $0.id < $1.id } == [b])
        #expect(sessions.phase(b) == .idle)
    }

    @Test func aSessionInAnotherProcessIsntReplaced() {
        let sessions = AgentSessions(
            hook("SessionStart", at: 1, pid: 42, processStart: 5),
            hook("SessionStart", session: "b", at: 2, pid: 42, processStart: 9),
            hook("SessionStart", session: "c", at: 3, pid: 43, processStart: 5)
        )
        #expect(sessions.sessions.count == 3)
    }

    @Test func codexSessionsSharingAProcessAreAllKept() {
        // The Codex app runs every thread in one app-server process.
        let sessions = AgentSessions(
            hook("SessionStart", host: .codex, at: 1, pid: 42, processStart: 5),
            hook("SessionStart", session: "b", host: .codex, at: 2, pid: 42, processStart: 5)
        )
        #expect(sessions.sessions.count == 2)
    }

    @Test func sessionEndRemovesTheSession() {
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 1), hook("SessionStart", session: "b", at: 1))
        var changed = sessions.apply(hook("SessionEnd", at: 2))
        #expect(changed)
        #expect(sessions.sessions[a] == nil)
        #expect(sessions.sessions[b] != nil)
        changed = sessions.apply(hook("SessionEnd", at: 3))
        #expect(!changed)
    }

    @Test func anEventThatArrivesAfterTheEndDoesntBringTheSessionBack() {
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 1), hook("SessionEnd", at: 11))
        var changed = sessions.apply(hook("Stop", at: 10))
        #expect(!changed)
        changed = sessions.apply(hook("Notification", at: 11, notification: "idle_prompt"))
        #expect(!changed)
        #expect(sessions.sessions.isEmpty)
        // Resuming it later is a new start.
        changed = sessions.apply(hook("SessionStart", at: 20, source: "resume"))
        #expect(changed)
        #expect(sessions.phase() == .idle)
    }

    @Test func aSessionEndEndsTheSessionHoweverLateItArrives() {
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 10), hook("PostToolUse", at: 20))
        var changed = sessions.apply(hook("SessionEnd", at: 15))
        #expect(changed)
        #expect(sessions.sessions.isEmpty)

        // Roga asked the agent about the session before it had read the end.
        sessions = AgentSessions(hook("UserPromptSubmit", at: 10))
        sessions.observe(a, .busy, cwd: nil, pid: nil, at: date(100))
        changed = sessions.apply(hook("SessionEnd", at: 97.5))
        #expect(changed)
        #expect(sessions.sessions.isEmpty)
    }

    @Test func aSessionEndFromBeforeTheSessionStartedAgainDoesntEndIt() throws {
        // The session was resumed in another process before Roga read the
        // first one's end.
        var sessions = AgentSessions(
            hook("UserPromptSubmit", at: 1, pid: 42, processStart: 1),
            hook("SessionStart", at: 20, pid: 50, processStart: 19, source: "resume")
        )
        let changed = sessions.apply(hook("SessionEnd", at: 10, pid: 42, processStart: 1))
        #expect(!changed)
        let session = try #require(sessions.sessions[a])
        #expect(session.pid == 50)
        #expect(session.phase == .idle)
    }

    // MARK: - Turns

    @Test func aPromptStartsWorkAndAQueuedOneKeepsWhenItStarted() throws {
        var sessions = AgentSessions(hook("SessionStart", at: 1), hook("UserPromptSubmit", at: 10))
        #expect(sessions.phase() == .working)
        let changed = sessions.apply(hook("UserPromptSubmit", at: 20))
        #expect(changed)
        let session = try #require(sessions.sessions[a])
        #expect(session.phaseSince == date(10))
        #expect(session.lastEvent == date(20))
    }

    @Test(arguments: [(AgentHost.claude, "AskUserQuestion"), (.claude, "ExitPlanMode"), (.codex, "request_user_input")])
    func askingThePersonSomethingWaitsForAnAnswer(host: AgentHost, tool: String) {
        let sessions = AgentSessions(
            hook("UserPromptSubmit", host: host, at: 1),
            hook("PreToolUse", host: host, at: 2, tool: tool)
        )
        #expect(sessions.phase(SessionKey(host: host, id: "a")) == .waiting(.question))
    }

    @Test(arguments: [(AgentHost.claude, "Bash"), (.claude, "request_user_input"), (.codex, "AskUserQuestion"), (.codex, "exec_command")])
    func otherToolsAreWork(host: AgentHost, tool: String) {
        let sessions = AgentSessions(hook("PreToolUse", host: host, at: 2, tool: tool))
        #expect(sessions.phase(SessionKey(host: host, id: "a")) == .working)
    }

    @Test(arguments: ["PostToolUse", "PostToolUseFailure", "PermissionDenied", "ElicitationResult", "PreCompact", "PostCompact", "SubagentStart"])
    func eventsDuringATurnAreWork(event: String) {
        let sessions = AgentSessions(hook("PermissionRequest", at: 1), hook(event, at: 2, subagent: event == "SubagentStart" ? "x" : nil))
        #expect(sessions.phase() == .working)
    }

    @Test(arguments: ["PermissionRequest", "Elicitation"])
    func permissionRequestsWaitForThePerson(event: String) {
        let sessions = AgentSessions(hook("UserPromptSubmit", at: 1), hook(event, at: 2))
        #expect(sessions.phase() == .waiting(.permission))
    }

    @Test(arguments: ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog"])
    func notificationsOfAPromptWaitForThePerson(type: String) {
        let sessions = AgentSessions(hook("UserPromptSubmit", at: 1), hook("Notification", at: 7, notification: type))
        #expect(sessions.phase() == .waiting(.permission))
    }

    @Test func otherNotificationsChangeNothing() {
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 1))
        sessions.apply(hook("Notification", at: 2, notification: "auth_success"))
        sessions.apply(hook("Notification", at: 3))
        #expect(sessions.phase() == .working)
    }

    @Test func anIdlePromptClearsWorkButNothingElse() {
        // Claude sends it after a minute without input, which also catches
        // a turn that someone stopped with Esc.
        #expect(AgentSessions(hook("UserPromptSubmit", at: 1), hook("Notification", at: 61, notification: "idle_prompt")).phase() == .idle)
        #expect(AgentSessions(hook("Stop", at: 1), hook("Notification", at: 61, notification: "idle_prompt")).phase() == .finished(failed: false))
        #expect(AgentSessions(hook("PermissionRequest", at: 1), hook("Notification", at: 61, notification: "idle_prompt")).phase() == .waiting(.permission))
        #expect(AgentSessions(hook("Notification", at: 61, notification: "idle_prompt")).phase() == .idle)
    }

    @Test func stopFinishesTheTurn() throws {
        let sessions = AgentSessions(hook("UserPromptSubmit", at: 1), hook("Stop", at: 9))
        let session = try #require(sessions.sessions[a])
        #expect(session.phase == .finished(failed: false))
        #expect(session.phaseSince == date(9))
    }

    @Test func stopWithBackgroundTasksKeepsWorking() throws {
        let sessions = AgentSessions(hook("UserPromptSubmit", at: 1), hook("Stop", at: 9, backgroundTasks: 2))
        let session = try #require(sessions.sessions[a])
        #expect(session.phase == .working)
        #expect(session.phaseSince == date(1))
        #expect(AgentSessions(hook("UserPromptSubmit", at: 1), hook("Stop", at: 9, backgroundTasks: 0)).phase() == .finished(failed: false))
    }

    @Test func stopFailureFinishesWithAFailure() {
        #expect(AgentSessions(hook("UserPromptSubmit", at: 1), hook("StopFailure", at: 9)).phase() == .finished(failed: true))
    }

    @Test func anInterruptMakesItIdle() {
        let codex = SessionKey(host: .codex, id: "a")
        let sessions = AgentSessions(hook("UserPromptSubmit", host: .codex, at: 1), hook("Interrupt", host: .codex, at: 5))
        #expect(sessions.phase(codex) == .idle)
    }

    @Test func anUnknownEventChangesNothingButIsHeard() throws {
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 1))
        let changed = sessions.apply(hook("TeammateIdle", at: 4))
        #expect(changed)
        let session = try #require(sessions.sessions[a])
        #expect(session.phase == .working)
        #expect(session.lastEvent == date(4))
        #expect(AgentSessions(hook("ConfigChange", at: 4)).phase() == .idle)
    }

    // MARK: - Subagents

    @Test func aSubagentsEventsDontChangeThePhase() throws {
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 1))
        sessions.apply(hook("PreToolUse", at: 20, tool: "AskUserQuestion", subagent: "x"))
        sessions.apply(hook("PermissionRequest", at: 21, subagent: "x"))
        sessions.apply(hook("Stop", at: 22, subagent: "x"))
        var session = try #require(sessions.sessions[a])
        #expect(session.phase == .working)
        #expect(session.lastEvent == date(22))

        sessions.apply(hook("Stop", at: 30))
        let changed = sessions.apply(hook("PostToolUse", at: 31, subagent: "x"))
        #expect(!changed)
        session = try #require(sessions.sessions[a])
        #expect(session.phase == .finished(failed: false))
        #expect(session.lastEvent == date(30))
    }

    @Test func subagentsAreCountedButNeverBelowZero() throws {
        var sessions = AgentSessions(
            hook("UserPromptSubmit", at: 1),
            hook("SubagentStart", at: 2, subagent: "x"),
            hook("SubagentStart", at: 3, subagent: "y")
        )
        #expect(sessions.sessions[a]?.subagents == 2)
        sessions.apply(hook("SubagentStop", at: 4, subagent: "x"))
        sessions.apply(hook("SubagentStop", at: 5, subagent: "y"))
        sessions.apply(hook("Stop", at: 6))
        // Claude also stops agents it never said it started, such as the
        // one that suggests the next prompt.
        sessions.apply(hook("SubagentStop", at: 7, subagent: "z"))
        let session = try #require(sessions.sessions[a])
        #expect(session.subagents == 0)
        #expect(session.phase == .finished(failed: false))
    }

    @Test func codexSubagentsShareTheirParentsSession() throws {
        let codex = SessionKey(host: .codex, id: "a")
        var sessions = AgentSessions(
            hook("UserPromptSubmit", host: .codex, at: 1),
            hook("SubagentStart", host: .codex, at: 2, subagent: "x"),
            hook("UserPromptSubmit", host: .codex, at: 3, subagent: "x"),
            hook("SubagentStop", host: .codex, at: 4, subagent: "x")
        )
        #expect(sessions.sessions[codex]?.subagents == 0)
        #expect(sessions.phase(codex) == .working)
        sessions.apply(hook("Stop", host: .codex, at: 5))
        #expect(sessions.phase(codex) == .finished(failed: false))
    }

    @Test func aSubagentsEventStartsAnUnknownSessionAsWorking() {
        #expect(AgentSessions(hook("PostToolUse", at: 1, subagent: "x")).phase() == .working)
        #expect(AgentSessions(hook("SubagentStop", at: 1, subagent: "x")).phase() == .idle)
        // That's only a guess, so the main agent's own word still counts
        // when it arrives a moment late.
        #expect(AgentSessions(hook("PostToolUse", at: 1, subagent: "x"), hook("Stop", at: 0.9)).phase() == .finished(failed: false))
    }

    // MARK: - Folders

    @Test func theFolderFollowsTheAgent() {
        var sessions = AgentSessions(hook("SessionStart", at: 1, cwd: "/w"))
        sessions.apply(hook("CwdChanged", at: 2, cwd: "/w/app"))
        #expect(sessions.sessions[a]?.cwd == "/w/app")
        sessions.apply(hook("PreToolUse", at: 3, cwd: "/v"))
        #expect(sessions.sessions[a]?.cwd == "/v")
        sessions.apply(hook("Stop", at: 4))
        #expect(sessions.sessions[a]?.cwd == "/v")
    }

    @Test func codexToolEventsDontMoveTheFolder() {
        // Since Codex 0.166 their `cwd` is where the command runs.
        let codex = SessionKey(host: .codex, id: "a")
        var sessions = AgentSessions(
            hook("SessionStart", host: .codex, at: 1, cwd: "/w"),
            hook("PreToolUse", host: .codex, at: 2, cwd: "/tmp"),
            hook("PermissionRequest", host: .codex, at: 3, cwd: "/tmp"),
            hook("PostToolUse", host: .codex, at: 4, cwd: "/tmp")
        )
        #expect(sessions.sessions[codex]?.cwd == "/w")
        sessions.apply(hook("Stop", host: .codex, at: 5, cwd: "/v"))
        #expect(sessions.sessions[codex]?.cwd == "/v")
    }

    @Test func aSubagentsEventsDontMoveTheFolder() {
        let sessions = AgentSessions(
            hook("UserPromptSubmit", at: 1, cwd: "/w"),
            hook("PreToolUse", at: 2, cwd: "/w/.claude/worktrees/x", subagent: "x")
        )
        #expect(sessions.sessions[a]?.cwd == "/w")
    }

    // MARK: - Events out of order

    @Test(arguments: [
        (hook("Stop", at: 10), AgentPhase.finished(failed: false)),
        (hook("StopFailure", at: 10), .finished(failed: true)),
        (hook("PermissionRequest", at: 10), .waiting(.permission)),
        (hook("PreToolUse", at: 10, tool: "AskUserQuestion"), .waiting(.question)),
    ])
    func anEventEvenAMomentLateDoesntUndoANewerOne(newer: HookEvent, expected: AgentPhase) {
        // The tool's PostToolUse ran just before the turn ended or stopped
        // for the person, but its line arrived after.
        let sessions = AgentSessions(hook("UserPromptSubmit", at: 1), newer, hook("PostToolUse", at: 9.995))
        #expect(sessions.phase() == expected)
        #expect(AgentSessions(hook("UserPromptSubmit", at: 1), newer, hook("UserPromptSubmit", at: 9)).phase() == expected)
    }

    @Test func aLateEventDoesntUndoOneThatOnlyConfirmedThePhase() {
        // The permission was granted and the tool ran, so the session is
        // working again, even though the PostToolUse didn't change its phase.
        let sessions = AgentSessions(
            hook("UserPromptSubmit", at: 1),
            hook("PostToolUse", at: 50),
            hook("PermissionRequest", at: 49)
        )
        #expect(sessions.phase() == .working)
    }

    @Test func eventsThatSayNothingAboutThePhaseDontHoldBackALateOne() {
        // A subagent's event and a change of folder came in between, but the
        // main agent's Stop is still the last word on its turn.
        var sessions = AgentSessions(
            hook("UserPromptSubmit", at: 1),
            hook("PostToolUse", at: 50.1, subagent: "x"),
            hook("Stop", at: 50)
        )
        #expect(sessions.phase() == .finished(failed: false))
        sessions = AgentSessions(
            hook("UserPromptSubmit", at: 1),
            hook("Stop", at: 20),
            hook("CwdChanged", at: 20.5, cwd: "/w"),
            hook("UserPromptSubmit", at: 20.4)
        )
        #expect(sessions.phase() == .working)
    }

    @Test func aLateEventFillsInWhatsMissingButChangesNothingElse() throws {
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 1, cwd: "/w"), hook("Stop", at: 10))
        let changed = sessions.apply(hook("PostToolUse", at: 7, cwd: "/v", pid: 9, processStart: 3))
        #expect(changed)
        var session = try #require(sessions.sessions[a])
        #expect(session.phase == .finished(failed: false))
        #expect(session.phaseSince == date(10))
        #expect(session.cwd == "/w")
        #expect(session.pid == 9)
        #expect(session.processStart == 3)
        #expect(session.lastEvent == date(10))

        sessions = AgentSessions(hook("UserPromptSubmit", at: 1), hook("Stop", at: 10, pid: 42))
        sessions.apply(hook("PostToolUse", at: 9, cwd: "/v", pid: 9))
        session = try #require(sessions.sessions[a])
        #expect(session.cwd == "/v")
        #expect(session.pid == 42)
    }

    @Test func aLateEventStillCountsItsSubagent() {
        let sessions = AgentSessions(hook("UserPromptSubmit", at: 10), hook("SubagentStart", at: 1, subagent: "x"))
        #expect(sessions.sessions[a]?.subagents == 1)
    }

    @Test func aSessionStartThatArrivesAfterTheFirstPromptDoesntMakeItIdle() {
        // Claude runs SessionStart's hooks in the background.
        let sessions = AgentSessions(hook("UserPromptSubmit", at: 10.5), hook("SessionStart", at: 10.4, source: "startup"))
        #expect(sessions.phase() == .working)
    }

    @Test func aLateNotificationDoesntUndoAnAnswer() {
        let sessions = AgentSessions(
            hook("PermissionRequest", at: 4),
            hook("PostToolUse", at: 10),
            hook("Notification", at: 9.9, notification: "permission_prompt")
        )
        #expect(sessions.phase() == .working)
    }

    @Test func aClockSetBackDoesntFreezeTheSession() throws {
        let sessions = AgentSessions(hook("Stop", at: 100), hook("UserPromptSubmit", at: 40))
        let session = try #require(sessions.sessions[a])
        #expect(session.phase == .working)
        #expect(session.lastEvent == date(40))
    }

    // MARK: - Processes

    @Test func anEndedProcessEndsItsSessions() {
        var sessions = AgentSessions(
            hook("SessionStart", at: 1, pid: 42, processStart: 5),
            hook("UserPromptSubmit", session: "b", host: .codex, at: 1, pid: 42, processStart: 5),
            hook("SessionStart", session: "c", at: 1, pid: 43, processStart: 5)
        )
        var changed = sessions.processEnded(pid: 42)
        #expect(changed)
        #expect(sessions.sessions.keys.map(\.id) == ["c"])
        changed = sessions.processEnded(pid: 42)
        #expect(!changed)
    }

    @Test func anEndedProcessLeavesAProcessThatGotItsIDAlone() {
        var sessions = AgentSessions(hook("SessionStart", at: 1, pid: 42, processStart: 5))
        var changed = sessions.processEnded(pid: 42, processStart: 6)
        #expect(!changed)
        changed = sessions.processEnded(pid: 42, processStart: 5)
        #expect(changed)
    }

    @Test func eventsFromAnEndedProcessDontBringItsSessionsBack() {
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 1, pid: 42, processStart: 5))
        sessions.processEnded(pid: 42)
        var changed = sessions.apply(hook("Stop", at: 2, pid: 42, processStart: 5))
        #expect(!changed)
        #expect(sessions.sessions.isEmpty)
        // The same session resumed in another process is back.
        changed = sessions.apply(hook("SessionStart", at: 3, pid: 50, processStart: 3, source: "resume"))
        #expect(changed)
        #expect(sessions.sessions[a]?.pid == 50)
    }

    // MARK: - What the agent says

    @Test func observingSeedsSessionsRogaMissed() {
        var sessions = AgentSessions()
        let changed = sessions.observe(a, .busy, cwd: "/w", pid: 42, at: date(5))
        #expect(changed)
        sessions.observe(b, .waiting, cwd: nil, pid: nil, at: date(5))
        sessions.observe(SessionKey(host: .claude, id: "c"), .idle, cwd: nil, pid: nil, at: date(5))
        #expect(sessions.sessions[a] == AgentSession(key: a, cwd: "/w", pid: 42, phase: .working, phaseSince: date(5), lastEvent: date(5)))
        #expect(sessions.phase(b) == .waiting(.permission))
        #expect(sessions.phase(SessionKey(host: .claude, id: "c")) == .idle)
    }

    @Test func busyRevivesAFinishedOrIdleSessionButLeavesOneThatsWaiting() {
        for (start, expected) in [
            (hook("Stop", at: 1), AgentPhase.working),
            (hook("SessionStart", at: 1), .working),
            (hook("PermissionRequest", at: 1), .waiting(.permission)),
            (hook("PreToolUse", at: 1, tool: "AskUserQuestion"), .waiting(.question)),
        ] {
            var sessions = AgentSessions(start)
            sessions.observe(a, .busy, cwd: nil, pid: nil, at: date(10))
            #expect(sessions.phase() == expected)
        }
    }

    @Test func busyEndsTheWaitOfASessionNoHookSpeaksFor() {
        // It started before the hooks were installed, so it never loads them,
        // and only the agent can say that the wait is over.
        var sessions = AgentSessions()
        sessions.observe(a, .waiting, cwd: "/w", pid: 42, at: date(5))
        #expect(!sessions.heardFromHooks(a))
        sessions.observe(a, .busy, cwd: nil, pid: nil, at: date(40))
        #expect(sessions.phase() == .working)
        sessions.observe(a, .waiting, cwd: nil, pid: nil, at: date(70))
        sessions.observe(a, .idle, cwd: nil, pid: nil, at: date(100))
        #expect(sessions.phase() == .idle)

        // Once a hook has spoken for it, only a hook ends its wait.
        sessions.observe(a, .waiting, cwd: nil, pid: nil, at: date(130))
        sessions.apply(hook("CwdChanged", at: 131, cwd: "/w/src"))
        #expect(sessions.heardFromHooks(a))
        sessions.observe(a, .busy, cwd: nil, pid: nil, at: date(160))
        #expect(sessions.phase() == .waiting(.permission))
        // And it's no longer heard from once it ends.
        sessions.apply(hook("SessionEnd", at: 170))
        #expect(!sessions.heardFromHooks(a))
    }

    @Test func waitingLeavesAQuestionAsItIs() {
        var sessions = AgentSessions(hook("PreToolUse", at: 1, tool: "ExitPlanMode"))
        sessions.observe(a, .waiting, cwd: nil, pid: nil, at: date(10))
        #expect(sessions.phase() == .waiting(.question))
        sessions = AgentSessions(hook("UserPromptSubmit", at: 1))
        sessions.observe(a, .waiting, cwd: nil, pid: nil, at: date(10))
        #expect(sessions.phase() == .waiting(.permission))
    }

    @Test func idleClearsWorkAndWaitingButLeavesAFinishedTurn() throws {
        for (start, expected) in [
            (hook("UserPromptSubmit", at: 1), AgentPhase.idle),
            (hook("PermissionRequest", at: 1), .idle),
            (hook("Stop", at: 1), .finished(failed: false)),
            (hook("StopFailure", at: 1), .finished(failed: true)),
        ] {
            var sessions = AgentSessions(start)
            sessions.observe(a, .idle, cwd: nil, pid: nil, at: date(100))
            #expect(sessions.phase() == expected)
        }
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 1))
        sessions.observe(a, .idle, cwd: nil, pid: nil, at: date(100))
        #expect(try #require(sessions.sessions[a]).phaseSince == date(100))
    }

    @Test func observingFillsInWhatTheHooksDidntSay() throws {
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 1, pid: 42, processStart: 5))
        sessions.observe(a, .busy, cwd: "/w", pid: 42, at: date(2))
        var session = try #require(sessions.sessions[a])
        #expect(session.cwd == "/w")
        #expect(session.processStart == 5)
        sessions.observe(a, .busy, cwd: "/v", pid: 50, at: date(3))
        session = try #require(sessions.sessions[a])
        #expect(session.cwd == "/w")
        #expect(session.pid == 50)
        #expect(session.processStart == nil)
    }

    @Test func observingASessionThatEndedBringsItBack() {
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 1), hook("SessionEnd", at: 10))
        sessions.observe(a, .busy, cwd: nil, pid: nil, at: date(12))
        #expect(sessions.phase() == .working)
        // An event from before the end still belongs to the session that
        // ended.
        let changed = sessions.apply(hook("Stop", at: 9))
        #expect(!changed)
        #expect(sessions.phase() == .working)
        sessions.apply(hook("Stop", at: 13))
        #expect(sessions.phase() == .finished(failed: false))
    }

    @Test func aHookEventFromAfterTheQuestionOutranksTheAnswer() throws {
        // The command ended while Roga waited for the answer, and the turn
        // with it.
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 10), hook("Stop", at: 100.3))
        sessions.observe(a, .busy, cwd: "/w", pid: 42, at: date(100))
        var session = try #require(sessions.sessions[a])
        #expect(session.phase == .finished(failed: false))
        #expect(session.phaseSince == date(100.3))
        #expect(session.lastEvent == date(100.3))
        // It still fills in what the hooks didn't say.
        #expect(session.cwd == "/w")
        #expect(session.pid == 42)

        // The person typed a prompt while Roga waited.
        sessions = AgentSessions(hook("Stop", at: 10), hook("UserPromptSubmit", at: 100.3, pid: 50, processStart: 7))
        sessions.observe(a, .idle, cwd: nil, pid: 42, at: date(100))
        session = try #require(sessions.sessions[a])
        #expect(session.phase == .working)
        #expect(session.pid == 50)
        #expect(session.processStart == 7)

        // An answer from after the last hook event still corrects it.
        sessions.observe(a, .idle, cwd: nil, pid: nil, at: date(190))
        #expect(sessions.phase() == .idle)
    }

    @Test func aSessionThatEndedWhileTheAgentWasAskedStaysEnded() {
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 10), hook("SessionEnd", at: 100.3))
        var changed = sessions.observe(a, .busy, cwd: nil, pid: 42, at: date(100))
        #expect(!changed)
        #expect(sessions.sessions.isEmpty)
        // So does one whose process Roga saw exit.
        sessions = AgentSessions(hook("UserPromptSubmit", at: 10, pid: 42, processStart: 5))
        sessions.processEnded(pid: 42)
        changed = sessions.observe(a, .busy, cwd: nil, pid: 42, at: date(200))
        #expect(!changed)
        #expect(sessions.sessions.isEmpty)
        // The same session in another process is back.
        changed = sessions.observe(a, .busy, cwd: nil, pid: 50, at: date(200))
        #expect(changed)
        #expect(sessions.phase() == .working)
    }

    @Test func observingRestartsTheQuietClock() {
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 0))
        #expect(sessions.quietWorking(for: .seconds(90), now: date(100)) == [a])
        sessions.observe(a, .busy, cwd: nil, pid: nil, at: date(100))
        #expect(sessions.quietWorking(for: .seconds(90), now: date(150)).isEmpty)
        #expect(sessions.quietWorking(for: .seconds(90), now: date(190)) == [a])
    }

    // MARK: - Quiet sessions

    @Test func quietSessionsAreTheWorkingOnesWithNoEventForAWhile() {
        let codex = SessionKey(host: .codex, id: "a")
        let sessions = AgentSessions(
            hook("UserPromptSubmit", host: .codex, at: 0),
            hook("UserPromptSubmit", at: 0),
            hook("UserPromptSubmit", session: "b", at: 0),
            hook("PostToolUse", session: "b", at: 50),
            hook("PermissionRequest", session: "c", at: 0),
            hook("Stop", session: "d", at: 0)
        )
        #expect(sessions.quietWorking(for: .seconds(90), now: date(89.5)).isEmpty)
        #expect(sessions.quietWorking(for: .seconds(90), now: date(90)) == [a, codex])
        #expect(sessions.quietWorking(for: .seconds(90), now: date(140)) == [a, b, codex])
        #expect(sessions.quietWorking(for: .milliseconds(89_500), now: date(89.5)) == [a, codex])
    }

    // MARK: - What a session is doing

    @Test func keepsTheLatestLineOfEachSession() {
        var sessions = AgentSessions(hook("UserPromptSubmit", at: 1))
        #expect(sessions.activity() == nil)
        sessions.apply(hook("PreToolUse", at: 2, tool: "Bash", activity: "Run the test suite"))
        #expect(sessions.activity() == "Run the test suite")
        // A tool that ends leaves its line until the next one starts.
        sessions.apply(hook("PostToolUse", at: 3, tool: "Bash"))
        #expect(sessions.activity() == "Run the test suite")
        // So does a tool that only keeps the task list, which has no line.
        sessions.apply(hook("PreToolUse", at: 4, tool: "TaskUpdate"))
        #expect(sessions.activity() == "Run the test suite")
        sessions.apply(hook("PreToolUse", at: 5, tool: "Read", activity: "Reading notes.txt"))
        #expect(sessions.activity() == "Reading notes.txt")
        sessions.apply(hook("PreToolUse", session: "b", at: 5, tool: "Grep", activity: "Searching the code"))
        #expect(sessions.activity(b) == "Searching the code")

        sessions.apply(hook("PermissionRequest", at: 6, tool: "Bash", activity: "git push"))
        #expect(sessions.phase() == .waiting(.permission))
        #expect(sessions.activity() == "git push")
        // A notification of the same prompt has no line, and changes nothing.
        sessions.apply(hook("Notification", at: 7, notification: "permission_prompt"))
        #expect(sessions.activity() == "git push")
        sessions.apply(hook("PostToolUse", at: 8, tool: "Bash"))
        #expect(sessions.phase() == .working)
        #expect(sessions.activity() == "git push")

        sessions.apply(hook("Stop", at: 9, activity: "Pushed the branch"))
        #expect(sessions.phase() == .finished(failed: false))
        #expect(sessions.activity() == "Pushed the branch")
        // A new turn starts with no line.
        sessions.apply(hook("UserPromptSubmit", at: 10))
        #expect(sessions.activity() == nil)
        #expect(sessions.activity(b) == "Searching the code")
    }

    @Test func aQuestionSaysWhatItAsks() {
        let sessions = AgentSessions(
            hook("UserPromptSubmit", at: 1),
            hook("PreToolUse", at: 2, tool: "ExitPlanMode", activity: "Wants a plan approved")
        )
        #expect(sessions.phase() == .waiting(.question))
        #expect(sessions.activity() == "Wants a plan approved")
    }

    @Test func aSubagentsToolsDontReplaceItsParentsLine() {
        var sessions = AgentSessions(
            hook("UserPromptSubmit", at: 1),
            hook("PreToolUse", at: 2, tool: "Agent", activity: "Subagent: Find where hooks are parsed"),
            hook("SubagentStart", at: 3, subagent: "x")
        )
        sessions.apply(hook("PreToolUse", at: 4, tool: "Read", subagent: "x", activity: "Reading HookHelper.swift"))
        sessions.apply(hook("PermissionRequest", at: 5, tool: "Bash", subagent: "x", activity: "rm"))
        sessions.apply(hook("Stop", at: 6, subagent: "x", activity: "Found it"))
        sessions.apply(hook("SubagentStop", at: 7, subagent: "x"))
        #expect(sessions.activity() == "Subagent: Find where hooks are parsed")
        // A subagent's event is still enough to show a session Roga hadn't
        // heard of as working, with nothing yet to say what it does.
        let unknown = AgentSessions(hook("PreToolUse", at: 4, tool: "Read", subagent: "x", activity: "Reading a.swift"))
        #expect(unknown.phase() == .working)
        #expect(unknown.activity() == nil)
    }

    @Test func aLateEventDoesntUndoANewerLine() {
        var sessions = AgentSessions(
            hook("UserPromptSubmit", at: 1),
            hook("PreToolUse", at: 10, tool: "Bash", activity: "Run the test suite"),
            hook("Stop", at: 20, activity: "All tests pass")
        )
        sessions.apply(hook("PreToolUse", at: 15, tool: "Read", activity: "Reading a.swift"))
        #expect(sessions.phase() == .finished(failed: false))
        #expect(sessions.activity() == "All tests pass")

        sessions.apply(hook("UserPromptSubmit", at: 30))
        sessions.apply(hook("PreToolUse", at: 32, tool: "Edit", activity: "Editing b.swift"))
        sessions.apply(hook("PreToolUse", at: 31, tool: "Read", activity: "Reading b.swift"))
        #expect(sessions.activity() == "Editing b.swift")
        // An event from long before is new, because the clock went back.
        sessions.apply(hook("PreToolUse", at: 1, tool: "Read", activity: "Reading c.swift"))
        #expect(sessions.activity() == "Reading c.swift")
    }

    @Test func whatEndsATurnSaysWhatItLeaves() {
        let tool = hook("PreToolUse", at: 2, tool: "Bash", activity: "Run the test suite")
        // A reply with no words in it has no line.
        #expect(AgentSessions(tool, hook("Stop", at: 3)).activity() == nil)
        #expect(AgentSessions(tool, hook("StopFailure", at: 3)).activity() == nil)
        let codex = SessionKey(host: .codex, id: "a")
        let codexTool = hook("PreToolUse", host: .codex, at: 2, tool: "Bash", activity: "swift test")
        #expect(AgentSessions(codexTool, hook("Interrupt", host: .codex, at: 3)).activity(codex) == nil)
        #expect(AgentSessions(tool, hook("SessionStart", at: 3, source: "clear")).activity() == nil)
        #expect(AgentSessions(tool, hook("SessionStart", at: 3, source: "compact")).activity() == "Run the test suite")
        // With background tasks still running, the reply says what it waits for.
        let waiting = AgentSessions(tool, hook("Stop", at: 3, backgroundTasks: 1, activity: "The build runs in the background"))
        #expect(waiting.phase() == .working)
        #expect(waiting.activity() == "The build runs in the background")
    }

    @Test func askingTheAgentClearsALineThatNoLongerFits() {
        var sessions = AgentSessions(
            hook("UserPromptSubmit", at: 1),
            hook("PreToolUse", at: 2, tool: "Bash", activity: "Run the test suite")
        )
        // Busy agrees with working, so the line stays.
        sessions.observe(a, .busy, cwd: nil, pid: nil, at: date(100))
        #expect(sessions.activity() == "Run the test suite")
        // After Esc, which sends nothing, the agent says it's idle.
        sessions.observe(a, .idle, cwd: nil, pid: nil, at: date(200))
        #expect(sessions.phase() == .idle)
        #expect(sessions.activity() == nil)

        var finished = AgentSessions(hook("Stop", at: 1, activity: "Done"))
        finished.observe(a, .busy, cwd: nil, pid: nil, at: date(100))
        #expect(finished.phase() == .working)
        #expect(finished.activity() == nil)
    }

    @Test func applyingSaysWhetherAnythingChanged() {
        var sessions = AgentSessions()
        let start = hook("SessionStart", at: 1, cwd: "/w")
        var changed = sessions.apply(start)
        #expect(changed)
        changed = sessions.apply(start)
        #expect(!changed)
        changed = sessions.apply(hook("UserPromptSubmit", at: 2))
        #expect(changed)
    }
}
