import AppKit
import GitCore
@testable import MenuUI
import SwiftUI
import Testing
@testable import AgentHooks
@testable import RogaUI

/// The menu that the repository's name in the title row opens: a row for each
/// worktree, and what its second line says.
@Suite(.timeLimit(.minutes(1)), .removesTemporaryFolders)
struct WorktreeMenuTests {
    private let home = NSHomeDirectory()
    private var main: Worktree { Worktree(path: home + "/code/agents-demo", branch: "refs/heads/main", isMain: true) }
    private var fixLogin: Worktree { Worktree(path: home + "/agents/fix-login", branch: "refs/heads/agent/fix-login") }

    private func choices(_ entries: [RefMenu.Entry]) -> [RefMenu.Choice] {
        entries.compactMap { if case let .choice(choice) = $0 { choice } else { nil } }
    }

    private func commands(_ entries: [RefMenu.Entry]) -> [(title: String, isEnabled: Bool, action: () -> Void)] {
        entries.compactMap { if case let .command(title, _, isEnabled, action) = $0 { (title, isEnabled, action) } else { nil } }
    }

    private func actions(shown: @escaping (String) -> Void = { _ in }, newWorktree: (() -> Void)? = {}) -> WorktreeMenu.Actions {
        WorktreeMenu.Actions(show: shown, newWorktree: newWorktree, reveal: { _ in }, openInTerminal: { _ in })
    }

    @Test func listsEachWorktreeByItsBranchWithTheMainOneFirst() {
        let detached = Worktree(path: home + "/agents/bisect", head: ObjectID(hex: "86b3386aa0000000000000000000000000000000"))
        let entries = WorktreeMenu.entries(
            for: [WorktreeFacts(worktree: main), WorktreeFacts(worktree: fixLogin), WorktreeFacts(worktree: detached)],
            shown: fixLogin.path,
            actions: actions()
        )
        #expect(choices(entries).map(\.title) == ["main", "agent/fix-login", "detached at 86b3386a"])
        #expect(choices(entries).map(\.isCurrent) == [false, true, false])
        #expect(commands(entries).map(\.title) == ["New Worktree…", "Show in Finder", "Open in Terminal"])
    }

    @Test func choosingAWorktreeShowsItAndChoosingTheCurrentOneDoesNothing() {
        var shown: [String] = []
        let entries = WorktreeMenu.entries(
            for: [WorktreeFacts(worktree: main), WorktreeFacts(worktree: fixLogin)],
            shown: fixLogin.path,
            actions: actions(shown: { shown.append($0) })
        )
        for choice in choices(entries) { choice.action() }
        #expect(shown == [main.path])
    }

    @Test func aBareRepositoryHasNoRow() {
        let bare = Worktree(path: home + "/code/agents-demo.git", isMain: true, isBare: true)
        let entries = WorktreeMenu.entries(for: [WorktreeFacts(worktree: bare), WorktreeFacts(worktree: fixLogin)], shown: fixLogin.path, actions: actions())
        #expect(choices(entries).map(\.title) == ["agent/fix-login"])
    }

    @Test func newWorktreeWaitsUntilItCanStart() {
        let entries = WorktreeMenu.entries(for: [WorktreeFacts(worktree: main)], shown: main.path, actions: actions(newWorktree: nil))
        #expect(commands(entries).map(\.isEnabled) == [false, true, true])
    }

    // MARK: The second line

    private func detailText(_ facts: WorktreeFacts) -> String {
        WorktreeMenu.details(for: facts).map(\.text).joined(separator: " · ")
    }

    @Test func aQuietWorktreeShowsItsFolderFromHome() {
        #expect(detailText(WorktreeFacts(worktree: main)) == "~/code/agents-demo")
    }

    @Test func saysHowFarItsBranchIsFromItsUpstream() {
        #expect(detailText(WorktreeFacts(worktree: fixLogin, upstream: UpstreamCounts(ahead: 2))) == "↑2 · ~/agents/fix-login")
        #expect(detailText(WorktreeFacts(worktree: fixLogin, upstream: UpstreamCounts(ahead: 1, behind: 4))) == "↓4 ↑1 · ~/agents/fix-login")
        #expect(detailText(WorktreeFacts(worktree: fixLogin, upstream: UpstreamCounts())) == "~/agents/fix-login")
        #expect(detailText(WorktreeFacts(worktree: fixLogin, upstream: UpstreamCounts(isGone: true))) == "Upstream gone · ~/agents/fix-login")
    }

