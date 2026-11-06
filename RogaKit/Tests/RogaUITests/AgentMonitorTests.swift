import AgentEngine
import Foundation
import GitCore
import GitRunner
import Observation
import Testing
@testable import AgentHooks
@testable import RogaUI

/// Hook events in, marks out: which state wins, what's been seen, which worktree
/// a session is in, and how stale sessions are cleared, by a process exiting and
/// by asking a fake `claude agents --json`.
@Suite(.timeLimit(.minutes(1)))
struct AgentMonitorTests {
    /// A repository at /git/api with a linked worktree of its own and one that
    /// Claude Code made inside the main checkout, and another repository whose
    /// folder starts the same way.
    let list = RepositoryList(listing: [
        ListedRepository(path: "/git/api/.git", worktrees: [
            Worktree(path: "/git/api", branch: "refs/heads/main", isMain: true),
            Worktree(path: "/git/api-login", branch: "refs/heads/login"),
            Worktree(path: "/git/api/.claude/worktrees/fix", branch: "refs/heads/fix"),
        ]),
        ListedRepository(path: "/git/api-old/.git", worktrees: [
            Worktree(path: "/git/api-old", branch: "refs/heads/main", isMain: true),
        ]),
    ])
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func monitor() -> AgentMonitor {
        let monitor = AgentMonitor(supportFolder: URL(filePath: "/nonexistent"), checkInterval: nil)
        monitor.now = { [start] in start.addingTimeInterval(600) }
        return monitor
    }

    private func event(_ name: String, _ session: String, host: AgentHost = .claude, in cwd: String? = nil, at seconds: Double, tool: String? = nil, pid: Int32? = nil, processStart: Double? = nil) -> HookEvent {
        HookEvent(host: host, event: name, session: session, cwd: cwd, pid: pid, processStart: processStart, tool: tool, time: start.timeIntervalSince1970 + seconds)
    }

    // MARK: Which state wins

