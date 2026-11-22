import Foundation
import GitCore
import Testing
@testable import AgentHooks
@testable import RogaUI

/// What the tabs along the top of the window say about each worktree
/// (decision 95).
@MainActor
@Suite
struct WorktreeTabsTests {
    private let home = NSHomeDirectory()
    private var main: Worktree { Worktree(path: home + "/code/agents-demo", branch: "refs/heads/main", isMain: true) }
    private var fixLogin: Worktree { Worktree(path: home + "/agents/fix-login", branch: "refs/heads/agent/fix-login") }
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ state: AgentSummary.State) -> AgentSummary {
        AgentSummary(state: state, since: start, hosts: [.claude], sessions: 1)
    }

    // MARK: Which worktrees have tabs

    @Test func aBareRepositoryHasNoTabAndTheRestKeepGitsOrder() {
        let bare = Worktree(path: home + "/code/agents-demo.git", isMain: true, isBare: true)
        let tabs = WorktreeTabs.tabs([WorktreeFacts(worktree: bare), WorktreeFacts(worktree: fixLogin), WorktreeFacts(worktree: main)])
        #expect(tabs.map(\.worktree.path) == [fixLogin.path, main.path])
    }

    // MARK: The name

    /// The two parts of the tab's name, with a bar between them.
    private func name(_ worktree: Worktree) -> String {
        let parts = WorktreeTabs.nameParts(of: worktree)
        return parts.folder + "|" + parts.name
    }

    @Test func theBranchsFolderIsSplitOffSoItCanBeDimmed() {
        #expect(name(fixLogin) == "agent/|fix-login")
        #expect(name(Worktree(path: home + "/agents/a", branch: "refs/heads/tm/agents/retry")) == "tm/agents/|retry")
    }

    @Test func aNameWithoutAFolderOrADetachedHeadStaysWhole() {
        #expect(name(main) == "|main")
        let detached = Worktree(path: home + "/agents/bisect", head: ObjectID(hex: "86b3386aa0000000000000000000000000000000"))
        #expect(name(detached) == "|detached at 86b3386a")
    }

    // MARK: The mark

    @Test func anAgentWaitingComesBeforeConflictsAndConflictsBeforeAnAgentAtWork() {
        let waiting = WorktreeFacts(worktree: fixLogin, hasConflicts: true, agent: agent(.waiting(.permission)))
        #expect(WorktreeTabs.mark(for: waiting) == .agent(.waiting(.permission)))
        let conflicted = WorktreeFacts(worktree: fixLogin, hasConflicts: true, agent: agent(.working))
        #expect(WorktreeTabs.mark(for: conflicted) == .conflicts)
        let stopped = WorktreeFacts(worktree: fixLogin, unfinished: UnfinishedWork(work: .merge, conflicts: 2))
        #expect(WorktreeTabs.mark(for: stopped) == .conflicts)
        #expect(WorktreeTabs.mark(for: WorktreeFacts(worktree: fixLogin, agent: agent(.working))) == .agent(.working))
        #expect(WorktreeTabs.mark(for: WorktreeFacts(worktree: fixLogin, agent: agent(.finished))) == .agent(.finished))
    }

    @Test func withNothingToSayItsTheRepositoryOnItsOwnTabAndTheWorktreeOnTheOthers() {
        #expect(WorktreeTabs.mark(for: WorktreeFacts(worktree: main)) == .repository)
        #expect(WorktreeTabs.mark(for: WorktreeFacts(worktree: fixLogin)) == .worktree)
        var locked = fixLogin
        locked.isLocked = true
        #expect(WorktreeTabs.mark(for: WorktreeFacts(worktree: locked)) == .locked)
        var missing = fixLogin
        missing.isPrunable = true
        #expect(WorktreeTabs.mark(for: WorktreeFacts(worktree: missing)) == .folderMissing)
    }

    // MARK: The number

    @Test func onlyTheMostPressingNumberShows() {
        let behind = UpstreamCounts(ahead: 1, behind: 3)
        #expect(WorktreeTabs.badge(for: WorktreeFacts(worktree: fixLogin, uncommittedFiles: 4, hasConflicts: true, upstream: behind)) == .conflicts(4))
        #expect(WorktreeTabs.badge(for: WorktreeFacts(worktree: fixLogin, uncommittedFiles: 4, statusFailure: "fatal: index file corrupt", upstream: behind)) == .cantList)
        #expect(WorktreeTabs.badge(for: WorktreeFacts(worktree: fixLogin, uncommittedFiles: 4, upstream: behind)) == .uncommitted(4))
        #expect(WorktreeTabs.badge(for: WorktreeFacts(worktree: fixLogin, upstream: behind)) == .behind(3))
        #expect(WorktreeTabs.badge(for: WorktreeFacts(worktree: fixLogin, upstream: UpstreamCounts(ahead: 2))) == .ahead(2))
    }

    @Test func aWorktreeWithNothingWaitingOrAGoneUpstreamHasNoNumber() {
        #expect(WorktreeTabs.badge(for: WorktreeFacts(worktree: fixLogin)) == nil)
        #expect(WorktreeTabs.badge(for: WorktreeFacts(worktree: fixLogin, upstream: UpstreamCounts(ahead: 2, isGone: true))) == nil)
    }

    // MARK: The tooltip

    @Test func theTooltipHasTheWholeNameItsKeyAndWhatTheMenuSays() {
        let facts = WorktreeFacts(worktree: fixLogin, upstream: UpstreamCounts(ahead: 1, behind: 4))
        #expect(WorktreeTabs.help(for: facts, repositoryName: nil, index: 1) == "agent/fix-login  ⌘2\n↓4 ↑1 · ~/agents/fix-login")
        #expect(WorktreeTabs.help(for: WorktreeFacts(worktree: main), repositoryName: "agents-demo", index: 0) == "agents-demo, on main  ⌘1\n~/code/agents-demo")
    }

    @Test func aTabPastTheNinthHasNoKey() {
        #expect(WorktreeTabs.help(for: WorktreeFacts(worktree: fixLogin), repositoryName: nil, index: 9) == "agent/fix-login\n~/agents/fix-login")
    }

    // MARK: Next and previous

    private func commands(_ titles: [String], current: String, disabled: Set<String> = []) -> WorktreeCommands {
        WorktreeCommands(
            worktrees: titles.map { title in
                WorktreeCommands.Worktree(path: "/" + title, title: title, isCurrent: title == current, isEnabled: !disabled.contains(title), show: {})
            },
            newWorktree: nil,
            reveal: nil,
            openInTerminal: nil
        )
    }

    @Test func nextAndPreviousGoAroundAndSkipWhatCantBeShown() {
        let worktrees = commands(["main", "a", "b", "c"], current: "c", disabled: ["a"])
        #expect(worktrees.worktree(after: 1)?.title == "main")
        #expect(worktrees.worktree(after: -1)?.title == "b")
        #expect(commands(["main", "a", "b"], current: "main", disabled: ["a"]).worktree(after: 1)?.title == "b")
    }

    @Test func withOnlyOneTabTheresNowhereToGo() {
        #expect(commands(["main"], current: "main").worktree(after: 1) == nil)
        #expect(commands(["main", "a"], current: "main", disabled: ["a"]).worktree(after: -1) == nil)
    }
}