    @Test func whatsStoppedComesFirstInRedWhenThereAreConflicts() throws {
        let conflicted = WorktreeFacts(
            worktree: fixLogin,
            hasConflicts: true,
            unfinished: UnfinishedWork(work: .rebase(branch: "refs/heads/main"), conflicts: 2),
            upstream: UpstreamCounts(ahead: 1)
        )
        let details = WorktreeMenu.details(for: conflicted)
        #expect(details.map(\.text) == ["Rebasing main · 2 conflicts", "↑1", "~/agents/fix-login"])
        #expect(details.first?.color != nil)
        #expect(details.dropFirst().allSatisfy { $0.color == nil })

        let ready = WorktreeMenu.details(for: WorktreeFacts(worktree: fixLogin, unfinished: UnfinishedWork(work: .merge, conflicts: 0)))
        #expect(ready.map(\.text) == ["Merging · ready to commit", "~/agents/fix-login"])
        #expect(ready.allSatisfy { $0.color == nil })
    }

    @Test func aLockedWorktreeSaysSo() {
        var locked = fixLogin
        locked.isLocked = true
        #expect(detailText(WorktreeFacts(worktree: locked)) == "Locked · ~/agents/fix-login")
    }

    @Test func aMissingOrDeletedWorktreeCantBeChosen() {
        var missing = fixLogin
        missing.isPrunable = true
        let gone = WorktreeMenu.choice(for: WorktreeFacts(worktree: missing), isCurrent: false) {}
        #expect(!gone.isEnabled)
        #expect(gone.detailText == "Folder missing · ~/agents/fix-login")

        let deleting = WorktreeMenu.choice(for: WorktreeFacts(worktree: fixLogin, isDeleting: true), isCurrent: false) {}
        #expect(!deleting.isEnabled)
        #expect(deleting.detailText == "Deleting… · ~/agents/fix-login")
    }

    @Test func aRowShowsItsWholeFolderOnHover() {
        #expect(WorktreeMenu.choice(for: WorktreeFacts(worktree: fixLogin), isCurrent: false) {}.help == fixLogin.path)
    }

    // MARK: The count

    @Test func countsUncommittedFilesInOrangeOrInRedWithConflicts() throws {
        #expect(WorktreeMenu.count(for: WorktreeFacts(worktree: fixLogin)) == nil)

        let changed = try #require(WorktreeMenu.count(for: WorktreeFacts(worktree: fixLogin, uncommittedFiles: 1234)))
        #expect(changed.text == 1234.formatted())
        #expect(changed.color == .systemOrange)
        #expect(changed.icon == nil)

        let conflicted = try #require(WorktreeMenu.count(for: WorktreeFacts(worktree: fixLogin, uncommittedFiles: 5, hasConflicts: true)))
        #expect(conflicted.text == "5")
        #expect(conflicted.color != .systemOrange)
        #expect(conflicted.icon != nil)
    }

    // MARK: What's known

