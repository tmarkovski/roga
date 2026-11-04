import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import YagaUI

/// Deleting linked worktrees from the sidebar, in a listed clone of a bare copy of
/// the `basic` repository. The clone has a linked worktree on `topic`.
@Suite(.timeLimit(.minutes(1)))
struct WorktreeDeletionModelTests {
    struct Setup {
        var folder: String
        var remote: String
        var work: String
        var linked: String
        var list: RepositoryList
        var repository: ListedRepository
        var model = WorktreeDeletionModel()

        var selection: WorktreeSelection { WorktreeSelection(repository: repository.path, worktree: linked) }

        var worktree: Worktree {
            get throws { try #require(repository.worktrees.first { $0.path == linked }) }
        }

        /// Asks to delete the worktree, and picks `scope` if the dialog asks how far
        /// to go.
        func ask(_ scope: WorktreeDeletion.Scope? = nil) async throws {
            model.askToDelete(try worktree, in: repository, list: list)
            await model.running?.value
            if let scope { model.pending?.scope = scope }
        }

        func confirm() async {
            model.confirm()
            await model.running?.value
        }
    }

    func setup(pushed: Bool = false) async throws -> Setup {
        let fixture = try await Fixture.repository("basic")
        let folder = try makeTemporaryFolder()
        let remote = folder + "/remote.git"
        let work = folder + "/work"
        let linked = folder + "/linked"
        try await runGit("clone", "--quiet", "--bare", "--no-local", fixture, remote, in: fixture)
        try await runGit("clone", "--quiet", remote, work, in: folder)
        try await runGit("worktree", "add", "--quiet", "-b", "topic", linked, "main", in: work)
        if pushed { try await runGit("push", "--quiet", "--set-upstream", "origin", "topic", in: linked) }
        let list = RepositoryList(store: RepositoryStore(file: URL(filePath: folder + "/support/repositories.json")))
        await list.connect(git: try await TestGit.make())
        _ = try await list.add(folder: work)
        let repository = try #require(list.repositories.first)
        await list.refresh()
        return Setup(folder: folder, remote: remote, work: work, linked: linked, list: list, repository: repository)
    }

    func commit(_ message: String, in folder: String) async throws {
        try await runGit("-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--quiet", "--allow-empty", "-m", message, in: folder)
    }

    func exists(_ ref: String, in folder: String) async throws -> Bool {
        try await !runGit("for-each-ref", "--format=%(refname)", ref, in: folder).isEmpty
    }

    // MARK: Deleting

    @Test func deletesAWorktreeWithNothingToChooseAndNothingToLoseWithoutAsking() async throws {
        let setup = try await setup()
        try await runGit("switch", "--quiet", "--detach", in: setup.linked)
        await setup.list.refresh()
        let before = setup.repository.deletionCount
        try await setup.ask()
        #expect(setup.model.pending == nil)
        #expect(setup.model.failure == nil)
        #expect(setup.repository.worktrees.map(\.path) == [setup.work])
        #expect(setup.repository.deletingWorktrees.isEmpty)
        #expect(setup.repository.deletionCount == before + 1)
        #expect(!FileManager.default.fileExists(atPath: setup.linked))
        #expect(try await exists("refs/heads/topic", in: setup.work))
    }

    @Test func asksHowFarToGoEvenWhenNothingWouldBeLost() async throws {
        let setup = try await setup()
        try await setup.ask()
        let pending = try #require(setup.model.pending)
        #expect(pending.title == "Delete the worktree for topic?")
        #expect(pending.scope == .worktreeAndBranch)
        #expect(FileManager.default.fileExists(atPath: setup.linked))

        await setup.confirm()
        #expect(!FileManager.default.fileExists(atPath: setup.linked))
        #expect(try await !exists("refs/heads/topic", in: setup.work))
    }

    @Test func aWindowShowingTheWorktreeMovesToTheMainOne() async throws {
        let setup = try await setup()
        let selection = setup.selection
        #expect(setup.list.resolve(selection) == selection)
        try await setup.ask(.worktree)
        await setup.confirm()
        #expect(setup.list.resolve(selection) == setup.repository.home)
        #expect(setup.repository.home.worktree == setup.work)
    }

