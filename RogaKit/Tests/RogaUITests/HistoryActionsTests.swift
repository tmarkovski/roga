import AppKit
import Foundation
import GitCore
import GitRunner
import HistoryUI
import MenuUI
import RepositoryEngine
import TestSupport
import Testing
@testable import RogaUI

/// What right-clicking a commit or a branch does (decision 65), against real git, in
/// a clone of the `basic` repository: `main` has Add the readme, Add the app
/// (`src/app.txt` reads `one`) and Change the app (it reads `one`, `two`), and
/// `feature` adds `NOTES.md` after Add the app.
@Suite(.timeLimit(.minutes(1)))
struct HistoryActionsTests {
    struct Worktree {
        var model: RepositoryModel
        var path: String
        var branch: BranchModel { model.branch }
    }

    let originFeature = "refs/remotes/origin/feature"
    /// Add notes, on `feature`.
    let addNotes = ObjectID(hex: Fixture.Basic.feature)!
    /// Add the app, which `main` and `feature` both have.
    let addTheApp = ObjectID(hex: Fixture.Basic.mainHistory[1])!
    /// Change the app, on `main`.
    let changeTheApp = ObjectID(hex: Fixture.Basic.main)!

    @discardableResult
    func git(_ arguments: String..., in folder: String) async throws -> String {
        try await TestGit.make().text(GitCommand(arguments, in: folder))
    }

    func worktree() async throws -> Worktree {
        let folder = try makeTemporaryFolder()
        let path = folder + "/work"
        try await git("clone", "--quiet", "--no-local", try await Fixture.repository("basic"), path, in: folder)
        try await git("config", "user.name", "T", in: path)
        try await git("config", "user.email", "t@example.com", in: path)
        return try await open(path)
    }

    func open(_ path: String) async throws -> Worktree {
        let session = try await RepositorySession.open(containing: path, git: try await TestGit.make())
        let model = RepositoryModel(session: session, worktree: path, fetchesByItself: { false }, drafts: .none)
        model.branch.timeToPlayHouse = { _ in .zero }
        model.branch.timeToShowFinished = { _ in .seconds(600) }
        await model.appear()
        await model.refRelationsUpdate?.value
        return Worktree(model: model, path: path)
    }

    func settled(_ work: Worktree) async {
        await work.model.preparingAction?.value
        await work.branch.preparingIntegration?.value
        await work.model.checkout?.value
        await work.branch.running?.value
        await work.model.check?.value
        await work.model.load()
        await work.model.refRelationsUpdate?.value
    }

    /// Has the model notice what a test changed behind its back, which a window
    /// hears about from its file watcher.
    func changedBehindItsBack(_ work: Worktree) async {
        work.model.refsChanged()
        await settled(work)
    }

    func head(_ work: Worktree, _ revision: String = "HEAD") async throws -> ObjectID {
        try #require(ObjectID(hex: try await git("rev-parse", revision, in: work.path)))
    }

    func write(_ text: String, to file: String, in work: Worktree) throws {
        try Data(text.utf8).write(to: URL(filePath: work.path + "/" + file))
    }

    func read(_ file: String, in work: Worktree) throws -> String {
        try String(contentsOfFile: work.path + "/" + file, encoding: .utf8)
    }

