import AppKit
import GitCore
import MenuUI
import Testing
@testable import RogaUI

/// The menu that the repository's name in the title row opens: a row for each
/// worktree, and what its second line says.
@Suite(.timeLimit(.minutes(1)))
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
        let facts = WorktreeMenu.facts(of: repository, shown: main.path, model: nil)
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
}