    @Test func forgetsThatItKeptTheWorktreeShowing() async throws {
        let setup = try await setup()
        setup.list.setExpanded(false, setup.repository)
        setup.list.keepShowing(setup.selection)
        #expect(setup.repository.keptWorktrees == [setup.linked])
        try await setup.ask(.worktree)
        await setup.confirm()
        #expect(setup.repository.keptWorktrees.isEmpty)
    }

    @Test func asksAboutWhatCantBeBroughtBackAndDeletesOnlyOnceAgreed() async throws {
        let setup = try await setup()
        try "new".write(toFile: setup.linked + "/untracked.txt", atomically: true, encoding: .utf8)
        try await setup.ask(.worktree)
        let pending = try #require(setup.model.pending)
        #expect(pending.title == "Delete the worktree for topic?")
        #expect(FileManager.default.fileExists(atPath: setup.linked))

        await setup.confirm()
        #expect(setup.model.pending == nil)
        #expect(!FileManager.default.fileExists(atPath: setup.linked))
        #expect(setup.repository.worktrees.map(\.path) == [setup.work])
    }

    @Test func cancellingLeavesEverythingAsItWas() async throws {
        let setup = try await setup(pushed: true)
        try await setup.ask(.everything)
        #expect(setup.model.pending != nil)
        // What the alert's Cancel button does through its binding.
        setup.model.pending = nil
        await setup.confirm()
        #expect(FileManager.default.fileExists(atPath: setup.linked))
        #expect(try await exists("refs/heads/topic", in: setup.work))
        #expect(try await exists("refs/heads/topic", in: setup.remote))
    }

    @Test func deletesEverythingOnceAgreed() async throws {
        let setup = try await setup(pushed: true)
        try await setup.ask(.everything)
        #expect(setup.model.pending?.title == "Delete the worktree for topic?")
        await setup.confirm()
        #expect(setup.model.failure == nil)
        #expect(!FileManager.default.fileExists(atPath: setup.linked))
        #expect(try await !exists("refs/heads/topic", in: setup.work))
        #expect(try await !exists("refs/heads/topic", in: setup.remote))
    }