    func message(_ work: Worktree) throws -> DialogContent {
        guard case .message(let content) = try #require(work.model.dialog) else {
            throw SelectedFileTests.TestError("The dialog isn't a message.")
        }
        return content
    }

    /// Makes a branch off Add the app whose only commit conflicts with Change the app.
    func addConflictingBranch(_ work: Worktree) async throws -> ObjectID {
        try await git("switch", "--quiet", "-c", "other", addTheApp.hex, in: work.path)
        try write("one\nthree\n", to: "src/app.txt", in: work)
        try await git("commit", "--quiet", "--all", "--message=Change it another way", in: work.path)
        let tip = try await head(work)
        try await git("switch", "--quiet", "main", in: work.path)
        await changedBehindItsBack(work)
        return tip
    }

    // MARK: Merging

    @Test func aMergeSaysWhatComesInAndMakesAMergeCommit() async throws {
        let work = try await worktree()
        work.branch.askToIntegrate(.merge, ref: originFeature)
        await settled(work)
        let dialog = try message(work)
        #expect(dialog.id == "integration")
        #expect(dialog.title == "Merge origin/feature into main?")
        #expect(dialog.message?.plain == "1 commit comes into main from origin/feature. A merge commit joins the two lines.")
        #expect(dialog.cards == [[.commit(hash: "b07dd8d5", subject: "Add notes")]])
        #expect(dialog.terminal == [.command(["merge", "--no-edit", "--ff", "origin/feature"])])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .primary])

        work.branch.confirmIntegration()
        await settled(work)
        let parents = try await git("log", "-1", "--format=%P", in: work.path).split(separator: " ")
        #expect(parents.count == 2)
        #expect(try read("NOTES.md", in: work).isEmpty == false)
        #expect(work.branch.finished == "Merged origin/feature")
    }

    @Test func aMergeThatStopsOnAConflictCanBeUndone() async throws {
        let work = try await worktree()
        let tip = try await addConflictingBranch(work)
        #expect(tip != changeTheApp)
        work.branch.askToIntegrate(.merge, ref: "refs/heads/other")
        await settled(work)
        work.branch.confirmIntegration()
        await settled(work)

        let conflict = try #require(work.branch.conflict)
        #expect(conflict.work == .merge)
        #expect(!conflict.startedByPull)
        let dialog = try message(work)
        #expect(dialog.title == "The merge stopped on a conflict")
        #expect(dialog.buttons.map(\.title) == ["Undo the merge", "Resolve"])

        work.branch.undoConflict()
        await settled(work)
        #expect(try await head(work) == changeTheApp)
        #expect(work.branch.finished == "Undid the merge")
    }

    @Test func aMergeWaitsForNothingWhenHeadHasEverything() async throws {
        let work = try await worktree()
        work.branch.askToIntegrate(.merge, ref: "refs/remotes/origin/main")
        await settled(work)
        #expect(work.branch.pendingIntegration == nil)
        #expect(try message(work).title == "Nothing to bring in")
    }

    @Test func aMergeDoesntRunIfHeadMovedWhileItAsked() async throws {
        let work = try await worktree()
        work.branch.askToIntegrate(.merge, ref: originFeature)
        await settled(work)
        // An agent commits while the dialog waits.
        try write("agent\n", to: "README.md", in: work)
        try await git("commit", "--quiet", "--all", "--message=Agent", in: work.path)
        let moved = try await head(work)

        work.branch.confirmIntegration()
        await settled(work)
        #expect(try await head(work) == moved)
        #expect(work.branch.failure?.title == "Can't merge origin/feature into main")
    }

    @Test func changesInTheWayOfAMergeGoAsideAndComeBack() async throws {
        let work = try await worktree()
        try await git("switch", "--quiet", "-c", "readme", addTheApp.hex, in: work.path)
        try write("theirs\n", to: "README.md", in: work)
        try await git("commit", "--quiet", "--all", "--message=Change the readme", in: work.path)
        try await git("switch", "--quiet", "main", in: work.path)
        // The branch changes this file, so git would refuse to merge over it.
        try write("mine\n", to: "README.md", in: work)
        await changedBehindItsBack(work)
        work.branch.askToIntegrate(.merge, ref: "refs/heads/readme")
        await settled(work)
        work.branch.confirmIntegration()
        await settled(work)
        // The merge went through, and the two versions conflict when they come back.
        #expect(try await git("log", "-1", "--format=%P", in: work.path).split(separator: " ").count == 2)
        #expect(work.branch.putBackConflict?.noun == "merge")
    }

    // MARK: Fast-forwarding

    @Test func aFastForwardGoesStraightAway() async throws {
        let work = try await worktree()
        try await git("reset", "--quiet", "--hard", addTheApp.hex, in: work.path)
        await changedBehindItsBack(work)
        #expect(work.model.relation(of: originFeature) == RefRelation(ahead: 1, behind: 0))
        work.branch.askToIntegrate(.fastForward, ref: originFeature)
        await settled(work)
        #expect(work.branch.pendingIntegration == nil)
        #expect(try await head(work) == addNotes)
        #expect(work.branch.finished == "Fast-forwarded to origin/feature")
    }

    @Test func aBranchThatIsntCheckedOutFastForwardsToItsUpstream() async throws {
        let work = try await worktree()
        try await git("branch", "--quiet", "--track", "feature", "origin/feature", in: work.path)
        try await git("update-ref", "refs/heads/feature", addTheApp.hex, in: work.path)
        await changedBehindItsBack(work)
        work.branch.fastForward(branch: "refs/heads/feature", toUpstream: originFeature)
        await settled(work)
        #expect(try await head(work, "refs/heads/feature") == addNotes)
        #expect(try await head(work) == changeTheApp)
    }

    // MARK: Rebasing

    @Test func aRebaseSaysWhatGetsNewHashes() async throws {
        let work = try await worktree()
        work.branch.askToIntegrate(.rebase, ref: originFeature)
        await settled(work)
        let dialog = try message(work)
        #expect(dialog.title == "Rebase main onto origin/feature?")
        #expect(dialog.message?.plain == "main gets origin/feature's commits, and then 1 commit of its own go on top, with new hashes.")
        #expect(dialog.note?.plain == "1 of these is already on its upstream, so pushing afterward will need a force push.")
        #expect(dialog.cards == [[.commit(hash: "da9ff973", subject: "Change the app")]])
        #expect(dialog.terminal == [.command(["rebase", "origin/feature"])])

        work.branch.confirmIntegration()
        await settled(work)
        #expect(try await head(work, "HEAD~1") == addNotes)
        #expect(work.branch.finished == "Rebased onto origin/feature")
    }

    @Test func uncommittedChangesGoAsideForARebaseAndComeBack() async throws {
        let work = try await worktree()
        try write("mine\n", to: "README.md", in: work)
        await changedBehindItsBack(work)
        work.branch.askToIntegrate(.rebase, ref: originFeature)
        await settled(work)
        work.branch.confirmIntegration()
        await settled(work)
        #expect(try await head(work, "HEAD~1") == addNotes)
        #expect(try read("README.md", in: work) == "mine\n")
        #expect(work.branch.finished == "Rebased onto origin/feature · your changes are back")
    }

    @Test func aRebaseThatStopsIsARebaseEvenThoughGitIsPickingACommit() async throws {
        let work = try await worktree()
        _ = try await addConflictingBranch(work)
        work.branch.askToIntegrate(.rebase, ref: "refs/heads/other")
        await settled(work)
        work.branch.confirmIntegration()
        await settled(work)
        let conflict = try #require(work.branch.conflict)
        if case .rebase = conflict.work {} else { Issue.record("It says \(conflict.work).") }
        #expect(try message(work).title == "The rebase stopped on a conflict")
    }

    // MARK: Cherry-picking

    @Test func aPlainCherryPickGoesStraightAwayAndSelectsTheNewCommit() async throws {
        let work = try await worktree()
        work.model.askToCherryPick(commit: addNotes)
        await settled(work)
        #expect(work.model.pendingCherryPick == nil)
        #expect(try await git("log", "-1", "--format=%s", in: work.path) == "Add notes")
        #expect(try await head(work) != addNotes)
        #expect(work.branch.finished == "Cherry-picked b07dd8d5")
        #expect(work.model.selectedCommit.id == (try await head(work)))
    }

    @Test func aCherryPickThatStopsShowsAsPartwayAndCanBeUndone() async throws {
        let work = try await worktree()
        let tip = try await addConflictingBranch(work)
        work.model.askToCherryPick(commit: tip)
        await settled(work)

        #expect(work.branch.conflict?.work == .cherryPick(commit: tip))
        #expect(try message(work).title == "The cherry-pick stopped on a conflict")
        #expect(work.branch.unfinished?.title == "Cherry-picking \(tip.hex.prefix(8)) · 1 conflict")
        #expect(work.branch.unfinished?.work?.abortArguments == ["cherry-pick", "--abort"])

        work.branch.undoConflict()
        await settled(work)
        #expect(try await head(work) == changeTheApp)
        #expect(work.branch.unfinished == nil)
    }

    @Test func aCherryPickFinishedInTheCommitBoxKeepsItsAuthor() async throws {
        let work = try await worktree()
        let tip = try await addConflictingBranch(work)
        work.model.askToCherryPick(commit: tip)
        await settled(work)
        work.branch.conflict = nil
        #expect(work.model.composer.heading.lead == "Commit cherry-pick")
        await work.model.composer.readingMessage?.value
        #expect(work.model.composer.message == "Change it another way")
    }

    @Test func aCommitThatChangesNothingLeavesTheWorktreeAsItWas() async throws {
        let work = try await worktree()
        // The same change as Change the app, on another line.
        try await git("switch", "--quiet", "-c", "same", addTheApp.hex, in: work.path)
        try write("one\ntwo\n", to: "src/app.txt", in: work)
        try await git("commit", "--quiet", "--all", "--message=The same change", in: work.path)
        let same = try await head(work)
        try await git("switch", "--quiet", "main", in: work.path)
        await changedBehindItsBack(work)

        work.model.askToCherryPick(commit: same)
        await settled(work)
        #expect(try await head(work) == changeTheApp)
        #expect(work.branch.failure?.message == "Everything \(same.hex.prefix(8)) changes is already here, so there's nothing to apply.")
        #expect(try await work.model.session.stoppedWork(in: work.path) == nil)
    }

    @Test func aCommitHeadAlreadyHasTakesAClick() async throws {
        let work = try await worktree()
        work.model.askToCherryPick(commit: addTheApp)
        await settled(work)
        let dialog = try message(work)
        #expect(dialog.title == "Cherry-pick \(addTheApp.hex.prefix(8)) into main?")
        #expect(dialog.message?.plain.contains("main already has this commit") == true)
        #expect(dialog.buttons.map(\.pressesWithReturn) == [true, false])
    }

    @Test func aMergeCherryPicksAgainstItsFirstParentAfterAsking() async throws {
        let work = try await worktree()
        try await git("merge", "--quiet", "--no-ff", "--no-edit", "origin/feature", in: work.path)
        let merge = try await head(work)
        try await git("reset", "--quiet", "--hard", changeTheApp.hex, in: work.path)
        await changedBehindItsBack(work)
        work.model.askToCherryPick(commit: merge)
        await settled(work)
        let dialog = try message(work)
        #expect(dialog.terminal == [.command(["cherry-pick", "-m", "1", merge.hex])])
        work.model.confirmCherryPick()
        await settled(work)
        #expect(try read("NOTES.md", in: work).isEmpty == false)
    }

    @Test func somethingStagedGoesAsideForACherryPickAndComesBack() async throws {
        let work = try await worktree()
        try write("mine\n", to: "README.md", in: work)
        try await git("add", "README.md", in: work.path)
        await changedBehindItsBack(work)
        work.model.askToCherryPick(commit: addNotes)
        await settled(work)
        #expect(try await git("log", "-1", "--format=%s", in: work.path) == "Add notes")
        #expect(try await git("diff", "--cached", "--name-only", in: work.path) == "README.md")
        #expect(work.branch.finished == "Cherry-picked b07dd8d5 · your changes are back")
    }

    // MARK: Resetting

    func askToReset(_ work: Worktree, to commit: ObjectID) async throws -> PendingReset {
        work.model.askToReset(to: commit, subject: "A subject")
        await settled(work)
        return try #require(work.model.pendingReset)
    }

    @Test func aResetOffersEveryWayWhenTheBranchIsGoingBack() async throws {
        let work = try await worktree()
        let pending = try await askToReset(work, to: addTheApp)
        #expect(pending.modes == [.keep, .soft, .mixed, .hard])
        let dialog = work.model.dialog(for: pending)
        #expect(dialog.title == "Reset main to \(addTheApp.hex.prefix(8))?")
        #expect(dialog.terminal == [.command(["reset", "--keep", addTheApp.hex])])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .primary])
        guard case .reset = try #require(work.model.dialog) else {
            Issue.record("It isn't the sheet with the choice.")
            return
        }
    }

    @Test func theCommandFollowsWhatsPicked() async throws {
        let work = try await worktree()
        var pending = try await askToReset(work, to: addTheApp)
        for mode in ResetMode.allCases {
            pending.mode = mode
            #expect(work.model.dialog(for: pending).terminal == [.command(["reset", "--\(mode.rawValue)", addTheApp.hex])])
        }
    }

    @Test func theArrowKeysMoveThroughTheWaysAndStopAtTheEnds() async throws {
        let work = try await worktree()
        _ = try await askToReset(work, to: addTheApp)
        work.model.pendingReset?.move(by: -1)
        #expect(work.model.pendingReset?.mode == .keep)
        for _ in 0..<5 { work.model.pendingReset?.move(by: 1) }
        #expect(work.model.pendingReset?.mode == .hard)
        work.model.pendingReset?.move(by: -1)
        #expect(work.model.pendingReset?.mode == .mixed)
    }

    @Test func goingAcrossToAnotherLineOnlyKeepsOrDiscards() async throws {
        let work = try await worktree()
        let pending = try await askToReset(work, to: addNotes)
        #expect(pending.modes == [.keep, .hard])
        #expect(work.model.dialog(for: pending).message?.plain.contains("isn't on main's line") == true)
    }

    @Test func softLeavesTheCommitsChangesStaged() async throws {
        let work = try await worktree()
        _ = try await askToReset(work, to: addTheApp)
        work.model.pendingReset?.mode = .soft
        work.model.confirmReset()
        await settled(work)
        #expect(try await head(work) == addTheApp)
        #expect(try await git("diff", "--cached", "--name-only", in: work.path) == "src/app.txt")
    }

    @Test func mixedLeavesTheCommitsChangesUnstaged() async throws {
        let work = try await worktree()
        _ = try await askToReset(work, to: addTheApp)
        work.model.pendingReset?.mode = .mixed
        work.model.confirmReset()
        await settled(work)
        #expect(try await head(work) == addTheApp)
        #expect(try await git("diff", "--cached", "--name-only", in: work.path).isEmpty)
        #expect(try await git("diff", "--name-only", in: work.path) == "src/app.txt")
    }

    @Test func hardThrowsAwayWhatsUncommittedAndSaysSoInRed() async throws {
        let work = try await worktree()
        try write("mine\n", to: "README.md", in: work)
        await changedBehindItsBack(work)
        var pending = try await askToReset(work, to: addTheApp)
        pending.mode = .hard
        #expect(pending.isDestructive)
        #expect(work.model.dialog(for: pending).buttons.map(\.kind) == [.secondary, .destructive])
        #expect(work.model.dialog(for: pending).note?.plain == "1 file has uncommitted changes.")

        work.model.pendingReset?.mode = .hard
        work.model.confirmReset()
        await settled(work)
        #expect(try await head(work) == addTheApp)
        #expect(try read("README.md", in: work) == "yaga\n")
    }

    @Test func commitsThatWouldBeLostAreListed() async throws {
        let work = try await worktree()
        try write("new\n", to: "README.md", in: work)
        try await git("commit", "--quiet", "--all", "--message=Only here", in: work.path)
        let onlyHere = try await head(work)
        await changedBehindItsBack(work)
        var pending = try await askToReset(work, to: changeTheApp)
        #expect(pending.commits == [ListedCommit(hash: String(onlyHere.hex.prefix(8)), subject: "Only here")])
        #expect(pending.isDestructive)
        pending.mode = .soft
        #expect(!pending.isDestructive)
        #expect(pending.isPartlyDestructive)
    }

    // MARK: Going to a commit, and making things there

    @Test func checkingOutACommitLeavesEveryBranchWhereItIs() async throws {
        let work = try await worktree()
        work.model.checkOutDetached(commit: addTheApp)
        await settled(work)
        #expect(try await head(work) == addTheApp)
        #expect(try await head(work, "refs/heads/main") == changeTheApp)
        #expect(work.model.history?.refs.currentBranch == nil)
    }

    @Test func aNewBranchCanStartAtAnyCommit() async throws {
        let work = try await worktree()
        work.branch.startNewBranch(at: addTheApp, named: "ef4cfd96")
        #expect(work.branch.isCreatingBranch)
        let branch = NewBranch(name: "from-here", startPoint: work.branch.newBranchStart?.commit)
        #expect(branch.arguments == ["switch", "-c", "from-here", addTheApp.hex])
        let refused = await work.branch.create(branch) { _, _ in }
        #expect(refused == nil)
        #expect(try await head(work) == addTheApp)
        #expect(try await git("branch", "--show-current", in: work.path) == "from-here")
    }

    @Test func aTagGoesOnTheCommitAndSaysWhyItCant() async throws {
        let work = try await worktree()
        work.branch.startNewTag(at: addTheApp, named: "ef4cfd96")
        #expect(await work.branch.create(NewTag(name: "v2", commit: addTheApp)) == nil)
        #expect(work.branch.newTagStart == nil)
        #expect(try await head(work, "refs/tags/v2") == addTheApp)

        let refused = await work.branch.create(NewTag(name: "v2", commit: addTheApp))
        #expect(refused?.contains("already exists") == true)
    }

    @Test func aBranchThatsNeverBeenPushedGetsAnUpstream() async throws {
        let work = try await worktree()
        // A remote of its own to push to, since every test clones the fixture.
        let remote = try makeTemporaryFolder() + "/remote.git"
        try await git("clone", "--quiet", "--bare", "--no-local", try await Fixture.repository("basic"), remote, in: work.path)
        try await git("remote", "set-url", "origin", remote, in: work.path)
        try await git("branch", "--quiet", "other", addTheApp.hex, in: work.path)
        await changedBehindItsBack(work)
        work.branch.push(branch: "refs/heads/other", upstream: nil)
        await settled(work)
        #expect(try await head(work, "refs/remotes/origin/other") == addTheApp)
        #expect(try await git("config", "branch.other.remote", in: work.path) == "origin")
    }

    // MARK: Choosing a remote

    @Test func aBranchFollowsTheRemoteThatsChosen() async throws {
        let work = try await worktree()
        let main = "refs/heads/main"
        let onFork = "refs/remotes/fork/main"
        try await git("remote", "add", "fork", "https://example.com/fork.git", in: work.path)
        try await git("remote", "add", "empty", "https://example.com/empty.git", in: work.path)
        try await git("update-ref", onFork, changeTheApp.hex, in: work.path)
        await changedBehindItsBack(work)
        #expect(work.model.remoteNames == ["empty", "fork", "origin"])
        #expect(work.model.relation(of: main)?.remote == "origin")

        work.model.setUpstream(of: main, to: "fork")
        await settled(work)
        await work.model.refRelationsUpdate?.value
        #expect(try await git("config", "branch.main.remote", in: work.path) == "fork")
        #expect(try await git("config", "branch.main.pushRemote", in: work.path) == "fork")
        #expect(work.model.relation(of: main)?.upstream?.name == onFork)
        #expect(work.branch.status?.upstream == onFork)

        // That remote hasn't got the branch, so its first push goes there.
        work.model.setUpstream(of: main, to: "empty")
        await settled(work)
        await work.model.refRelationsUpdate?.value
        #expect(try await git("config", "branch.main.pushRemote", in: work.path) == "empty")
        #expect(work.model.relation(of: main)?.upstream == nil)
        #expect(work.model.relation(of: main)?.remote == "empty")
        #expect(work.branch.status?.push == .firstTime(remote: "empty"))
    }

    // MARK: Adding and removing remotes

    @Test func aNewRemoteKeepsBothURLsAndShowsItsBranches() async throws {
        let work = try await worktree()
        let source = try await Fixture.repository("basic")
        work.branch.add(NewRemote(name: "fork", url: source, pushURL: "https://example.com/push.git"))
        #expect(work.branch.remoteDraft == nil)
        await settled(work)
        await work.model.refRelationsUpdate?.value
        #expect(work.branch.failure == nil)
        #expect(try await git("config", "remote.fork.url", in: work.path) == source)
        #expect(try await git("config", "remote.fork.pushurl", in: work.path) == "https://example.com/push.git")
        #expect(try await head(work, "refs/remotes/fork/main") == changeTheApp)
        #expect(work.model.remoteNames == ["fork", "origin"])
    }

    @Test func aRemoteThatCantBeFetchedStaysAndTheDialogSaysSo() async throws {
        let work = try await worktree()
        work.branch.add(NewRemote(name: "fork", url: try makeTemporaryFolder() + "/nothing-here.git"))
        await settled(work)
        await work.model.refRelationsUpdate?.value
        #expect(work.branch.failure?.title == "Added fork, but can't fetch from it")
        #expect(work.model.remoteNames == ["fork", "origin"])
    }

    @Test func gitsRefusalToAddARemoteChangesNothing() async throws {
        let work = try await worktree()
        work.branch.add(NewRemote(name: "a..b", url: "https://example.com/a.git"))
        await settled(work)
        #expect(work.branch.failure?.title == "Can't add a..b")
        #expect(work.branch.failure?.changedNothing == true)
    }

    @Test func removingARemoteSaysWhoUsesItAndTakesItsBranches() async throws {
        let work = try await worktree()
        let main = "refs/heads/main"
        let remote = RemoteDetails(name: "origin", address: "example.com", branches: [
            RemoteBranchDetails(name: "refs/remotes/origin/main", tip: changeTheApp),
            RemoteBranchDetails(name: originFeature, tip: addNotes),
        ])
        #expect(work.model.relation(of: main)?.remote == "origin")
        work.model.askToRemove(remote: remote)
        let removal = try #require(work.branch.remoteRemoval)
        #expect(removal.name == "origin")
        #expect(removal.branchCount == 2)
        #expect(removal.branches == ["main"])

        let dialog = work.branch.dialog(for: removal)
        #expect(dialog.title == "Remove origin?")
        #expect(dialog.terminal == [.command(["remote", "remove", "origin"])])
        #expect(dialog.cards == [[.heading("This branch stops pushing and pulling there", isLost: false), .name("main")]])

        work.branch.confirmRemoteRemoval()
        await settled(work)
        await work.model.refRelationsUpdate?.value
        #expect(work.branch.remoteRemoval == nil)
        #expect(work.branch.failure == nil)
        #expect(try await git("remote", in: work.path) == "")
        #expect(work.model.remoteNames == [])
        #expect(work.model.relation(of: main)?.upstream == nil)
    }

    @Test func theAddDialogFillsInItsCommandsAndHoldsBackUntilItsRight() async throws {
        let work = try await worktree()
        let empty = work.branch.dialog(for: .init(), among: ["origin"])
        #expect(empty.buttons.last?.isEnabled == false)
        #expect(empty.terminal.first == .command(["remote", "add", "name", "url"]))

        let taken = work.branch.dialog(for: .init(name: "origin", url: "a"), among: ["origin"])
        #expect(taken.buttons.last?.isEnabled == false)
        #expect(taken.note?.plain == "origin is already a remote.")

        let ready = work.branch.dialog(for: .init(name: " fork ", url: "a", pushURL: "b"), among: ["origin"])
        #expect(ready.buttons.last?.isEnabled == true)
        #expect(ready.terminal == [
            .command(["remote", "add", "fork", "a"]),
            .command(["remote", "set-url", "--push", "fork", "b"]),
            .command(["fetch", "fork"]),
        ])
    }

    @Test func theAddButtonUsesWhatsTypedWhenItsPressedNotWhenItWasMade() async throws {
        let work = try await worktree()
        let source = try await Fixture.repository("basic")
        work.branch.remoteDraft = .init(name: "fork", url: "/")
        let draft = try #require(work.branch.remoteDraft)
        let early = try #require(work.branch.dialog(for: draft, among: ["origin"]).buttons.last)
        #expect(early.isEnabled)
        work.branch.remoteDraft?.url = source
        early.action()
        await settled(work)
        #expect(try await git("config", "remote.fork.url", in: work.path) == source)
    }

    // MARK: The menu in place

    func titles(_ entries: [RefMenu.Entry]) -> [String] {
        entries.compactMap { entry in
            switch entry {
            case let .command(title, _, _, _, _): title.plain
            case let .submenu(title, _, _, _): title.plain
            default: nil
            }
        }
    }

    @Test func theMenuForTheCurrentBranchsRowUsesWhatsKnown() async throws {
        let work = try await worktree()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("HistoryActionsTests." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let row = try #require((0..<work.model.rowCount).first { work.model.commit(atRow: $0) == changeTheApp })
        let entries = work.model.menuEntries(forRow: row, badge: nil, pasteboard: pasteboard) { _, _ in }
        #expect(titles(entries).prefix(3) == ["Pull", "Push", "Fetch"])
    }

    @Test func theMenuForAnotherBranchKnowsHowItStands() async throws {
        let work = try await worktree()
        let row = try #require((0..<work.model.rowCount).first { work.model.commit(atRow: $0) == addNotes })
        let entries = work.model.menuEntries(forRow: row, badge: nil) { _, _ in }
        #expect(titles(entries).prefix(3) == ["Check out", "Merge origin/feature into main…", "Rebase main onto origin/feature…"])
        #expect(titles(entries).contains("Cherry-pick into main"))
    }

    @Test func aCommitOnHeadsLineHasNothingToCherryPick() async throws {
        let work = try await worktree()
        let row = try #require((0..<work.model.rowCount).first { work.model.commit(atRow: $0) == addTheApp })
        #expect(work.model.headContains(row: row) == true)
        #expect(!titles(work.model.menuEntries(forRow: row, badge: nil) { _, _ in }).contains("Cherry-pick into main"))
    }

    @Test func theRowForUncommittedChangesOffersToDiscardThem() async throws {
        let work = try await worktree()
        try write("mine\n", to: "README.md", in: work)
        await changedBehindItsBack(work)
        #expect(titles(work.model.menuEntries(forRow: 0, badge: nil) { _, _ in }) == ["Discard all changes…"])
    }

    @Test func aBranchInTheRefsPanelHasTheSameRows() async throws {
        let work = try await worktree()
        let entries = work.model.menuEntries(
            forBranch: originFeature,
            tip: addNotes,
            delete: HistoryMenu.Delete(title: "Delete from remote…", isEnabled: true) {}
        ) { _, _ in }
        #expect(titles(entries).prefix(3) == ["Check out", "Merge origin/feature into main…", "Rebase main onto origin/feature…"])
        #expect(titles(entries).last == "Delete from remote…")
    }
}
