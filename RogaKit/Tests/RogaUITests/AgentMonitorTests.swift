import AgentEngine
import Foundation
import GitCore
import GitRunner
import Observation
import Synchronization
import Testing
@testable import AgentHooks
@testable import RogaUI

/// Hook events in, marks out: which state wins, what's been seen, which worktree
/// a session is in, and how stale sessions are cleared, by a process exiting and
/// by asking a fake `claude agents --json`.
@Suite(.timeLimit(.minutes(1)), .removesTemporaryFolders)
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
        // The second event is in the same folder and too soon to move it.
        #expect(monitor.lastHeard[.claude] == AgentProvider.Heard(date: start, cwd: "/git/api"))
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

    // MARK: What a window shows

    @Test func selectingAWorktreeSeesWhatFinishedThere() {
        let monitor = monitor()
        monitor.receive(event("Stop", "a", in: "/git/api", at: 10))
        monitor.receive(event("Stop", "b", in: "/git/api-login", at: 10))
        monitor.selected(worktree: nil)
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .finished)
        monitor.selected(worktree: "/git/api")
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)
        #expect(monitor.summary(forWorktree: "/git/api-login", in: list)?.state == .finished)
    }

    @Test func whatFinishesInTheShownWorktreeIsSeenWhileTheWindowIsInFront() {
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0))
        // Working isn't something to see.
        monitor.showing(worktree: "/git/api", appearsActive: true, in: list)
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)
        monitor.receive(event("Stop", "a", in: "/git/api", at: 60))
        monitor.showing(worktree: "/git/api", appearsActive: true, in: list)
        #expect(monitor.summary(forWorktree: "/git/api", in: list) == nil)
    }

    @Test func whatFinishedBehindIsSeenWhenTheWindowComesToTheFront() {
        let monitor = monitor()
        monitor.receive(event("Stop", "a", in: "/git/api", at: 60))
        monitor.showing(worktree: "/git/api", appearsActive: false, in: list)
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .finished)
        // Another window, in front, shows another worktree.
        monitor.showing(worktree: "/git/api-login", appearsActive: true, in: list)
        monitor.showing(worktree: nil, appearsActive: true, in: list)
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .finished)
        // The window comes to the front.
        monitor.showing(worktree: "/git/api", appearsActive: true, in: list)
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

    /// Counts the folders a monitor resolves, and notes any it resolved on
    /// the main thread, where a stalled volume would hang the app.
    private nonisolated final class Resolutions: Sendable {
        private let state = Mutex<(folders: [String], onMainThread: Int)>(([], 0))
        var folders: [String] { state.withLock { $0.folders } }
        var onMainThread: Int { state.withLock { $0.onMainThread } }

        func resolve(_ path: String) -> String {
            let isMain = Thread.isMainThread
            state.withLock { state in
                state.folders.append(path)
                if isMain { state.onMainThread += 1 }
            }
            return RepositoryList.comparablePath(path)
        }
    }

    @Test func placingMarksResolvesEachFolderOnceAwayFromTheMainThread() async {
        // Resolving a folder asks the file system about each folder in its
        // path, and every row asks where the marks are as it draws.
        let resolutions = Resolutions()
        let monitor = monitor()
        monitor.resolvePath = { resolutions.resolve($0) }
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0))
        monitor.receive(event("UserPromptSubmit", "b", in: "/git/api/src", at: 0))
        monitor.receive(event("UserPromptSubmit", "c", in: "/git/api/src", at: 0))
        // Until a folder is resolved, it compares as it's spelled, which is
        // the same for these.
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.sessions == 3)
        // The list has four worktrees, one of them where a session is, and
        // the other sessions are in one more folder.
        #expect(await AgentTestSupport.eventually { resolutions.folders.count == 5 })
        _ = monitor.summary(forWorktree: "/git/api-login", in: list)
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.sessions == 3)

        // A mark changing places the sessions again, without resolving their
        // folders again.
        monitor.receive(event("Stop", "a", in: "/git/api", at: 10))
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.sessions == 2)

        // A commit or a checkout in a worktree changes nothing placing reads.
        var changed = list.repositories[0].worktrees
        changed[1].head = ObjectID(hex: String(repeating: "a", count: 40))
        changed[2].branch = "refs/heads/other"
        let committed = RepositoryList(listing: [ListedRepository(path: "/git/api/.git", worktrees: changed)] + list.repositories.dropFirst())
        #expect(monitor.summary(forWorktree: "/git/api", in: committed)?.sessions == 2)

        // Only a worktree that's new is resolved.
        let grown = RepositoryList(listing: list.repositories + [
            ListedRepository(path: "/git/web/.git", worktrees: [Worktree(path: "/git/web", branch: "refs/heads/main", isMain: true)]),
        ])
        #expect(monitor.summary(forWorktree: "/git/api", in: grown)?.sessions == 2)
        #expect(await AgentTestSupport.eventually { resolutions.folders.count == 6 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(resolutions.folders.count == 6)
        #expect(Set(resolutions.folders).count == 6)
        #expect(resolutions.onMainThread == 0)
    }

    @Test func aFolderThatTakesLongToResolveDoesntHoldUpTheRows() async {
        // As on a network volume that has stopped answering.
        nonisolated final class Stuck: Sendable {
            let release = DispatchSemaphore(value: 0)
            let isStuck = Mutex(true)
        }
        let stuck = Stuck()
        let monitor = monitor()
        monitor.resolvePath = { path in
            if path == "/git/api/src" {
                _ = stuck.release.wait(timeout: .now() + 10)
                stuck.isStuck.withLock { $0 = false }
            }
            return RepositoryList.comparablePath(path)
        }
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api/src", at: 0))
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)
        #expect(stuck.isStuck.withLock { $0 })
        stuck.release.signal()
        #expect(await AgentTestSupport.eventually { !stuck.isStuck.withLock { $0 } })
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)
    }

    @Test func aFolderSpelledThroughALinkFindsItsWorktreeOnceResolved() async throws {
        nonisolated final class Changes: @unchecked Sendable { var count = 0 }
        let folder = try AgentTestSupport.folder()
        try FileManager.default.createDirectory(atPath: folder + "/api/src", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder + "/shortcut", withDestinationPath: folder + "/api")
        let list = RepositoryList(listing: [
            ListedRepository(path: folder + "/api/.git", worktrees: [Worktree(path: folder + "/api", branch: "refs/heads/main", isMain: true)]),
        ])
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", in: folder + "/shortcut/src", at: 0))
        // The row that asks first is told again once the folder is resolved.
        let changes = Changes()
        withObservationTracking {
            _ = monitor.summary(forWorktree: folder + "/api", in: list)
        } onChange: {
            changes.count += 1
        }
        #expect(await AgentTestSupport.eventually { changes.count > 0 })
        #expect(monitor.summary(forWorktree: folder + "/api", in: list)?.state == .working)
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
        // The child lives until the test stops it, rather than for a set time,
        // so a busy machine can't end it before the test has read its start.
        let child = Task {
            try await programs.run(ProgramCommand("/bin/sh", ["-c", "echo $$ > '\(pidFile)'; exec /bin/sleep 60"]))
        }
        #expect(await AgentTestSupport.eventually { FileManager.default.contents(atPath: pidFile).map { !$0.isEmpty } ?? false })
        let text = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(text))
        let processStart = try #require(AgentProcess.startTime(of: pid))

        let monitor = monitor()
        defer { monitor.stop() }
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0, pid: pid, processStart: processStart))
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)
        #expect(kill(pid, SIGTERM) == 0)
        _ = await child.result
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
        // The events are further apart than `heardRefreshInterval`, so that
        // each one moves it.
        monitor.receive(event("PreToolUse", "a", host: .codex, in: "/private/tmp/build", at: 40))
        #expect(monitor.lastHeard[.codex] == AgentProvider.Heard(date: start.addingTimeInterval(40), cwd: "/git/api"))
        // An event that arrives late doesn't move it back.
        monitor.receive(event("PostToolUse", "a", host: .codex, in: "/private/tmp/build", at: 3))
        #expect(monitor.lastHeard[.codex] == AgentProvider.Heard(date: start.addingTimeInterval(40), cwd: "/git/api"))
        // A session's end still says where it was.
        monitor.receive(event("SessionEnd", "a", host: .codex, at: 80))
        #expect(monitor.lastHeard[.codex] == AgentProvider.Heard(date: start.addingTimeInterval(80), cwd: "/git/api"))
        // Nor does a session Roga hasn't heard where it is, which isn't
        // where the last one was.
        monitor.receive(event("PreToolUse", "b", host: .codex, in: "/private/tmp/build", at: 85))
        #expect(monitor.lastHeard[.codex] == AgentProvider.Heard(date: start.addingTimeInterval(85), cwd: nil))
        #expect(monitor.lastHeard[.claude] == nil)
    }

    @Test func lastHeardChangesWithTheFolderOrOnceItsHalfAMinuteOld() {
        let monitor = monitor()
        monitor.receive(event("UserPromptSubmit", "a", in: "/git/api", at: 0))
        // Each tool the agent runs in the same folder within half a minute
        // leaves it alone, so Settings doesn't redraw for each one.
        let changes = Mutex(0)
        func watch() {
            withObservationTracking { _ = monitor.lastHeard } onChange: { changes.withLock { $0 += 1 } }
        }
        watch()
        for second in stride(from: 1.0, to: 29.0, by: 0.5) {
            monitor.receive(event(second.truncatingRemainder(dividingBy: 1) == 0 ? "PreToolUse" : "PostToolUse", "a", in: "/git/api", at: second, tool: "Bash"))
        }
        #expect(changes.withLock { $0 } == 0)
        #expect(monitor.lastHeard[.claude] == AgentProvider.Heard(date: start, cwd: "/git/api"))
        // What it shows is behind, but a late event is still told apart from
        // the latest one: this one from another folder, sent before the last
        // tool, doesn't move it there.
        monitor.receive(event("UserPromptSubmit", "late", in: "/git/api-login", at: 15))
        #expect(changes.withLock { $0 } == 0)
        #expect(monitor.lastHeard[.claude] == AgentProvider.Heard(date: start, cwd: "/git/api"))
        // Half a minute after what it shows, the next event moves it.
        monitor.receive(event("PreToolUse", "a", in: "/git/api", at: 30, tool: "Bash"))
        #expect(changes.withLock { $0 } == 1)
        #expect(monitor.lastHeard[.claude] == AgentProvider.Heard(date: start.addingTimeInterval(30), cwd: "/git/api"))
        // Another folder moves it at once.
        watch()
        monitor.receive(event("UserPromptSubmit", "b", in: "/git/api-login", at: 31))
        #expect(changes.withLock { $0 } == 2)
        #expect(monitor.lastHeard[.claude] == AgentProvider.Heard(date: start.addingTimeInterval(31), cwd: "/git/api-login"))
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

    /// What `claude agents --json` says about one session, "old", in
    /// /git/api, whose process is the tests' own, so that it stays alive.
    private func listing(_ status: String) -> String {
        let me = ProcessInfo.processInfo.processIdentifier
        return #"[{"pid":\#(me),"sessionId":"old","status":"\#(status)","cwd":"/git/api","kind":"interactive"}]"#
    }

    @Test func aWaitThatOnlyClaudeCodeShowedEndsWhenItSaysSo() async throws {
        // The session was running before the hooks were installed, so it
        // never loads them, and no hook event will end its wait.
        let (provider, log, folder) = try provider(listing: listing("waiting"), hooks: .notInstalled)
        let sessions = folder + "/sessions.json"
        let monitor = listeningMonitor(in: folder, checkInterval: .milliseconds(50))
        monitor.start(agents: provider)
        defer { monitor.stop() }
        // Install… in Settings: the hooks read installed, and Roga asks
        // what's running.
        provider.setStateForTests(hookStatus: [.claude: .installed])
        #expect(await AgentTestSupport.eventually { monitor.summary(forWorktree: "/git/api", in: list)?.state == .waiting(.permission) })
        // The person allows the tool, and the turn ends.
        try listing("idle").write(toFile: sessions, atomically: true, encoding: .utf8)
        #expect(await AgentTestSupport.eventually { monitor.summary(forWorktree: "/git/api", in: list) == nil })

        // Busy when asked, and waiting once it has been quiet a while: the
        // wait that the quiet check shows ends when Claude Code says busy.
        try listing("busy").write(toFile: sessions, atomically: true, encoding: .utf8)
        await monitor.askClaude(always: true)
        #expect(monitor.summary(forWorktree: "/git/api", in: list)?.state == .working)
        try listing("waiting").write(toFile: sessions, atomically: true, encoding: .utf8)
        monitor.now = { [start] in start.addingTimeInterval(600 + 91) }
        #expect(await AgentTestSupport.eventually { monitor.summary(forWorktree: "/git/api", in: list)?.state == .waiting(.permission) })
        try listing("busy").write(toFile: sessions, atomically: true, encoding: .utf8)
        #expect(await AgentTestSupport.eventually { monitor.summary(forWorktree: "/git/api", in: list)?.state == .working })

        // Once Claude Code no longer lists it, nothing can keep it current.
        try "[]".write(toFile: sessions, atomically: true, encoding: .utf8)
        monitor.now = { [start] in start.addingTimeInterval(600 + 91 + 91) }
        #expect(await AgentTestSupport.eventually { monitor.summary(forWorktree: "/git/api", in: list) == nil })
        #expect(askedForSessions(log) > 4)
    }

    @Test func aWaitAHookShowedIsLeftToTheHooks() async throws {
        let (provider, log, folder) = try provider(listing: listing("idle"))
        let monitor = listeningMonitor(in: folder, checkInterval: .milliseconds(50))
        monitor.start(agents: provider)
        defer { monitor.stop() }
        #expect(await AgentTestSupport.eventually { monitor.sessions[SessionKey(host: .claude, id: "old")] != nil })
        // Its hooks speak for it, so they'll say when the wait is over.
        monitor.receive(event("PermissionRequest", "old", in: "/git/api", at: 601))
        try await Task.sleep(for: .milliseconds(300))
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
        // asks once more, once the monitor has seen Claude Code go.
        let found = provider.lookups
        provider.setStateForTests(lookups: [:], hookStatus: [:])
        #expect(await AgentTestSupport.eventually { !monitor.couldSeed })
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

    @Test func aStoppedMonitorLetsGoAndCanStartAgain() async throws {
        let folder = try AgentTestSupport.folder()
        let (defaults, _) = AgentTestSupport.defaults()
        let provider = AgentTestSupport.provider(support: folder, defaults: defaults, codexHome: folder)
        let support = URL(filePath: folder, directoryHint: .isDirectory)
        let monitor = AgentMonitor(supportFolder: support, checkInterval: .seconds(600))
        monitor.start(agents: provider)
        #expect(monitor.listening == .listening)
        #expect(monitor.isWatchingForTermination)

        monitor.stop()
        #expect(monitor.listening == .starting)
        #expect(!monitor.isWatchingForTermination)
        // Its socket is free for another copy of Roga. A process that other
        // tests start can hold the lock's file for a moment as it starts, so
        // each start tries again until it listens, as Try Again does.
        let other = AgentMonitor(supportFolder: support, checkInterval: nil)
        #expect(await AgentTestSupport.eventually {
            other.start(agents: provider)
            return other.listening == .listening
        })
        other.stop()

        defer { monitor.stop() }
        #expect(await AgentTestSupport.eventually {
            monitor.start(agents: provider)
            return monitor.listening == .listening
        })
        #expect(monitor.isWatchingForTermination)
        let socket = HookSocket.path(supportFolder: support)
        #expect(HookHelper.send(event("UserPromptSubmit", "a", in: "/git/api", at: 0), toSocketAt: socket))
        #expect(await AgentTestSupport.eventually { monitor.sessions.count == 1 })
    }

    @Test func aMonitorThatNobodyHoldsGoesAwayBetweenChecks() async throws {
        // Claude Code is found with its hooks, so the monitor asks what's
        // running as it starts, and then waits to check quiet sessions.
        let (provider, log, folder) = try provider(listing: "[]")
        var monitor: AgentMonitor? = listeningMonitor(in: folder, checkInterval: .seconds(600))
        monitor?.start(agents: provider)
        weak var gone = monitor
        #expect(await AgentTestSupport.eventually { askedForSessions(log) == 1 })
        monitor = nil
        #expect(await AgentTestSupport.eventually { gone == nil })

        // It let go of its socket, so another monitor can listen there. The
        // weak reference reads nil a moment before the monitor's deinit has
        // run on the main actor, and a process that other tests start holds
        // the lock's file for a moment as it starts, so the next monitor
        // tries again, as Try Again in Settings does.
        let next = listeningMonitor(in: folder)
        defer { next.stop() }
        #expect(await AgentTestSupport.eventually {
            next.start(agents: provider)
            return next.listening == .listening
        })
    }
}