    @Test func aSessionThatsWorkingShowsTheRing() {
        let monitor = monitor()
        monitor.receive(event("SessionStart", "a", in: "/git/api", at: 0))
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 10))
        let summary = monitor.summary(forWorktree: "/git/api", in: list)
        #expect(summary == AgentSummary(state: .working, since: start.addingTimeInterval(10), hosts: [.claude], sessions: 1))
        #expect(summary?.description == "Claude Code is working")
        #expect(monitor.lastHeard[.claude] == AgentProvider.Heard(date: start.addingTimeInterval(10), cwd: "/git/api"))
    }

    @Test func waitingBeatsWorkingAndWorkingBeatsFinished() {
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0))
        monitor.receive(event("Stop", "a", in: "/git/api", at: 5))
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .finished)
        monitor.receive(event("UserPromptSubmit", "b", host: .codex, in: "/git/api", at: 10))
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)
        monitor.receive(event("UserPromptSubmit", "c", in: "/git/api", at: 20))
        monitor.receive(event("PermissionRequest", "c", in: "/git/api", at: 30))
        let summary = monitor.summary(forWorktree: "/git/api", in: list)
        #expect(summary?.state == .waiting(.permission))
        #expect(summary?.description == "Claude Code is waiting for you to allow a tool")
        monitor.receive(event("SessionEnd", "c", in: "/git/api", at: 40))
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.description == "Codex is working")
    }

    @Test func severalSessionsCountAndTheLongestSaysHowLong() {
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", host: .codex, in: "/git/api", at: 100))
        monitor.receive(event("UserPromptSubmit", "b", in: "/git/api/src", at: 40))
        let summary = monitor.summary(forWorktree: "/git/api", in: list)
        #expect(summary == AgentSummary(state: .working, since: start.addingTimeInterval(40), hosts: [.claude, .codex], sessions: 2))
        #expect(summary?.description == "2 agents are working")
        #expect(summary?.menuDetail(now: start.addingTimeInterval(400)) == "2 agents working · 6 min")
    }

    @Test func aQuestionIsWaitingForAnAnswer() {
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0))
        monitor.receive(event("PreToolUse", "a", in: "/git/api", at: 1, tool: "AskUserQuestion"))
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.description == "Claude Code is waiting for your answer")
    }

    @Test func anIdleSessionHasNoMark() {
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", host: .codex, in: "/git/api", at: 0))
        monitor.receive(event("Interrupt", "a", host: .codex, in: "/git/api", at: 1))
        #expect(monitor.sessions.count == 1)
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)
    }

    // MARK: Seen

    @Test func whatFinishedShowsUntilSomeoneLooks() {
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0))
        monitor.receive(event("Stop", "a", in: "/git/api", at: 60))
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.description == "Claude Code finished")
        monitor.markSeen(worktree: "/git/api")
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)
        // Looking doesn't hide what's still going on, or what finishes next.
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 700))
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)
        monitor.receive(event("Stop", "a", in: "/git/api", at: 760))
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .finished)
    }

    @Test func lookingAtOneWorktreeLeavesTheOthers() {
        let monitor = monitor()
        monitor.receive(event("Stop", "a", in: "/git/api", at: 10))
        monitor.receive(event("Stop", "b", in: "/git/api-login", at: 10))
        monitor.markSeen(worktree: "/git/api")
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)
        #expect(monitor.summary(forWorktree: "/git/api-login", in: list)?.state == .finished)
    }

    @Test func lookingWhereNoDotWouldGoRedrawsNothing() {
        // Every row with a mark reads what's been seen, and a worktree is
        // looked at each time it's selected.
        nonisolated final class Changes: @unchecked Sendable { var count = 0 }
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0))
        monitor.receive(event("Stop", "b", in: "/git/api-login", at: 0))
        monitor.markSeen(worktree: "/git/api-login")
        let changes = Changes()
        withObservationTracking {
            _ = monitor.summary(forWorktree: "/git/api", in: list)
            _ = monitor.summary(forWorktree: "/git/api-login", in: list)
        } onChange: {
            changes.count += 1
        }
        monitor.markSeen(worktree: "/git/api")
        monitor.markSeen(worktree: "/git/api-login")
        monitor.markSeen(worktree: "/git/api-old")
        #expect(changes.count == 0)

        // Once something has finished there, looking takes its dot away.
        monitor.receive(event("Stop", "a", in: "/git/api", at: 10))
        let looked = Changes()
        withObservationTracking {
            _ = monitor.summary(forWorktree: "/git/api", in: list)
        } onChange: {
            looked.count += 1
        }
        monitor.markSeen(worktree: "/git/api")
        #expect(looked.count == 1)
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)
    }

    // MARK: Which worktree

    @Test func theDeepestWorktreeHoldsTheSession() {
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api/.claude/worktrees/fix/Sources", at: 0))
        #expect(monitor.summary(forWorktree: "/git/api/.claude/worktrees/fix", in: list)?.state == .working)
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)
    }

    @Test func aFolderThatOnlyStartsTheSameIsntInside() {
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api-old/src", at: 0))
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)
        #expect(monitor.summary(forWorktree: "/git/api-old", in: list)?.state == .working)
    }

    @Test func aSessionOutsideTheSidebarHasNoMark() {
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", in: "/Users/someone/scratch", at: 0))
        monitor.receive(event("UserPromptSubmit", "b", at: 0))
        #expect(monitor.sessions.count == 2)
        for worktree in list.repositories.flatMap(\.worktrees) {
            #expect(monitor.summary(forWorktree: worktree.path, in: list) == nil)
        }
    }

    @Test func theRowForHiddenWorktreesShowsTheMostUrgent() {
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api-login", at: 0))
        // Codex's PermissionRequest names the command's folder rather than the
        // session's, so the session's comes from its prompt.
        monitor.receive(event("UserPromptSubmit", "b", host: .codex, in: "/git/api/.claude/worktrees/fix", at: 4))
        monitor.receive(event("PermissionRequest", "b", host: .codex, in: "/tmp", at: 5))
        monitor.receive(event("UserPromptSubmit", "c", in: "/git/api", at: 0))
        monitor.receive(event("PermissionRequest", "c", in: "/git/api", at: 1))
        let hidden = monitor.summary(forWorktrees: ["/git/api-login", "/git/api/.claude/worktrees/fix"], in: list)
        #expect(hidden == AgentSummary(state: .waiting(.permission), since: start.addingTimeInterval(5), hosts: [.codex], sessions: 1))
        #expect(monitor.summary(forWorktrees: [], in: list) == nil)
    }

    @Test func aWorktreeAddedLaterGetsItsSessions() {
        let monitor = monitor()
        let repository = ListedRepository(path: "/git/web/.git", worktrees: [Worktree(path: "/git/web", isMain: true)])
        let list = RepositoryList(listing: [repository])
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/web-docs", at: 0))
        #expect(monitor.summary(forWorktree: "/git/web-docs", in: list) == nil)
        let grown = RepositoryList(listing: [ListedRepository(path: "/git/web/.git", worktrees: [Worktree(path: "/git/web", isMain: true), Worktree(path: "/git/web-docs")])])
        #expect(monitor.summary(forWorktree: "/git/web-docs", in: grown)?.state == .working)
    }

    // MARK: Words

    @Test func theWorktreeMenuSaysHowLongFromAMinuteOn() {
        let working = AgentSummary(state: .working, since: start, hosts: [.claude], sessions: 1)
        #expect(working.menuDetail(now: start.addingTimeInterval(59)) == "Agent working")
        #expect(working.menuDetail(now: start.addingTimeInterval(6 * 60 + 5)) == "Agent working · 6 min")
        #expect(working.menuDetail(now: start.addingTimeInterval(65 * 60)) == "Agent working · 1 hr 5 min")
        #expect(working.help(now: start.addingTimeInterval(30)) == "Claude Code is working")
        #expect(working.help(now: start.addingTimeInterval(6 * 60)) == "Claude Code is working, for 6 minutes")
        #expect(working.help(now: start.addingTimeInterval(60)) == "Claude Code is working, for 1 minute")
        let waiting = AgentSummary(state: .waiting(.question), since: start, hosts: [.codex], sessions: 1)
        #expect(waiting.menuDetail(now: start.addingTimeInterval(120)) == "Agent waiting for you · 2 min")
        let several = AgentSummary(state: .waiting(.permission), since: start, hosts: [.claude, .codex], sessions: 2)
        #expect(several.description == "2 agents are waiting for you")
        let finished = AgentSummary(state: .finished, since: start, hosts: [.codex], sessions: 1)
        #expect(finished.menuDetail(now: start.addingTimeInterval(3600)) == "Agent finished")
        #expect(finished.help(now: start.addingTimeInterval(3600)) == "Codex finished")
        #expect(AgentSummary(state: .finished, since: start, hosts: [.claude], sessions: 3).description == "3 agents finished")
    }

    // MARK: Processes

    @Test func aSessionEndsWhenItsProcessExits() async throws {
        let folder = try AgentTestSupport.folder()
        let pidFile = folder + "/pid"
        let programs = Programs(searchPath: "/usr/bin:/bin")
        let child = Task {
            try await programs.run(ProgramCommand("/bin/sh", ["-c", "echo $$ > '\(pidFile)'; exec /bin/sleep 1"]))
        }
        #expect(await AgentTestSupport.eventually { FileManager.default.contents(atPath: pidFile).map { !$0.isEmpty } ?? false })
        let text = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(text))
        let processStart = try #require(AgentProcess.startTime(of: pid))

        let monitor = monitor()
        defer { monitor.stop() }
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0, pid: pid, processStart: processStart))
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)
        _ = try await child.value
        #expect(await AgentTestSupport.eventually { monitor.sessions.isEmpty })
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)

        // A session whose process is already gone when Roga hears of it ends
        // at once.
        monitor.receive(event("UserPromptSubmit", "b", in: "/git/api", at: 5, pid: pid, processStart: processStart))
        #expect(monitor.sessions.isEmpty)
    }

    @Test func aProcessIDThatNowBelongsToAnotherProcessEndsTheSession() throws {
        let monitor = monitor()
        defer { monitor.stop() }
        let me = ProcessInfo.processInfo.processIdentifier
        let myStart = try #require(AgentProcess.startTime(of: me))
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0, pid: me, processStart: myStart - 1000))
        #expect(monitor.sessions.isEmpty)
        // The test's own process is alive, so its session stays.
        monitor.receive(event("UserPromptSubmit", "b", in: "/git/api", at: 0, pid: me, processStart: myStart))
        #expect(monitor.sessions.count == 1)
    }

    // MARK: Last heard

    @Test func lastHeardNamesTheSessionsFolderRatherThanACommands() {
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", host: .codex, in: "/git/api", at: 0))
        // Since Codex 0.166, its tool events name the folder the command runs
        // in, which isn't where the session is.
        monitor.receive(event("PreToolUse", "a", host: .codex, in: "/private/tmp/build", at: 5))
        #expect(monitor.lastHeard[.codex] == AgentProvider.Heard(date: start.addingTimeInterval(5), cwd: "/git/api"))
        // An event that arrives late doesn't move it back.
        monitor.receive(event("PostToolUse", "a", host: .codex, in: "/private/tmp/build", at: 3))
        #expect(monitor.lastHeard[.codex] == AgentProvider.Heard(date: start.addingTimeInterval(5), cwd: "/git/api"))
        // A session's end still says where it was.
        monitor.receive(event("SessionEnd", "a", host: .codex, at: 8))
        #expect(monitor.lastHeard[.codex] == AgentProvider.Heard(date: start.addingTimeInterval(8), cwd: "/git/api"))
        // Nor does a session Roga hasn't heard where it is, which isn't
        // where the last one was.
        monitor.receive(event("PreToolUse", "b", host: .codex, in: "/private/tmp/build", at: 10))
        #expect(monitor.lastHeard[.codex] == AgentProvider.Heard(date: start.addingTimeInterval(10), cwd: nil))
        #expect(monitor.lastHeard[.claude] == nil)
    }

    // MARK: Asking Claude Code

    /// A provider that has found a fake Claude Code, which lists the sessions
    /// in `sessions` and records every run in `log`, with its hooks in the
    /// state `hooks`. `body` runs before the fake answers, as in
    /// `AgentTestSupport.claude`. The folder holds Roga's support folder,
    /// `support`.
    private func provider(listing sessions: String, delay: Double = 0, hooks: HookStatus? = .installed, body: String = "") throws -> (AgentProvider, log: String, folder: String) {
        let folder = try AgentTestSupport.folder()
        let log = folder + "/runs.log"
        let listing = folder + "/sessions.json"
        try sessions.write(toFile: listing, atomically: true, encoding: .utf8)
        let claude = try AgentTestSupport.claude(in: folder, log: log, sessions: listing, delay: delay, body: body)
        let (defaults, _) = AgentTestSupport.defaults()
        let provider = AgentTestSupport.provider(support: folder + "/support", defaults: defaults, codexHome: folder + "/codex")
        let installation = AgentInstallation(kind: .claude, executable: claude, version: AgentVersion(major: 2, minor: 1, patch: 290))
        provider.setStateForTests(
            lookups: [.claude: .found(installation), .codex: .notFound],
            hookStatus: hooks.map { [.claude: $0] } ?? [:],
            programs: Programs(searchPath: folder)
        )
        return (provider, log, folder)
    }

    /// A monitor that listens in the support folder inside `folder`, since
    /// it asks Claude Code nothing while it can't hear the hooks.
    private func listeningMonitor(in folder: String, checkInterval: Duration? = nil) -> AgentMonitor {
        let monitor = AgentMonitor(supportFolder: URL(filePath: folder + "/support", directoryHint: .isDirectory), checkInterval: checkInterval)
        monitor.now = { [start] in start.addingTimeInterval(600) }
        return monitor
    }

    private func askedForSessions(_ log: String) -> Int {
        AgentTestSupport.runs(in: log).filter { $0 == ["agents", "--json"] }.count
    }

    @Test func aQuietWorkingSessionAsksClaudeCode() async throws {
        let (provider, log, folder) = try provider(listing: #"[{"sessionId":"a","status":"idle","cwd":"/git/api","kind":"interactive"}]"#)
        let monitor = listeningMonitor(in: folder)
        monitor.start(agents: provider)
        defer { monitor.stop() }
        // Pressing Esc sends nothing, so the session goes on showing working.
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0))
        monitor.now = { [start] in start.addingTimeInterval(60) }
        await monitor.askClaude()
        #expect(askedForSessions(log) == 0)
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)

        monitor.now = { [start] in start.addingTimeInterval(91) }
        await monitor.askClaude()
        #expect(askedForSessions(log) == 1)
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)
        #expect(monitor.sessions[SessionKey(host: .claude, id: "a")]?.phase == .idle)
    }

    @Test func aQuietCodexSessionDoesntAskClaudeCode() async throws {
        let (provider, log, folder) = try provider(listing: "[]")
        let monitor = listeningMonitor(in: folder)
        monitor.start(agents: provider)
        defer { monitor.stop() }
        monitor.receive(event("UserPromptSubmit", "a", host: .codex, in: "/git/api", at: 0))
        monitor.now = { [start] in start.addingTimeInterval(91) }
        await monitor.askClaude()
        #expect(askedForSessions(log) == 0)
    }

    @Test func aQuietSessionClaudeCodeDoesntListIsAskedAboutOnce() async throws {
        // Such as a claude -p that another tool runs: it's working, and its
        // process exiting ends it.
        let (provider, log, folder) = try provider(listing: "[]")
        let monitor = listeningMonitor(in: folder)
        monitor.start(agents: provider)
        defer { monitor.stop() }
        let me = ProcessInfo.processInfo.processIdentifier
        let myStart = try #require(AgentProcess.startTime(of: me))
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0, pid: me, processStart: myStart))
        for seconds in [91.0, 121, 151, 181] {
            monitor.now = { [start] in start.addingTimeInterval(seconds) }
            await monitor.askClaude()
        }
        #expect(askedForSessions(log) == 1)
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)

        // Its next event starts another quiet stretch, which Roga asks about.
        monitor.receive(event("PostToolUse", "a", in: "/git/api", at: 200, pid: me, processStart: myStart))
        monitor.now = { [start] in start.addingTimeInterval(291) }
        await monitor.askClaude()
        #expect(askedForSessions(log) == 2)
    }

    @Test func aQuietSessionWithNoProcessThatClaudeCodeDoesntListGoesIdle() async throws {
        let (provider, log, folder) = try provider(listing: "[]")
        let monitor = listeningMonitor(in: folder)
        monitor.start(agents: provider)
        defer { monitor.stop() }
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0))
        monitor.now = { [start] in start.addingTimeInterval(91) }
        await monitor.askClaude()
        #expect(askedForSessions(log) == 1)
        #expect(monitor.sessions[SessionKey(host: .claude, id: "a")]?.phase == .idle)
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)

        // When it was working after all, its next event says so.
        monitor.receive(event("PreToolUse", "a", in: "/git/api", at: 100))
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)
    }

    @Test func aStatusRogaDoesntKnowIsAskedAboutOnce() async throws {
        let (provider, log, folder) = try provider(listing: #"[{"sessionId":"a","status":"compacting","cwd":"/git/api"}]"#)
        let monitor = listeningMonitor(in: folder)
        monitor.start(agents: provider)
        defer { monitor.stop() }
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0))
        for seconds in [91.0, 121, 151] {
            monitor.now = { [start] in start.addingTimeInterval(seconds) }
            await monitor.askClaude()
        }
        #expect(askedForSessions(log) == 1)
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)
    }

    @Test func askingAtLaunchFindsSessionsRogaMissed() async throws {
        let (provider, log, folder) = try provider(listing: """
            [{"sessionId":"a","status":"busy","cwd":"/git/api-login","kind":"interactive"},
             {"sessionId":"b","status":"waiting","waitingFor":"permission","cwd":"/git/api"},
             {"sessionId":"c","status":"idle","cwd":"/git/api-old"},
             {"status":"busy","cwd":"/git/api-old"}]
            """)
        let monitor = listeningMonitor(in: folder)
        monitor.start(agents: provider)
        defer { monitor.stop() }
        await monitor.askClaude(always: true)
        #expect(askedForSessions(log) == 1)
        #expect(monitor.summary(forWorktree: "/git/api-login", in: list)?.state == .working)
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .waiting(.permission))
        #expect(monitor.summary(forWorktree: "/git/api-old", in: list) == nil)
        #expect(monitor.sessions.count == 3)
    }

    @Test func askingAtLaunchWaitsForClaudeCodesHooks() async throws {
        // Without them, nothing would end a wait that the answer showed.
        let waiting = #"[{"sessionId":"b","status":"waiting","waitingFor":"permission","cwd":"/git/api"}]"#
        let (provider, log, folder) = try provider(listing: waiting, hooks: .notInstalled)
        let monitor = listeningMonitor(in: folder)
        monitor.start(agents: provider)
        defer { monitor.stop() }
        await monitor.askClaude(always: true)
        provider.setStateForTests(hookStatus: [.claude: .disabled])
        await monitor.askClaude(always: true)
        #expect(askedForSessions(log) == 0)
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)

        provider.setStateForTests(hookStatus: [.claude: .installed])
        await monitor.askClaude(always: true)
        #expect(askedForSessions(log) == 1)
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .waiting(.permission))
    }

    @Test func nothingIsAskedWhileRogaCantHearTheHooks() async throws {
        let waiting = #"[{"sessionId":"b","status":"waiting","waitingFor":"permission","cwd":"/git/api"}]"#
        let (provider, log, folder) = try provider(listing: waiting)
        // Another copy of Roga with the same bundle ID has the socket.
        let other = try HookListener(supportFolder: URL(filePath: folder + "/support", directoryHint: .isDirectory))
        defer { other.stop() }
        let monitor = listeningMonitor(in: folder)
        monitor.start(agents: provider)
        defer { monitor.stop() }
        #expect(monitor.listening == .anotherCopy)
        await monitor.askClaude(always: true)
        #expect(askedForSessions(log) == 0)
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)

        // Nor when the socket couldn't be opened at all.
        let failed = AgentMonitor(supportFolder: URL(filePath: "/nonexistent"), checkInterval: nil)
        failed.start(agents: provider)
        defer { failed.stop() }
        #expect(failed.listening != .listening && failed.listening != .anotherCopy)
        await failed.askClaude(always: true)
        #expect(askedForSessions(log) == 0)
    }

    @Test func theFirstQuestionWaitsUntilClaudeCodeIsFound() async throws {
        let (provider, log, folder) = try provider(listing: #"[{"sessionId":"a","status":"busy","cwd":"/git/api"}]"#)
        let found = provider.lookups
        provider.setStateForTests(lookups: [:])
        let monitor = listeningMonitor(in: folder, checkInterval: .milliseconds(50))
        monitor.start(agents: provider)
        defer { monitor.stop() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(askedForSessions(log) == 0)

        provider.setStateForTests(lookups: found)
        #expect(await AgentTestSupport.eventually { askedForSessions(log) == 1 })
        #expect(await AgentTestSupport.eventually { monitor.summary(forWorktree: "/git/api", in: list)?.state == .working })
        // After that, it asks only about quiet sessions.
        try await Task.sleep(for: .milliseconds(300))
        #expect(askedForSessions(log) == 1)
    }

    @Test func aFirstQuestionThatFailsWaitsUntilClaudeCodeIsFoundAgain() async throws {
        let (provider, log, folder) = try provider(listing: "[]", body: #"if [ "$1" = "agents" ]; then exit 1; fi"#)
        let monitor = listeningMonitor(in: folder, checkInterval: .milliseconds(50))
        monitor.start(agents: provider)
        defer { monitor.stop() }
        #expect(await AgentTestSupport.eventually { askedForSessions(log) == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(askedForSessions(log) == 1)

        // Look Again, which looks for Claude Code and checks its hooks again,
        // asks once more.
        let found = provider.lookups
        provider.setStateForTests(lookups: [:], hookStatus: [:])
        try await Task.sleep(for: .milliseconds(100))
        provider.setStateForTests(lookups: found, hookStatus: [.claude: .installed])
        #expect(await AgentTestSupport.eventually { askedForSessions(log) == 2 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(askedForSessions(log) == 2)
    }

    @Test func onlyOneQuestionAtATime() async throws {
        let (provider, log, folder) = try provider(listing: "[]", delay: 0.3)
        let monitor = listeningMonitor(in: folder)
        monitor.start(agents: provider)
        defer { monitor.stop() }
        async let first: Void = monitor.askClaude(always: true)
        async let second: Void = monitor.askClaude(always: true)
        _ = await (first, second)
        #expect(askedForSessions(log) == 1)
    }

    @Test func withoutClaudeCodeThereIsNoOneToAsk() async throws {
        let (defaults, _) = AgentTestSupport.defaults()
        let folder = try AgentTestSupport.folder()
        let provider = AgentTestSupport.provider(support: folder + "/support", defaults: defaults, codexHome: folder)
        provider.setStateForTests(lookups: [.claude: .notFound, .codex: .notFound], programs: Programs(searchPath: folder))
        let monitor = listeningMonitor(in: folder)
        monitor.start(agents: provider)
        defer { monitor.stop() }
        #expect(monitor.listening == .listening)
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0))
        monitor.now = { [start] in start.addingTimeInterval(91) }
        await monitor.askClaude(always: true)
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)
    }

    // MARK: Listening

    @Test func hearsEventsOnItsSocket() async throws {
        let folder = try AgentTestSupport.folder()
        let (defaults, _) = AgentTestSupport.defaults()
        let provider = AgentTestSupport.provider(support: folder, defaults: defaults, codexHome: folder)
        let monitor = AgentMonitor(supportFolder: URL(filePath: folder, directoryHint: .isDirectory), checkInterval: nil)
        monitor.start(agents: provider)
        defer { monitor.stop() }
        #expect(monitor.listening == .listening)

        let sent = event("UserPromptSubmit", "a", in: "/git/api", at: 0)
        let socket = HookSocket.path(supportFolder: URL(filePath: folder, directoryHint: .isDirectory))
        #expect(HookHelper.send(sent, toSocketAt: socket))
        #expect(await AgentTestSupport.eventually { monitor.sessions.count == 1 })
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)

        // A second copy of Roga with the same bundle ID can't listen too.
        let other = AgentMonitor(supportFolder: URL(filePath: folder, directoryHint: .isDirectory), checkInterval: nil)
        other.start(agents: provider)
        #expect(other.listening == .anotherCopy)
        other.stop()
    }
}