    @Test func takesWhatTheSidebarKnowsAboutEachWorktree() {
        let repository = ListedRepository(
            path: main.path + "/.git",
            worktrees: [main, fixLogin],
            uncommittedFiles: [fixLogin.path: 3],
            conflictedWorktrees: [fixLogin.path],
            unfinishedWork: [fixLogin.path: UnfinishedWork(work: .merge, conflicts: 1)!],
            upstreams: ["refs/heads/main": UpstreamCounts(behind: 3)],
            deletingWorktrees: [fixLogin.path]
        )
        let facts = WorktreeMenu.facts(of: repository, shown: main.path, model: nil, agents: nil, in: RepositoryList(listing: [repository]))
        #expect(facts == [
            WorktreeFacts(worktree: main, upstream: UpstreamCounts(behind: 3)),
            WorktreeFacts(
                worktree: fixLogin,
                uncommittedFiles: 3,
                hasConflicts: true,
                unfinished: UnfinishedWork(work: .merge, conflicts: 1),
                isDeleting: true
            ),
        ])
    }

    // MARK: Agents

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ state: AgentSummary.State, sessions: Int = 1) -> AgentSummary {
        AgentSummary(state: state, since: start, hosts: [.claude], sessions: sessions)
    }

    @Test func whatAnAgentIsDoingComesFirstOnTheSecondLine() {
        let working = WorktreeFacts(worktree: fixLogin, upstream: UpstreamCounts(ahead: 2), agent: agent(.working))
        // Under a minute, it leaves the time out.
        #expect(WorktreeMenu.details(for: working, now: start.addingTimeInterval(59)).map(\.text) == ["Claude Code working", "↑2", "~/agents/fix-login"])
        let details = WorktreeMenu.details(for: working, now: start.addingTimeInterval(6 * 60 + 59))
        #expect(details.map(\.text) == ["Claude Code working", "6 min", "↑2", "~/agents/fix-login"])
        #expect(details.allSatisfy { $0.color == nil })

        let both = WorktreeFacts(worktree: fixLogin, isDeleting: true, agent: agent(.working, sessions: 2))
        #expect(WorktreeMenu.details(for: both, now: start.addingTimeInterval(90)).map(\.text) == ["2 agents working", "1 min", "Deleting…", "~/agents/fix-login"])
    }

    @Test func anAgentWaitingForYouIsAmberAndOneThatFinishedSaysNoTime() throws {
        let waiting = WorktreeMenu.details(for: WorktreeFacts(worktree: fixLogin, agent: agent(.waiting(.permission))), now: start.addingTimeInterval(120))
        #expect(waiting.map(\.text) == ["Claude Code waiting for you", "2 min", "~/agents/fix-login"])
        #expect(waiting.prefix(2).allSatisfy { $0.color == WorktreeMenu.agentWaitingColor })
        #expect(waiting.last?.color == nil)

        let finished = WorktreeMenu.details(for: WorktreeFacts(worktree: fixLogin, agent: agent(.finished)), now: start.addingTimeInterval(3600))
        #expect(finished.map(\.text) == ["Claude Code finished", "~/agents/fix-login"])
        #expect(finished.allSatisfy { $0.color == nil })
    }

    @Test func whatTheAgentSaysItsDoingFollowsItsName() {
        func details(_ state: AgentSummary.State, _ host: AgentHost, _ activity: String) -> [RefMenu.Detail] {
            let agent = AgentSummary(state: state, since: start, hosts: [host], sessions: 1, activity: activity)
            return WorktreeMenu.details(
                for: WorktreeFacts(worktree: fixLogin, unfinished: UnfinishedWork(work: .rebase(branch: "refs/heads/main"), conflicts: 2), agent: agent),
                now: start.addingTimeInterval(6 * 60 + 5)
            )
        }
        let working = details(.working, .claude, "Run the test suite")
        #expect(working.map(\.text) == ["Claude Code: Run the test suite", "6 min", "Rebasing main · 2 conflicts", "~/agents/fix-login"])
        #expect(working.first?.color == nil)
        let waiting = details(.waiting(.permission), .codex, "git push")
        #expect(waiting.map(\.text) == ["Codex needs your OK: git push", "6 min", "Rebasing main · 2 conflicts", "~/agents/fix-login"])
        #expect(waiting.prefix(2).allSatisfy { $0.color == WorktreeMenu.agentWaitingColor })
        let question = details(.waiting(.question), .claude, "Wants a plan approved")
        #expect(question.prefix(2).map(\.text) == ["Claude Code: Wants a plan approved", "6 min"])
        #expect(question.prefix(2).allSatisfy { $0.color == WorktreeMenu.agentWaitingColor })
        // The reply stays in the mark's tooltip.
        #expect(details(.finished, .claude, "Added the line to the menu").first?.text == "Claude Code finished")
    }

    @Test func onlyTheAgentsWordsMayBeCutShortAndTheyReadAsOneLineWithTheTime() {
        let now = start.addingTimeInterval(6 * 60 + 5)
        let agents = [
            AgentSummary(state: .working, since: start, hosts: [.claude], sessions: 1, activity: "Run the test suite"),
            AgentSummary(state: .waiting(.permission), since: start, hosts: [.codex], sessions: 1, activity: "git push"),
            AgentSummary(state: .working, since: start, hosts: [.claude, .codex], sessions: 2),
            AgentSummary(state: .working, since: now, hosts: [.claude], sessions: 1),
            AgentSummary(state: .finished, since: start, hosts: [.claude], sessions: 1, activity: "Done"),
        ]
        for agent in agents {
            let facts = WorktreeFacts(worktree: fixLogin, upstream: UpstreamCounts(ahead: 2), agent: agent)
            let choice = WorktreeMenu.choice(for: facts, isCurrent: false, now: now) {}
            // The menu's width and VoiceOver read the parts joined, as one line.
            #expect(choice.detailText == agent.menuDetail(now: now) + " · ↑2 · ~/agents/fix-login")
            #expect(choice.details.map(\.canBeCutShort) == [true] + Array(repeating: false, count: choice.details.count - 1))
        }
    }

    @Test func aLongLineIsCutShortSoItCantHideAConflict() throws {
        let line = String(String(repeating: "Run the test suite ", count: 7).prefix(120))
        #expect(line.count == 120)
        let agent = AgentSummary(state: .working, since: start, hosts: [.claude], sessions: 1, activity: line)
        let facts = WorktreeFacts(
            worktree: fixLogin,
            uncommittedFiles: 3,
            unfinished: UnfinishedWork(work: .rebase(branch: "refs/heads/main"), conflicts: 2),
            upstream: UpstreamCounts(ahead: 2),
            agent: agent
        )
        let choice = WorktreeMenu.choice(for: facts, isCurrent: false, now: start.addingTimeInterval(65 * 60)) {}
        #expect(choice.details.map(\.text) == ["Claude Code: " + line, "1 hr 5 min", "Rebasing main · 2 conflicts", "↑2", "~/agents/fix-login"])
        // The line widens the menu to its limit.
        #expect(RefMenu.make([.choice(choice)]).items.compactMap { $0.view?.frame.width } == [480])

        let room = RefMenu.textRoom(inRow: 480, count: choice.count)
        let widths = try #require(RefMenu.detailWidths(of: choice.details, in: room))
        let whole = choice.details.map { RefMenu.detailWidth($0.text) }
        // How long, the conflicts and how far ahead stay whole.
        #expect(widths[1...3] == whole[1...3])
        // The agent's words are cut at their end, and the folder keeps room
        // for its name.
        #expect(widths[0] < whole[0] && widths[0] >= 24)
        #expect(widths[4] >= 80)
        let separators = 4 * RefMenu.detailWidth(" · ")
        #expect(abs(widths.reduce(0, +) + separators - room) < 0.001)

        // A short line is too long too, with conflicts and an hour beside it,
        // and only its words are cut.
        let short = AgentSummary(state: .working, since: start, hosts: [.claude], sessions: 1, activity: "Run the test suite")
        var conflicts = facts
        conflicts.agent = short
        let details = WorktreeMenu.details(for: conflicts, now: start.addingTimeInterval(65 * 60))
        let shortWhole = details.map { RefMenu.detailWidth($0.text) }
        let cut = try #require(RefMenu.detailWidths(of: details, in: room))
        #expect(cut[0] < shortWhole[0])
        #expect(cut[1...3] == shortWhole[1...3])
    }

    @Test func aShortLineOrOneWithNothingToCutIsDrawnAsBefore() {
        let room = RefMenu.textRoom(inRow: 480, count: nil)
        let rebase = UnfinishedWork(work: .rebase(branch: "refs/heads/main"), conflicts: 2)
        let agent = AgentSummary(state: .working, since: start, hosts: [.claude], sessions: 1, activity: "Run the test suite")
        let short = WorktreeMenu.details(for: WorktreeFacts(worktree: fixLogin, upstream: UpstreamCounts(ahead: 2), agent: agent), now: start.addingTimeInterval(6 * 60))
        #expect(RefMenu.detailWidths(of: short, in: room) == nil)
        // Without an agent, nothing can be cut, so even a row too long is drawn
        // as it always has been.
        let deep = Worktree(path: home + "/" + String(repeating: "nested/", count: 40) + "fix-login", branch: "refs/heads/agent/fix-login", isLocked: true)
        let noAgent = WorktreeMenu.details(for: WorktreeFacts(worktree: deep, unfinished: rebase, upstream: UpstreamCounts(ahead: 2)))
        #expect(RefMenu.detailWidths(of: noAgent, in: 120) == nil)
    }

    @Test func theAmberHasALightAndADarkVersion() throws {
        func hex(in name: NSAppearance.Name) throws -> Int {
            var value: Int?
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                if let color = WorktreeMenu.agentWaitingColor.usingColorSpace(.sRGB) {
                    value = [color.redComponent, color.greenComponent, color.blueComponent].reduce(0) { $0 << 8 | Int(($1 * 255).rounded()) }
                }
            }
            return try #require(value)
        }
        #expect(try hex(in: .aqua) == 0x9A5200)
        #expect(try hex(in: .darkAqua) == 0xF0A54A)
    }

    @Test func theMenuSaysForHowLongAsOfWhenItsDrawn() {
        let entries = WorktreeMenu.entries(
            for: [WorktreeFacts(worktree: main), WorktreeFacts(worktree: fixLogin, agent: agent(.working))],
            shown: main.path,
            now: start.addingTimeInterval(65 * 60),
            actions: actions()
        )
        #expect(choices(entries).map(\.detailText) == ["~/code/agents-demo", "Claude Code working · 1 hr 5 min · ~/agents/fix-login"])
    }

    private func event(_ name: String, _ session: String, host: AgentHost = .claude, in cwd: String, at seconds: Double) -> HookEvent {
        HookEvent(host: host, event: name, session: session, cwd: cwd, pid: nil, processStart: nil, tool: nil, time: start.timeIntervalSince1970 + seconds)
    }

    /// A monitor that hears only the events a test gives it.
    private func newMonitor() -> AgentMonitor {
        AgentMonitor(supportFolder: URL(filePath: "/nonexistent"), checkInterval: nil)
    }

    @Test func takesWhatAgentsAreDoingFromTheMonitor() {
        let repository = ListedRepository(path: main.path + "/.git", worktrees: [main, fixLogin])
        let list = RepositoryList(listing: [repository])
        let monitor = newMonitor()
        monitor.receive(event("UserPromptSubmit", "a", in: fixLogin.path + "/Sources", at: 0))
        monitor.receive(event("UserPromptSubmit", "b", host: .codex, in: fixLogin.path, at: 30))
        monitor.receive(event("PermissionRequest", "b", host: .codex, in: fixLogin.path, at: 40))

        let facts = WorktreeMenu.facts(of: repository, shown: main.path, model: nil, agents: monitor, in: list)
        #expect(facts.map(\.agent) == [
            nil,
            AgentSummary(state: .waiting(.permission), since: start.addingTimeInterval(40), hosts: [.codex], sessions: 1),
        ])
        // Without a monitor, it says nothing about agents.
        #expect(WorktreeMenu.facts(of: repository, shown: main.path, model: nil, agents: nil, in: list).allSatisfy { $0.agent == nil })
    }

    @Test func theChipSaysWhatAgentsAreDoingOnlyWhileTheMarksShow() {
        let (defaults, name) = AgentTestSupport.defaults()
        defer { AgentTestSupport.remove(defaults, named: name) }
        let repository = ListedRepository(path: main.path + "/.git", worktrees: [main, fixLogin])
        let list = RepositoryList(listing: [repository])
        let monitor = newMonitor()
        monitor.receive(event("UserPromptSubmit", "a", in: fixLogin.path, at: 0))
        func agents() -> [AgentSummary.State?] {
            let chip = WorktreeChip(
                repository: repository,
                worktree: main,
                model: nil,
                actions: actions(),
                monitor: monitor,
                list: list,
                marks: AgentMarksSetting(store: defaults)
            )
            return chip.facts.map { $0.agent?.state }
        }

        // The menu says what agents are doing until the person turns the
        // marks off in Settings.
        #expect(agents() == [nil, .working])
        defaults.set(false, forKey: AgentPreferences.showsMarksKey)
        #expect(agents() == [nil, nil])
        defaults.set(true, forKey: AgentPreferences.showsMarksKey)
        #expect(agents() == [nil, .working])
    }

    @Test func onlyAgentsWorkingOrWaitingHaveMinutesToRedrawOn() {
        let later = start.addingTimeInterval(100)
        let finished = AgentSummary(state: .finished, since: start, hosts: [.claude], sessions: 1)
        let waiting = AgentSummary(state: .waiting(.question), since: later, hosts: [.codex], sessions: 1)
        let working = AgentSummary(state: .working, since: start, hosts: [.claude], sessions: 2)
        // What the chip's menu redraws on, for its worktrees' agents.
        #expect(WholeMinutes(of: [finished, waiting, nil]) == WholeMinutes(since: [later]))
        #expect(WholeMinutes(of: [nil, nil]) == WholeMinutes(since: []))
        // What a sidebar mark's tooltip redraws on.
        #expect(SidebarMark(summary: finished).minutes == WholeMinutes(since: []))
        #expect(SidebarMark(summary: waiting).minutes == WholeMinutes(since: [later]))
        #expect(SidebarMark(summary: working).minutes == WholeMinutes(since: [start]))
    }

    @Test func wholeMinutesComeASecondAfterEachMinuteOfEveryAgent() {
        let first = start
        let second = start.addingTimeInterval(20)
        let schedule = WholeMinutes(since: [first, second])
        let now = start.addingTimeInterval(130)
        let times = Array(schedule.entries(from: now, mode: .normal).prefix(5)).map { $0.timeIntervalSince(start) }
        #expect(times == [130, 141, 181, 201, 241])
        // Each one says the next minute, not the one before it.
        let summary = AgentSummary(state: .working, since: second, hosts: [.claude], sessions: 1)
        #expect(summary.menuDetail(now: start.addingTimeInterval(times[1])) == "Claude Code working · 2 min")

        #expect(Array(WholeMinutes(since: []).entries(from: now, mode: .normal)) == [now])
        // Before an agent's first minute, the next is its first.
        #expect(Array(WholeMinutes(since: [now]).entries(from: now, mode: .normal).prefix(2)) == [now, now.addingTimeInterval(61)])
    }
}