    @Test func theRowSaysItsDeletingAndCantBeDeletedTwice() async throws {
        let setup = try await setup(pushed: true)
        // A slow push, which waits until the test lets it go on.
        let hooks = setup.work + "/.git/hooks"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        let hook = hooks + "/pre-push"
        try "#!/bin/sh\nwhile [ ! -e '\(setup.folder)/go' ]; do sleep 0.05; done\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)

        let worktree = try setup.worktree
        try await setup.ask(.everything)
        setup.model.confirm()
        let deleting = try #require(setup.model.running)
        while !FileManager.default.fileExists(atPath: setup.folder + "/go") {
            if setup.repository.deletingWorktrees.contains(setup.linked) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(setup.repository.deletingWorktrees == [setup.linked])

        setup.model.askToDelete(worktree, in: setup.repository, list: setup.list)
        #expect(setup.model.running == deleting)

        try "".write(toFile: setup.folder + "/go", atomically: true, encoding: .utf8)
        await deleting.value
        #expect(setup.repository.deletingWorktrees.isEmpty)
        #expect(setup.model.failure == nil)
    }

    // MARK: When git refuses

    @Test func showsWhatGitSaysAboutALockedWorktreeWithoutAsking() async throws {
        let setup = try await setup(pushed: true)
        try await runGit("worktree", "lock", "--reason", "agent running", setup.linked, in: setup.work)
        try await setup.ask(.everything)
        #expect(setup.model.pending == nil)
        let failure = try #require(setup.model.failure)
        #expect(failure.title == "Can't delete the worktree linked")
        #expect(failure.said.contains("agent running"))
        #expect(setup.repository.deletingWorktrees.isEmpty)
        #expect(FileManager.default.fileExists(atPath: setup.linked))
        #expect(try await exists("refs/heads/topic", in: setup.remote))
    }

    @Test func saysWhatsLeftWhenTheBranchCantBeDeleted() async throws {
        let setup = try await setup(pushed: true)
        try await runGit("worktree", "add", "--quiet", "--force", setup.folder + "/second", "topic", in: setup.work)
        await setup.list.refresh()
        try await setup.ask(.everything)
        await setup.confirm()
        let failure = try #require(setup.model.failure)
        #expect(failure.title == "Can't delete topic")
        #expect(failure.summary == "The worktree is gone, but its branch topic isn't.")
        #expect(failure.command == ["branch", "-D", "topic"])
        #expect(failure.note == "origin/topic wasn't touched.")
        #expect(!setup.repository.worktrees.contains { $0.path == setup.linked })
    }

    @Test func saysWhatsLeftWhenTheRemoteCantBeReached() async throws {
        let setup = try await setup(pushed: true)
        try await setup.ask(.everything)
        try FileManager.default.moveItem(atPath: setup.remote, toPath: setup.remote + ".moved")
        await setup.confirm()
        let failure = try #require(setup.model.failure)
        #expect(failure.title == "Can't delete origin/topic")
        #expect(failure.summary == "The worktree and its branch are gone, but origin/topic isn't.")
        #expect(failure.command == ["push", "--delete", "origin", "refs/heads/topic"])
        #expect(failure.note == "To try again, use Delete from Remote… in the refs panel.")
        // The refs panel's remote branch is still there to try again from.
        #expect(try await exists("refs/remotes/origin/topic", in: setup.work))
    }

    // MARK: What the dialog says

    @Test func saysWhatGoesWhateverAnyoneChooses() async throws {
        let setup = try await setup()
        let exclude = setup.work + "/.git/info/exclude"
        try ".env\n".write(toFile: exclude, atomically: true, encoding: .utf8)
        try "SECRET=1".write(toFile: setup.linked + "/.env", atomically: true, encoding: .utf8)
        try "new".write(toFile: setup.linked + "/untracked.txt", atomically: true, encoding: .utf8)
        try await setup.ask()
        let dialog = setup.model.dialog(for: try #require(setup.model.pending))
        #expect(dialog.message?.plain == "These can't be brought back:")
        #expect(dialog.cards == [[
            .fact("1 uncommitted file", "goes with the folder"),
            .fact("Files git ignores", ".env"),
        ]])
        #expect(dialog.terminal == [
            .command(["worktree", "remove", "--force", setup.linked]),
            .command(["branch", "-D", "topic"]),
        ])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .destructive])
    }

    @Test func aDeletionThatLosesNothingCanBeAgreedToWithReturn() async throws {
        let setup = try await setup()
        try await setup.ask()
        let dialog = setup.model.dialog(for: try #require(setup.model.pending))
        #expect(dialog.switches.map(\.isOn) == [true])
        #expect(dialog.switches.map(\.title.plain) == ["Also delete topic"])
        #expect(dialog.switches.first?.detail.plain == "Its commits are all on other branches or tags.")
        #expect(dialog.buttons.map(\.kind) == [.secondary, .primary])
    }

    @Test func aBranchWithCommitsOfItsOwnStartsOffAndSaysWhenTheyGo() async throws {
        let setup = try await setup()
        try await commit("Only here", in: setup.linked)
        try await setup.ask()
        var dialog = setup.model.dialog(for: try #require(setup.model.pending))
        #expect(dialog.switches.map(\.isOn) == [false])
        #expect(dialog.switches.first?.detail.plain == "1 commit isn't on any other branch or tag.")
        #expect(dialog.cardsAfterSwitches.first?.first == .heading("1 commit stays on topic", isLost: false))
        #expect(dialog.terminal == [.command(["worktree", "remove", setup.linked]), .blank])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .primary])

        dialog.switches[0].flip()
        dialog = setup.model.dialog(for: try #require(setup.model.pending))
        #expect(dialog.switches.map(\.isOn) == [true])
        #expect(dialog.cardsAfterSwitches.first?.first == .heading("This commit can't be brought back", isLost: true))
        #expect(dialog.terminal == [.command(["worktree", "remove", setup.linked]), .command(["branch", "-D", "topic"])])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .destructive])
    }

    /// A sheet can't change size once it's open.
    @Test func nothingComesOrGoesWhenTheSwitchesFlip() async throws {
        let setup = try await setup(pushed: true)
        try await commit("Only here", in: setup.linked)
        try await setup.ask()
        func shape() throws -> [Int] {
            let dialog = setup.model.dialog(for: try #require(setup.model.pending))
            return [dialog.cards.count, dialog.switches.count, dialog.cardsAfterSwitches.first?.count ?? 0, dialog.terminal.count]
        }
        let before = try shape()
        #expect(before == [0, 2, 2, 3])
        for scope in [WorktreeDeletion.Scope.worktree, .worktreeAndBranch, .init(deletesRemoteBranch: true), .everything] {
            setup.model.pending?.scope = scope
            #expect(try shape() == before)
        }
    }

    @Test func aPushedBranchSaysItsCommitsAreOnItsRemoteBranchUntilThatGoesToo() async throws {
        let setup = try await setup(pushed: true)
        try await commit("Pushed", in: setup.linked)
        try await runGit("push", "--quiet", in: setup.linked)
        try await setup.ask()
        var dialog = setup.model.dialog(for: try #require(setup.model.pending))
        #expect(dialog.switches.map(\.isOn) == [true, false])
        #expect(dialog.switches.first?.detail.plain == "Its commits are also on origin/topic.")
        #expect(dialog.cardsAfterSwitches.first?.first == .heading("1 commit stays on origin/topic", isLost: false))

        dialog.switches[1].flip()
        dialog = setup.model.dialog(for: try #require(setup.model.pending))
        #expect(dialog.cardsAfterSwitches.first?.first == .heading("This commit can't be brought back", isLost: true))
    }

    @Test func warnsThatDeletingFromARemoteAffectsEveryoneAndStartsOff() async throws {
        let setup = try await setup(pushed: true)
        try await setup.ask()
        var dialog = setup.model.dialog(for: try #require(setup.model.pending))
        #expect(dialog.switches.map(\.isOn) == [true, false])
        #expect(dialog.switches.last?.title.plain == "Also delete origin/topic")
        #expect(dialog.switches.last?.detail.plain == "This deletes the branch on origin, for everyone who uses it.")
        #expect(dialog.terminal == [
            .command(["worktree", "remove", setup.linked]),
            .command(["branch", "-D", "topic"]),
            .blank,
        ])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .primary])

        dialog.switches[1].flip()
        dialog = setup.model.dialog(for: try #require(setup.model.pending))
        #expect(dialog.terminal.last == .command(["push", "--delete", "origin", "refs/heads/topic"]))
        #expect(dialog.buttons.map(\.kind) == [.secondary, .destructive])
    }

    @Test func deletesTheRemoteBranchAndKeepsItsOwnWhenThatsWhatsPicked() async throws {
        let setup = try await setup(pushed: true)
        try await setup.ask()
        let dialog = setup.model.dialog(for: try #require(setup.model.pending))
        dialog.switches[0].flip()
        dialog.switches[1].flip()
        await setup.confirm()
        #expect(setup.model.failure == nil)
        #expect(try await exists("refs/heads/topic", in: setup.work))
        #expect(try await !exists("refs/heads/topic", in: setup.remote))
    }

    @Test func saysOnlyTheWorktreeWentWhenItsBranchStayedAndTheRemoteCantBeReached() async throws {
        let setup = try await setup(pushed: true)
        try await setup.ask(.init(deletesRemoteBranch: true))
        try FileManager.default.moveItem(atPath: setup.remote, toPath: setup.remote + ".moved")
        await setup.confirm()
        #expect(setup.model.failure?.summary == "The worktree is gone, but origin/topic isn't.")
    }

    @Test func aDetachedWorktreeWithSomethingToLoseHasNoSwitches() async throws {
        let setup = try await setup()
        try await runGit("switch", "--quiet", "--detach", in: setup.linked)
        try await commit("Detached", in: setup.linked)
        await setup.list.refresh()
        try await setup.ask()
        let dialog = setup.model.dialog(for: try #require(setup.model.pending))
        #expect(dialog.switches.isEmpty)
        #expect(dialog.cardsAfterSwitches.first?.first == .heading("This commit can't be brought back", isLost: true))
        #expect(dialog.terminal == [.command(["worktree", "remove", setup.linked])])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .destructive])
    }

    /// Commits submodules on `topic`, checked out in the linked worktree, which
    /// leaves the worktree clean. git needs telling to allow a URL that's a folder.
    func addSubmodules(_ paths: [String], in setup: Setup) async throws {
        for path in paths {
            try await runGit("-c", "protocol.file.allow=always", "submodule", "add", "--quiet", setup.remote, path, in: setup.linked)
            try await commit("Add \(path)", in: setup.linked)
        }
    }

    @Test func offersToDeleteAWorktreeWithASubmoduleAnyway() async throws {
        let setup = try await setup()
        try await addSubmodules(["vendor/lib"], in: setup)
        try await setup.ask(.worktree)
        #expect(setup.model.failure == nil)
        let pending = try #require(setup.model.pending)
        #expect(FileManager.default.fileExists(atPath: setup.linked))

        let dialog = setup.model.dialog(for: pending)
        #expect(dialog.title == "Delete the worktree for topic?")
        #expect(dialog.message?.plain == "Git only removes a worktree with submodules when it's forced. Nothing has looked inside them, so anything that's only there goes too.")
        #expect(dialog.cards == [[.fact("Submodule", "vendor/lib")]])
        #expect(dialog.terminal == [.command(["worktree", "remove", "--force", setup.linked]), .blank])
        #expect(dialog.buttons.map(\.title) == ["Cancel", "Delete anyway"])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .destructive])

        await setup.confirm()
        #expect(setup.model.failure == nil)
        #expect(!FileManager.default.fileExists(atPath: setup.linked))
        #expect(setup.repository.worktrees.map(\.path) == [setup.work])
        #expect(try await exists("refs/heads/topic", in: setup.work))
    }

    @Test func cancellingLeavesAWorktreeWithASubmoduleAsItWas() async throws {
        let setup = try await setup()
        try await addSubmodules(["vendor/lib"], in: setup)
        try await setup.ask(.worktree)
        setup.model.dialog?.dismiss()
        #expect(setup.model.pending == nil)
        #expect(FileManager.default.fileExists(atPath: setup.linked + "/vendor/lib/.git"))
    }

    @Test func saysWhatElseGoesBesideASubmodule() async throws {
        let setup = try await setup()
        try await addSubmodules(["vendor/lib"], in: setup)
        try "new".write(toFile: setup.linked + "/untracked.txt", atomically: true, encoding: .utf8)
        try await setup.ask(.worktree)
        let dialog = setup.model.dialog(for: try #require(setup.model.pending))
        #expect(dialog.message?.plain.hasSuffix("goes too. These can't be brought back:") == true)
        #expect(dialog.cards == [[.fact("1 uncommitted file", "goes with the folder"), .fact("Submodule", "vendor/lib")]])
    }

    @Test func countsTheSubmodulesItDoesntList() async throws {
        let setup = try await setup()
        let paths = (1...(DialogContent.listLimit + 2)).map { "vendor/\($0)" }
        try await addSubmodules(paths, in: setup)
        try await setup.ask(.worktree)
        let dialog = setup.model.dialog(for: try #require(setup.model.pending))
        let listed = paths.prefix(DialogContent.listLimit).joined(separator: ", ")
        #expect(dialog.cards == [[.fact("Submodules", listed + " and 2 more")]])
    }

    @Test func aWorktreeWithoutSubmodulesKeepsItsPlainButton() async throws {
        let setup = try await setup()
        try "new".write(toFile: setup.linked + "/untracked.txt", atomically: true, encoding: .utf8)
        try await setup.ask(.worktree)
        let dialog = setup.model.dialog(for: try #require(setup.model.pending))
        #expect(dialog.buttons.map(\.title) == ["Cancel", "Delete"])
    }

    @Test func showsWhatGitSaysAboutALockedWorktreeWithASubmoduleWithoutAsking() async throws {
        let setup = try await setup()
        try await addSubmodules(["vendor/lib"], in: setup)
        try await runGit("worktree", "lock", "--reason", "agent running", setup.linked, in: setup.work)
        try await setup.ask(.worktree)
        #expect(setup.model.pending == nil)
        let failure = try #require(setup.model.failure)
        #expect(failure.said.contains("agent running"))
        #expect(FileManager.default.fileExists(atPath: setup.linked))
    }

    @Test func dismissingTheDialogLeavesEverythingAsItWas() async throws {
        let setup = try await setup(pushed: true)
        try await setup.ask(.everything)
        setup.model.dialog?.dismiss()
        #expect(setup.model.pending == nil)
        #expect(setup.model.dialog == nil)
        #expect(FileManager.default.fileExists(atPath: setup.linked))
    }

    @Test func namesADetachedWorktreeByItsFolder() async throws {
        let setup = try await setup()
        try await runGit("switch", "--quiet", "--detach", in: setup.linked)
        try await commit("Detached", in: setup.linked)
        await setup.list.refresh()
        try await setup.ask(.worktree)
        let pending = try #require(setup.model.pending)
        #expect(pending.title == "Delete the worktree linked?")
        #expect(pending.commits.map(\.subject) == ["Detached"])
    }
}
