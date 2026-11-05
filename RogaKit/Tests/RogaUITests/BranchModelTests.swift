import CommitGraph
import Foundation
import GitCore
import GitRunner
import HistoryUI
import RepositoryEngine
import TestSupport
import Testing
@testable import RogaUI

/// The branch in the title row, between clones of a bare copy of the `basic`
/// repository. `other` stands for someone else pushing to the remote.
@Suite(.timeLimit(.minutes(1)))
struct BranchModelTests {
    struct Clones {
        var folder: String
        var remote: String
        var work: String
        var other: String
        var session: RepositorySession
    }

    @discardableResult
    func git(_ arguments: String..., in folder: String) async throws -> String {
        try await TestGit.make().text(GitCommand(arguments, in: folder))
    }

    func clones() async throws -> Clones {
        let fixture = try await Fixture.repository("basic")
        let folder = FileManager.default.temporaryDirectory.appending(path: "roga-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = try #require(realpath(folder.path(percentEncoded: false), nil))
        defer { free(path) }
        let root = String(cString: path)
        try await git("clone", "--quiet", "--bare", "--no-local", fixture, root + "/remote.git", in: fixture)
        try await git("clone", "--quiet", root + "/remote.git", root + "/work", in: root)
        try await git("clone", "--quiet", root + "/remote.git", root + "/other", in: root)
        for clone in ["work", "other"] {
            try await git("config", "user.name", "T", in: root + "/" + clone)
            try await git("config", "user.email", "t@example.com", in: root + "/" + clone)
        }
        let session = try await RepositorySession.open(containing: root + "/work", git: try await TestGit.make())
        return Clones(folder: root, remote: root + "/remote.git", work: root + "/work", other: root + "/other", session: session)
    }

    func model(_ clones: Clones, fetches: Bool = true) -> RepositoryModel {
        let model = RepositoryModel(session: clones.session, worktree: clones.work, fetchesByItself: { fetches })
        // Most tests have no reason to wait for the house.
        model.branch.timeToPlayHouse = { _ in .zero }
        return model
    }

    @discardableResult
    func commit(_ message: String, in folder: String, file: String? = nil, text: String = "") async throws -> String {
        if let file { try text.write(toFile: folder + "/" + file, atomically: true, encoding: .utf8) }
        try await git("add", "--all", in: folder)
        try await git("commit", "--quiet", "--allow-empty", "-m", message, in: folder)
        return try await git("rev-parse", "HEAD", in: folder)
    }

    func pushFromOther(_ clones: Clones, file: String? = nil, text: String = "") async throws {
        try await commit("From someone else", in: clones.other, file: file, text: text)
        try await git("push", "--quiet", in: clones.other)
    }

    // MARK: Fetching by itself

    @Test func fetchingByItselfBringsInACountAndTheCommits() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        let model = model(clones)
        await model.appear()
        await model.branch.quietFetch?.value
        await model.check?.value
        #expect(model.branch.status?.behind == 1)
        #expect(model.branch.fetchRecord.lastFetched != nil)
        // A remote branch moved, so history loads again to show its commit.
        await model.load()
        #expect(model.history?.refs.refs.contains { $0.name == "refs/remotes/origin/main" } == true)
        #expect(model.rowCount == model.history?.rows.count)
    }

    @Test func doesntFetchWhenItsTurnedOff() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        let model = model(clones, fetches: false)
        await model.appear()
        #expect(model.branch.quietFetch == nil)
        model.becameActive()
        #expect(model.branch.quietFetch == nil)
        await model.check?.value
        #expect(model.branch.status?.behind == 0)
    }

    @Test func doesntFetchWithoutARemote() async throws {
        let clones = try await clones()
        try await git("remote", "remove", "origin", in: clones.work)
        let model = model(clones)
        await model.appear()
        #expect(model.branch.status?.remote == nil)
        #expect(model.branch.quietFetch == nil)
    }

    @Test func aFailedFetchInterruptsNobody() async throws {
        let clones = try await clones()
        try await git("remote", "set-url", "origin", clones.folder + "/gone.git", in: clones.work)
        let model = model(clones)
        await model.appear()
        await model.branch.quietFetch?.value
        #expect(model.branch.failure == nil)
        #expect(model.branch.fetchRecord.failure != nil)
        #expect(model.branch.summary().hasPrefix("couldn't reach origin"))
    }

    // MARK: Pulling

    @Test func pullsAndSaysSo() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        let model = model(clones)
        await model.appear()
        await model.branch.quietFetch?.value
        await model.check?.value

        model.branch.pull()
        #expect(model.branch.action == .pulling)
        await model.branch.running?.value
        #expect(model.branch.action == nil)
        #expect(model.branch.finished == "Pulled")
        await model.check?.value
        #expect(model.branch.status?.behind == 0)
    }

    @Test func nothingElseRunsUntilItFinishes() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        let model = model(clones)
        await model.appear()
        await model.branch.quietFetch?.value
        await model.check?.value

        model.branch.pull()
        let running = model.branch.running
        model.branch.fetch()
        #expect(model.branch.action == .pulling)
        #expect(model.branch.running == running)
        await running?.value
    }

    @Test func refusesToPullWhileCheckingOut() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        let model = model(clones)
        await model.appear()
        await model.branch.quietFetch?.value
        await model.check?.value
        model.branch.isCheckingOut = { true }
        model.branch.pull()
        #expect(model.branch.action == nil)
    }

    @Test func offersToUndoAPullThatHitAConflict() async throws {
        let clones = try await clones()
        try await pushFromOther(clones, file: "conflict.txt", text: "theirs\n")
        let mine = try await commit("Mine", in: clones.work, file: "conflict.txt", text: "mine\n")
        let model = model(clones)
        await model.appear()

        model.branch.pull(.merge)
        await model.branch.running?.value
        #expect(model.branch.failure == nil)
        #expect(model.branch.conflict == BranchModel.Conflict(pull: .merge, files: ["conflict.txt"], ran: ["pull", "--no-rebase", "--ff"]))

        model.branch.undoPull()
        await model.branch.running?.value
        #expect(model.branch.conflict == nil)
        #expect(try await git("rev-parse", "HEAD", in: clones.work) == mine)
        #expect(try await clones.session.stoppedWork(in: clones.work) == nil)
    }

    // MARK: Choosing how to pull

    /// Clones where `main` and `origin/main` have moved apart, as Roga knows it.
    private func divergedModel(_ clones: Clones) async throws -> RepositoryModel {
        try await pushFromOther(clones, file: "theirs.txt", text: "theirs\n")
        try await commit("Mine", in: clones.work, file: "mine.txt", text: "mine\n")
        try await git("fetch", "--quiet", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()
        #expect(model.branch.status?.hasDiverged == true)
        return model
    }

    private func dialogContent(_ model: RepositoryModel) throws -> DialogContent {
        guard case .message(let content) = try #require(model.dialog) else {
            Issue.record("Expected a dialog with a message")
            throw CancellationError()
        }
        return content
    }

    @Test func asksHowToPullWhenTheConfigDoesntSay() async throws {
        let clones = try await clones()
        let model = try await divergedModel(clones)
        model.branch.pull()
        #expect(model.branch.action == nil)
        #expect(model.branch.pullChoice == PullChoice(branch: "main", upstream: "origin/main", behind: 1, ahead: 1))
        #expect(model.dialog?.id == "pull")

        model.dialog?.dismiss()
        #expect(model.branch.pullChoice == nil)
        #expect(model.dialog == nil)
        #expect(model.branch.status?.hasDiverged == true)
    }

    @Test func doesntAskWhenTheConfigSays() async throws {
        let clones = try await clones()
        try await git("config", "pull.rebase", "true", in: clones.work)
        let model = try await divergedModel(clones)
        model.branch.pull()
        #expect(model.branch.pullChoice == nil)
        await model.branch.running?.value
        #expect(model.branch.finished == "Pulled")
    }

    @Test func theCommandAndTheButtonFollowWhatsPicked() async throws {
        let clones = try await clones()
        let model = try await divergedModel(clones)
        var choice = PullChoice(branch: "main", upstream: "origin/main", behind: 3, ahead: 1)

        let rebase = model.branch.dialog(for: choice)
        #expect(rebase.title == "Pull 3 commits into main")
        // The empty line is room for the one that remembering adds.
        #expect(rebase.terminal == [.command(["pull", "--rebase"]), .blank])
        #expect(CommandBlock.copied(rebase.terminal) == "git pull --rebase")
        #expect(rebase.buttons.last?.title == "Rebase")
        #expect(rebase.buttons.last?.kind == .primary)

        choice.pick = .merge
        choice.remembers = true
        let merge = model.branch.dialog(for: choice)
        #expect(merge.terminal == [.command(["config", "pull.rebase", "false"]), .command(["pull", "--no-rebase", "--ff"])])
        #expect(merge.buttons.last?.title == "Merge")
    }

    /// A keyboard shortcut can hold on to a button's older action, so the action
    /// has to read what's picked when it runs, rather than when it was made.
    @Test func aButtonMadeBeforeTheToggleChangedStillRemembers() async throws {
        let clones = try await clones()
        let model = try await divergedModel(clones)
        model.branch.pull()
        let choice = try #require(model.branch.pullChoice)
        let stale = try #require(model.branch.dialog(for: choice).buttons.last)
        model.branch.pullChoice?.pick = .merge
        model.branch.pullChoice?.remembers = true
        stale.action()
        await model.branch.running?.value
        #expect(try await git("config", "--get", "pull.rebase", in: clones.work) == "false")
    }

    @Test func oneCommitIsSaidAsOne() async throws {
        let clones = try await clones()
        let model = try await divergedModel(clones)
        let choice = PullChoice(branch: "main", upstream: "origin/main", behind: 1, ahead: 1)
        let dialog = model.branch.dialog(for: choice)
        #expect(dialog.title == "Pull 1 commit into main")
        #expect(dialog.message?.plain == "main and origin/main have moved apart. origin/main has 1 commit that main doesn't, and main has 1 of its own.")
    }

    @Test func pullingWithoutRememberingLeavesTheConfigAlone() async throws {
        let clones = try await clones()
        let model = try await divergedModel(clones)
        model.branch.pull()
        model.branch.confirmPull()
        #expect(model.branch.pullChoice == nil)
        await model.branch.running?.value
        #expect(model.branch.finished == "Pulled")
        await model.check?.value
        #expect(model.branch.status?.behind == 0)
        #expect(model.branch.status?.pullRebase == nil)
    }

    @Test func rememberingWritesTheConfigSoItDoesntAskAgain() async throws {
        let clones = try await clones()
        let model = try await divergedModel(clones)
        model.branch.pull()
        model.branch.pullChoice?.pick = .merge
        model.branch.pullChoice?.remembers = true
        model.branch.confirmPull()
        await model.branch.running?.value
        #expect(model.branch.finished == "Pulled")
        #expect(try await git("config", "--get", "pull.rebase", in: clones.work) == "false")
        #expect(try await git("rev-list", "--count", "--merges", "HEAD~1..HEAD", in: clones.work) == "1")

        // Moving apart again now goes straight to what was remembered.
        try await pushFromOther(clones, file: "theirs2.txt", text: "theirs\n")
        try await commit("Mine again", in: clones.work, file: "mine2.txt", text: "mine\n")
        try await git("fetch", "--quiet", in: clones.work)
        await model.branch.refresh()
        #expect(model.branch.status?.hasDiverged == true)
        model.branch.pull()
        #expect(model.branch.pullChoice == nil)
        #expect(model.branch.action == .pulling)
        await model.branch.running?.value
    }

    @Test func aPullThatCantWriteTheConfigSaysSo() async throws {
        let clones = try await clones()
        let model = try await divergedModel(clones)
        // git writes its config by renaming a lock file, which this gets in the way of.
        try "".write(toFile: clones.work + "/.git/config.lock", atomically: true, encoding: .utf8)
        model.branch.pull()
        model.branch.pullChoice?.remembers = true
        model.branch.confirmPull()
        await model.branch.running?.value
        #expect(model.branch.failure?.title == "Can't pull main")
        #expect(model.branch.failure?.command == ["config", "pull.rebase", "true"])
        #expect(model.branch.status?.hasDiverged == true)
        try FileManager.default.removeItem(atPath: clones.work + "/.git/config.lock")
    }

    // MARK: What the dialogs say

    @Test func aFailureShowsWhatRanAndWhatGitSaid() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        try await commit("Mine", in: clones.work)
        let model = model(clones)
        await model.appear()
        model.branch.pull(.fastForward)
        await model.branch.running?.value
        let dialog = try dialogContent(model)
        #expect(dialog.title == "Can't pull main")
        #expect(dialog.message?.plain == "Nothing changed. What git said is below.")
        #expect(dialog.terminal.first == .ran(["pull", "--ff-only"]))
        guard case .output(let said) = dialog.terminal.last else {
            Issue.record("Expected what git said")
            return
        }
        #expect(said == model.branch.failure?.message)
        #expect(dialog.buttons.map(\.title) == ["OK"])
        dialog.buttons[0].action()
        #expect(model.branch.failure == nil)
    }

    /// Other code can say something went wrong with only words.
    @Test func aFailureWithOnlyWordsShowsNoTerminal() async throws {
        let clones = try await clones()
        let model = model(clones, fetches: false)
        model.branch.failure = BranchModel.Failure(title: "Can't stage", message: "Something happened.")
        let dialog = try dialogContent(model)
        #expect(dialog.terminal.isEmpty)
        #expect(dialog.message?.plain == "Something happened.")
    }

    @Test func aConflictListsItsFilesAndShowsWhatUndoingRuns() async throws {
        let clones = try await clones()
        let model = model(clones, fetches: false)
        let files = (1...7).map { "file\($0).txt" }
        model.branch.conflict = BranchModel.Conflict(pull: .rebase(branch: "refs/heads/main"), files: files, ran: ["pull", "--rebase"])
        let dialog = try dialogContent(model)
        #expect(dialog.title == "The pull stopped on a conflict")
        #expect(dialog.message?.plain.hasPrefix("main is partway through a rebase, with 7 files in conflict.") == true)
        #expect(dialog.cards.first?.count == 6)
        #expect(dialog.cards.first?.last == .more("and 2 more"))
        #expect(dialog.terminal == [
            .ran(["pull", "--rebase"]),
            .gap,
            .comment("Undo the pull runs"),
            .command(["rebase", "--abort"]),
        ])
        #expect(CommandBlock.copied(dialog.terminal) == "git rebase --abort")
        #expect(dialog.buttons.map(\.title) == ["Leave it", "Undo the pull"])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .primary])
        dialog.dismiss()
        #expect(model.branch.conflict == nil)
    }

    @Test func abortingSaysWhatItLosesAndTheCommand() async throws {
        let clones = try await clones()
        let model = model(clones, fetches: false)
        model.branch.pendingAbort = .merge
        let dialog = try dialogContent(model)
        #expect(dialog.title == "Abort the merge?")
        #expect(dialog.terminal == [.command(["merge", "--abort"])])
        #expect(dialog.buttons.map(\.title) == ["Cancel", "Abort merge"])
        #expect(dialog.buttons.last?.kind == .destructive)
        dialog.dismiss()
        #expect(model.branch.pendingAbort == nil)
    }

    @Test func aForcePushSaysWhatItOverwritesWithHashes() async throws {
        let clones = try await clones()
        let model = model(clones, fetches: false)
        let commits = [ListedCommit(hash: "8f3c1d20", subject: "First try")]
        model.branch.forcePush = BranchModel.ForcePush(branch: "main", upstream: "origin/main", count: 3, commits: commits)
        let dialog = try dialogContent(model)
        #expect(dialog.title == "Force push main?")
        #expect(dialog.message?.plain == "This overwrites 3 commits on origin/main, and your branch takes their place.")
        #expect(dialog.cards == [[.commit(hash: "8f3c1d20", subject: "First try"), .more("and 2 more")]])
        #expect(dialog.note?.plain == "git refuses if origin/main has commits that main never had.")
        #expect(dialog.terminal == [.command(["push", "--force-with-lease", "--force-if-includes"])])
        #expect(dialog.buttons.last?.kind == .destructive)
    }

    @Test func aForcePushThatLosesNothingSaysSo() async throws {
        let clones = try await clones()
        let model = model(clones, fetches: false)
        model.branch.forcePush = BranchModel.ForcePush(branch: "main", upstream: "origin/main", count: 0, commits: [])
        let dialog = try dialogContent(model)
        #expect(dialog.message?.plain.hasSuffix("so none are lost.") == true)
        #expect(dialog.cards.isEmpty)
    }

    @Test func deletingABranchSaysWhatItLosesAndShowsItsCommand() async throws {
        let clones = try await clones()
        _ = try await makeBranchWithACommit("other", clones)
        let model = model(clones, fetches: false)
        await model.appear()
        await askToDelete("refs/heads/other", model)
        let dialog = try dialogContent(model)
        #expect(dialog.title == "Delete other?")
        #expect(dialog.message?.plain == "1 commit isn't on any other branch or tag, so it goes too.")
        #expect(dialog.terminal == [.command(["branch", "-D", "other"])])
        #expect(dialog.cards.first?.count == 1)
        dialog.dismiss()
        #expect(model.branch.pendingDeletion == nil)
        #expect(try await exists("refs/heads/other", in: clones.work))
    }

    @Test func deletingFromARemoteSaysWhoItAffects() async throws {
        let clones = try await clones()
        try await git("branch", "--track", "feature", "origin/feature", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()
        await askToDelete("refs/remotes/origin/feature", model)
        let dialog = try dialogContent(model)
        #expect(dialog.title == "Delete feature from origin?")
        #expect(dialog.message?.plain == "This deletes the branch on origin, for everyone who uses it. Its commits are all on other branches or tags, so none are lost.")
        #expect(dialog.terminal == [.command(["push", "--delete", "origin", "refs/heads/feature"])])
    }

    // MARK: Going to a commit

    /// A loaded model of `work`, whose branch has all the commits on it pushed, and
    /// then `unpushed` more.
    private func modelToGoBack(_ clones: Clones, unpushed: Int = 0) async throws -> RepositoryModel {
        for number in 0..<unpushed { try await commit("Unpushed \(number)", in: clones.work) }
        let model = model(clones, fetches: false)
        await model.appear()
        return model
    }

    /// The row of a commit, by a revision that leads to it.
    private func row(_ revision: String, in clones: Clones, of model: RepositoryModel) async throws -> Int {
        let id = try #require(ObjectID(hex: try await git("rev-parse", revision, in: clones.work)))
        let history = try #require(model.history)
        let position = try #require(history.graph.position(of: id))
        return try #require(history.rows.firstIndex(of: position))
    }

    private func finishGoing(_ model: RepositoryModel) async {
        await model.checkout?.value
        await model.branch.running?.value
        await model.check?.value
        await model.load()
    }

    private func notInAnotherWorktree(_ folder: String, _ commit: ObjectID?) {
        Issue.record("It's not in another worktree.")
    }

    @Test func goesBackStraightAwayWhenEverythingIsPushed() async throws {
        let clones = try await clones()
        let model = try await modelToGoBack(clones)
        let target = try await git("rev-parse", "HEAD~1", in: clones.work)

        model.goToRow(try await row("HEAD~1", in: clones, of: model), showWorktree: notInAnotherWorktree)
        await finishGoing(model)

        #expect(model.dialog == nil)
        #expect(try await git("rev-parse", "HEAD", in: clones.work) == target)
        #expect(model.headDescription == "main")
        #expect(model.branch.status?.behind == 1)
        #expect(model.selectedCommit.id?.hex == target)
    }

    @Test func asksBeforeLosingCommitsThatArentPushed() async throws {
        let clones = try await clones()
        let model = try await modelToGoBack(clones, unpushed: 2)
        let tip = try await git("rev-parse", "HEAD", in: clones.work)
        let target = try await git("rev-parse", "origin/main", in: clones.work)

        model.goToRow(try await row("origin/main", in: clones, of: model), showWorktree: notInAnotherWorktree)
        await model.checkout?.value

        let dialog = try dialogContent(model)
        let short = String(target.prefix(8))
        #expect(dialog.title == "Reset main to \(short)?")
        #expect(dialog.message?.plain == "main moves to \(short). 2 commits aren't on a remote, another branch or a tag, so they would be lost.")
        #expect(dialog.cards.first?.count == 2)
        #expect(dialog.buttons.map(\.title) == ["Cancel", "Reset anyway", "Push, then reset"])
        #expect(dialog.buttons[1].kind == .destructive)
        #expect(dialog.buttons[2].kind == .primary)
        #expect(dialog.terminal == [.comment("Reset anyway skips the push"), .command(["push"]), .command(["reset", "--keep", target])])
        #expect(try await git("rev-parse", "HEAD", in: clones.work) == tip)
        #expect(CommandBlock.copied(dialog.terminal) == "git push\ngit reset --keep \(target)")

        dialog.dismiss()
        #expect(model.dialog == nil)
        #expect(try await git("rev-parse", "HEAD", in: clones.work) == tip)
    }

    @Test func saysOneCommitIsLost() async throws {
        let clones = try await clones()
        let model = try await modelToGoBack(clones, unpushed: 1)
        model.goToRow(try await row("origin/main", in: clones, of: model), showWorktree: notInAnotherWorktree)
        await model.checkout?.value
        let dialog = try dialogContent(model)
        #expect(dialog.message?.plain.hasSuffix("1 commit isn't on a remote, another branch or a tag, so it would be lost.") == true)
        #expect(dialog.note?.plain == "git reflog can still find it for a while.")
    }

    @Test func resetsAnywayWhenAsked() async throws {
        let clones = try await clones()
        let model = try await modelToGoBack(clones, unpushed: 2)
        let target = try await git("rev-parse", "origin/main", in: clones.work)
        model.goToRow(try await row("origin/main", in: clones, of: model), showWorktree: notInAnotherWorktree)
        await model.checkout?.value

        try dialogContent(model).buttons[1].action()
        #expect(model.dialog == nil)
        await finishGoing(model)

        #expect(try await git("rev-parse", "HEAD", in: clones.work) == target)
        #expect(model.branch.status?.ahead == 0)
        // Nothing leads to them any more, so history has let them go.
        #expect(model.history?.rows.count == 4)
    }

    @Test func pushesThenResetsWhenAsked() async throws {
        let clones = try await clones()
        let model = try await modelToGoBack(clones, unpushed: 2)
        let tip = try await git("rev-parse", "HEAD", in: clones.work)
        let target = try await git("rev-parse", "origin/main", in: clones.work)
        model.goToRow(try await row("origin/main", in: clones, of: model), showWorktree: notInAnotherWorktree)
        await model.checkout?.value

        try dialogContent(model).buttons[2].action()
        #expect(model.branch.action == .pushing)
        await finishGoing(model)

        #expect(model.dialog == nil)
        #expect(try await git("rev-parse", "HEAD", in: clones.work) == target)
        #expect(try await git("rev-parse", "main", in: clones.remote) == tip)
        #expect(model.branch.status?.behind == 2)
        #expect(model.branch.status?.ahead == 0)
    }

    @Test func aRefusedPushLeavesTheBranchWhereItWas() async throws {
        let clones = try await clones()
        let model = try await modelToGoBack(clones, unpushed: 1)
        let tip = try await git("rev-parse", "HEAD", in: clones.work)
        model.goToRow(try await row("origin/main", in: clones, of: model), showWorktree: notInAnotherWorktree)
        await model.checkout?.value
        // Someone pushes after the counts were read, so the remote rejects this.
        try await pushFromOther(clones)

        try dialogContent(model).buttons[2].action()
        await finishGoing(model)

        let dialog = try dialogContent(model)
        #expect(dialog.title == "Can't push main")
        #expect(try await git("rev-parse", "HEAD", in: clones.work) == tip)
    }

    @Test func saysThePushWentThroughWhenTheResetDoesnt() async throws {
        let clones = try await clones()
        let model = try await modelToGoBack(clones, unpushed: 1)
        model.goToRow(try await row("HEAD~1", in: clones, of: model), showWorktree: notInAnotherWorktree)
        await model.checkout?.value
        // A commit made while the dialog waits.
        let new = try await commit("Made meanwhile", in: clones.work)

        try dialogContent(model).buttons[2].action()
        await finishGoing(model)

        let dialog = try dialogContent(model)
        #expect(dialog.title.hasPrefix("Can't reset main to"))
        #expect(dialog.message?.plain == "The push went through, but main is still where it was. Something else has moved HEAD since Roga counted what this would lose, so Roga left it there.")
        #expect(dialog.terminal.isEmpty)
        #expect(try await git("rev-parse", "HEAD", in: clones.work) == new)
    }

    @Test func saysWhatGitSaidWhenItRefusesTheResetAfterThePush() async throws {
        let clones = try await clones()
        let tip = try await commit("Mine", in: clones.work, file: "mine.txt", text: "One\n")
        let model = try await modelToGoBack(clones)
        let target = try await git("rev-parse", "HEAD~1", in: clones.work)
        model.goToRow(try await row("HEAD~1", in: clones, of: model), showWorktree: notInAnotherWorktree)
        await model.checkout?.value
        // A change that the reset would have to overwrite.
        try "Two\n".write(toFile: clones.work + "/mine.txt", atomically: true, encoding: .utf8)

        try dialogContent(model).buttons[2].action()
        await finishGoing(model)

        let dialog = try dialogContent(model)
        #expect(dialog.title == "Can't reset main to \(target.prefix(8))")
        #expect(dialog.message?.plain == "The push went through, but main is still where it was. What git said is below.")
        #expect(dialog.terminal.first == .ran(["reset", "--keep", target]))
        #expect(try await git("rev-parse", "HEAD", in: clones.work) == tip)
        #expect(try await git("rev-parse", "main", in: clones.remote) == tip)
    }

    @Test func doesntOfferAPushGitWouldReject() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        try await git("fetch", "--quiet", in: clones.work)
        let model = try await modelToGoBack(clones, unpushed: 1)
        #expect(model.branch.status?.hasDiverged == true)

        model.goToRow(try await row("origin/main", in: clones, of: model), showWorktree: notInAnotherWorktree)
        await model.checkout?.value

        let dialog = try dialogContent(model)
        #expect(dialog.buttons.map(\.title) == ["Cancel", "Reset anyway"])
        #expect(dialog.note?.plain.contains("git would reject it: origin/main has commits that main doesn't.") == true)
        #expect(dialog.terminal.count == 1)
    }

    @Test func doesntOfferAPushWithoutARemote() async throws {
        let clones = try await clones()
        try await git("remote", "remove", "origin", in: clones.work)
        let model = try await modelToGoBack(clones, unpushed: 1)
        model.goToRow(try await row("HEAD~1", in: clones, of: model), showWorktree: notInAnotherWorktree)
        await model.checkout?.value
        #expect(try dialogContent(model).buttons.map(\.title) == ["Cancel", "Reset anyway"])
    }

    @Test func aRowWithAnotherBranchGoesToThatBranch() async throws {
        let clones = try await clones()
        try await git("branch", "older", "HEAD~1", in: clones.work)
        let model = try await modelToGoBack(clones, unpushed: 1)
        let tip = try await git("rev-parse", "main", in: clones.work)

        model.goToRow(try await row("older", in: clones, of: model), showWorktree: notInAnotherWorktree)
        await finishGoing(model)

        #expect(model.dialog == nil)
        #expect(model.headDescription == "older")
        #expect(try await git("rev-parse", "main", in: clones.work) == tip)
    }

    @Test func aCommitOnAnotherLineDetachesAndLeavesTheBranch() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--create", "side", "HEAD~1", in: clones.work)
        let onSide = try await commit("On side", in: clones.work)
        try await commit("Further on side", in: clones.work)
        try await git("switch", "--quiet", "main", in: clones.work)
        let tip = try await git("rev-parse", "main", in: clones.work)
        let model = try await modelToGoBack(clones, unpushed: 1)

        model.goToRow(try await row(onSide, in: clones, of: model), showWorktree: notInAnotherWorktree)
        await finishGoing(model)

        #expect(model.dialog == nil)
        #expect(model.headDescription == "detached at " + onSide.prefix(8))
        #expect(try await git("rev-parse", "main~1", in: clones.work) == tip)
    }

    @Test func asksBeforeLeavingCommitsOnADetachedHead() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--detach", in: clones.work)
        let model = try await modelToGoBack(clones, unpushed: 1)
        let target = try await git("rev-parse", "HEAD~2", in: clones.work)

        model.goToRow(try await row("HEAD~2", in: clones, of: model), showWorktree: notInAnotherWorktree)
        await model.checkout?.value

        let dialog = try dialogContent(model)
        #expect(dialog.title == "Switch to \(target.prefix(8))?")
        #expect(dialog.message?.plain == "HEAD isn't on a branch. 1 commit isn't on a remote, a branch or a tag, so it would be lost.")
        #expect(dialog.buttons.map(\.title) == ["Cancel", "Switch anyway"])
        #expect(dialog.terminal == [.command(["switch", "--detach", target])])

        dialog.buttons[1].action()
        await finishGoing(model)
        #expect(try await git("rev-parse", "HEAD", in: clones.work) == target)
    }

    @Test func asksBeforeABranchLeavesCommitsOnADetachedHeadBehind() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--detach", in: clones.work)
        let model = try await modelToGoBack(clones, unpushed: 1)
        let stray = try await git("rev-parse", "HEAD", in: clones.work)
        let badge = CommitRowContent.Badge(title: "main", kind: .branch, refName: "refs/heads/main")

        model.checkOut(badge, showWorktree: notInAnotherWorktree)
        await model.checkout?.value

        let dialog = try dialogContent(model)
        #expect(dialog.title == "Switch to main?")
        #expect(dialog.terminal == [.command(["switch", "main"])])
        #expect(try await git("rev-parse", "HEAD", in: clones.work) == stray)

        dialog.buttons[1].action()
        await finishGoing(model)
        #expect(model.headDescription == "main")
    }

    @Test func aBranchChecksOutFromADetachedHeadWhenNothingIsLeftBehind() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--detach", in: clones.work)
        let model = try await modelToGoBack(clones)
        let badge = CommitRowContent.Badge(title: "main", kind: .branch, refName: "refs/heads/main")
        model.checkOut(badge, showWorktree: notInAnotherWorktree)
        await finishGoing(model)
        #expect(model.dialog == nil)
        #expect(model.headDescription == "main")
    }

    @Test func theCurrentCommitsRowGoesNowhere() async throws {
        let clones = try await clones()
        let model = try await modelToGoBack(clones)
        model.goToRow(try await row("HEAD", in: clones, of: model), showWorktree: notInAnotherWorktree)
        #expect(model.checkout == nil)
    }

    @Test func theRowForUncommittedChangesGoesNowhere() async throws {
        let clones = try await clones()
        try "Mine\n".write(toFile: clones.work + "/new.txt", atomically: true, encoding: .utf8)
        let model = try await modelToGoBack(clones)
        #expect(model.hasWorkingTreeRow)
        model.goToRow(0, showWorktree: notInAnotherWorktree)
        #expect(model.checkout == nil)
    }

    @Test func doesNothingWhileStuckPartway() async throws {
        let clones = try await clones()
        let model = try await modelToGoBack(clones)
        model.branch.unfinished = UnfinishedWork(work: .merge, conflicts: 0)
        model.goToRow(try await row("HEAD~1", in: clones, of: model), showWorktree: notInAnotherWorktree)
        #expect(model.checkout == nil)
    }

    @Test func theUpstreamsBadgeGoesToItsCommit() async throws {
        let clones = try await clones()
        let model = try await modelToGoBack(clones, unpushed: 1)
        let badge = CommitRowContent.Badge(title: "origin/main", kind: .remoteBranch, refName: "refs/remotes/origin/main")
        model.checkOut(badge, showWorktree: notInAnotherWorktree)
        await model.checkout?.value
        #expect(try dialogContent(model).title.hasPrefix("Reset main to"))
    }

    @Test func aFailedCheckoutComesFirst() async throws {
        let clones = try await clones()
        let model = model(clones, fetches: false)
        model.branch.pendingAbort = .merge
        model.checkoutFailure = RepositoryModel.CheckoutFailure(branch: "main", message: "error: no", command: ["switch", "main"])
        let dialog = try dialogContent(model)
        #expect(dialog.title == "Can't check out main")
        #expect(dialog.terminal == [.ran(["switch", "main"]), .output("error: no")])
        dialog.dismiss()
        #expect(model.checkoutFailure == nil)
        #expect(model.dialog?.id == "abort")
    }

    // MARK: Unfinished work

    /// Clones with a conflict waiting in `conflict.txt`, once `origin/main` is merged.
    private func clonesAboutToConflict() async throws -> (Clones, mine: String) {
        let clones = try await clones()
        try await pushFromOther(clones, file: "conflict.txt", text: "theirs\n")
        let mine = try await commit("Mine", in: clones.work, file: "conflict.txt", text: "mine\n")
        _ = try await git("fetch", "--quiet", in: clones.work)
        return (clones, mine)
    }

    /// Looks at the worktree again and waits until that's done. A fetch from
    /// `appear` may still be running, and when it ends it starts this over.
    private func look(_ model: RepositoryModel) async {
        await model.branch.quietFetch?.value
        model.refsChanged()
        await model.check?.value
    }

    @Test func showsAMergeStartedSomewhereElse() async throws {
        let (clones, mine) = try await clonesAboutToConflict()
        let model = model(clones)
        await model.appear()
        #expect(model.branch.unfinished == nil)

        _ = try? await git("merge", "origin/main", in: clones.work)
        await look(model)
        #expect(model.branch.unfinished == UnfinishedWork(work: .merge, conflicts: 1))
        #expect(model.branch.conflict == nil)
        var row = model.rowContent(0)
        #expect(row.subject == "Merging · 1 conflict")
        #expect(row.body == "· 1 uncommitted file")
        #expect(row.isWarning)

        // With no conflicts left it's still unfinished, but nothing is wrong.
        try "both\n".write(toFile: clones.work + "/conflict.txt", atomically: true, encoding: .utf8)
        _ = try await git("add", "conflict.txt", in: clones.work)
        await look(model)
        #expect(model.branch.unfinished == UnfinishedWork(work: .merge, conflicts: 0))
        #expect(model.branch.unfinished?.hasConflicts == false)
        row = model.rowContent(0)
        #expect(row.subject == "Merging · 1 uncommitted file, 1 staged")
        #expect(row.body == nil)
        #expect(!row.isWarning)

        model.branch.askToAbort()
        #expect(model.branch.pendingAbort == .merge)
        model.branch.confirmAbort()
        #expect(model.branch.pendingAbort == nil)
        #expect(model.branch.action == .aborting)
        await model.branch.running?.value
        await look(model)
        #expect(model.branch.finished == "Aborted the merge")
        #expect(model.branch.unfinished == nil)
        #expect(try await git("rev-parse", "HEAD", in: clones.work) == mine)
    }

    @Test func showsARebaseWithTheBranchItsRebasing() async throws {
        let (clones, _) = try await clonesAboutToConflict()
        let model = model(clones)
        await model.appear()

        _ = try? await git("rebase", "origin/main", in: clones.work)
        await look(model)
        let unfinished = try #require(model.branch.unfinished)
        #expect(unfinished.work == .rebase(branch: "refs/heads/main"))
        #expect(unfinished.title == "Rebasing main · 1 conflict")
        // A rebase stops with `HEAD` detached, so there's no branch to have counts.
        #expect(model.branch.status == nil)

        model.branch.askToAbort()
        model.branch.confirmAbort()
        await model.branch.running?.value
        await look(model)
        #expect(model.branch.finished == "Aborted the rebase")
        #expect(model.branch.unfinished == nil)
    }

    @Test func conflictsWithoutAMergeOrARebaseHaveNothingToAbort() async throws {
        let clones = try await clones()
        try await commit("Base", in: clones.work, file: "conflict.txt", text: "base\n")
        try "stashed\n".write(toFile: clones.work + "/conflict.txt", atomically: true, encoding: .utf8)
        _ = try await git("stash", "--quiet", in: clones.work)
        try await commit("Mine", in: clones.work, file: "conflict.txt", text: "mine\n")
        _ = try? await git("stash", "pop", "--quiet", in: clones.work)
        let model = model(clones)
        await model.appear()
        await look(model)

        #expect(model.branch.unfinished == UnfinishedWork(work: nil, conflicts: 1))
        #expect(model.branch.unfinished?.title == "1 conflict")
        model.branch.askToAbort()
        #expect(model.branch.pendingAbort == nil)
    }

    @Test func showingConflictsSelectsTheRowForUncommittedChanges() async throws {
        let (clones, _) = try await clonesAboutToConflict()
        let model = model(clones)
        await model.appear()
        _ = try? await git("merge", "origin/main", in: clones.work)
        await look(model)
        #expect(model.selectedRow != 0)

        model.branch.showChanges()
        #expect(model.selectedRow == 0)
    }

    @Test func aWorktreeThatsFineSaysNothing() async throws {
        let clones = try await clones()
        let model = model(clones)
        await model.appear()
        await look(model)
        #expect(model.branch.unfinished == nil)
    }

    @Test func aPullThatFailsForAnotherReasonSaysWhatGitSaid() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        try await commit("Mine", in: clones.work)
        let model = model(clones)
        await model.appear()
        model.branch.pull(.fastForward)
        await model.branch.running?.value
        #expect(model.branch.conflict == nil)
        #expect(model.branch.failure?.title == "Can't pull main")
        #expect(model.branch.failure?.message.isEmpty == false)
    }

    // MARK: Letting the house play

    @Test func aQuickPullWaitsForTheHouseToPlayOnce() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        let model = model(clones)
        await model.appear()
        // The fetch it started by itself would clash with this one over the ref.
        await model.branch.quietFetch?.value
        try await git("fetch", "--quiet", in: clones.work)
        await model.branch.refresh()
        model.branch.timeToPlayHouse = { action in
            #expect(action == .pulling)
            return .milliseconds(700)
        }

        let started = ContinuousClock.now
        model.branch.pull()
        #expect(model.branch.action == .pulling)
        await model.branch.running?.value
        #expect(ContinuousClock.now - started >= .milliseconds(700))
        #expect(model.branch.action == nil)
        #expect(model.branch.finished == "Pulled")
    }

    /// These would wait for ten minutes if they waited at all, and the suite's
    /// time limit would fail them.
    @Test func aRefusalDoesntWaitForTheHouse() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        try await commit("Mine", in: clones.work)
        let model = model(clones)
        await model.appear()
        model.branch.timeToPlayHouse = { _ in .seconds(600) }
        model.branch.pull(.fastForward)
        await model.branch.running?.value
        #expect(model.branch.failure != nil)
        #expect(model.branch.action == nil)
    }

    @Test func aConflictDoesntWaitForTheHouse() async throws {
        let clones = try await clones()
        try await pushFromOther(clones, file: "conflict.txt", text: "theirs\n")
        try await commit("Mine", in: clones.work, file: "conflict.txt", text: "mine\n")
        let model = model(clones)
        await model.appear()
        model.branch.timeToPlayHouse = { _ in .seconds(600) }
        model.branch.pull(.merge)
        await model.branch.running?.value
        #expect(model.branch.conflict != nil)
        #expect(model.branch.action == nil)
    }

    // MARK: Pushing

    @Test func pushesAndSaysSo() async throws {
        let clones = try await clones()
        let mine = try await commit("Mine", in: clones.work)
        let model = model(clones)
        await model.appear()
        #expect(model.branch.status?.ahead == 1)

        model.branch.push()
        await model.branch.running?.value
        #expect(model.branch.finished == "Pushed")
        #expect(try await git("rev-parse", "main", in: clones.remote) == mine)
    }

    @Test func aRejectedPushFetchesWhichCorrectsTheCounts() async throws {
        let clones = try await clones()
        try await commit("Mine", in: clones.work)
        let model = model(clones)
        await model.appear()
        await model.branch.quietFetch?.value
        await model.check?.value
        // Someone pushes after Roga fetched, so the count hasn't noticed.
        try await pushFromOther(clones)
        #expect(model.branch.status?.push == .toUpstream)

        model.branch.push()
        await model.branch.running?.value
        #expect(model.branch.failure?.title == "Can't push main")
        await model.check?.value
        #expect(model.branch.status?.behind == 1)
        #expect(model.branch.status?.ahead == 1)
    }

    @Test func aForcePushAsksFirstAndSaysWhatItOverwrites() async throws {
        let clones = try await clones()
        try await commit("First try", in: clones.work)
        try await git("push", "--quiet", in: clones.work)
        try await git("reset", "--quiet", "--hard", "HEAD~1", in: clones.work)
        let mine = try await commit("Second try", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        model.branch.askToForcePush()
        while model.branch.forcePush == nil { await Task.yield() }
        #expect(model.branch.forcePush?.count == 1)
        #expect(model.branch.forcePush?.commits.map(\.subject) == ["First try"])
        #expect(model.branch.forcePush?.branch == "main")
        #expect(model.branch.forcePush?.upstream == "origin/main")
        #expect(try await git("rev-parse", "main", in: clones.remote) != mine)

        model.branch.confirmForcePush()
        await model.branch.running?.value
        #expect(model.branch.forcePush == nil)
        #expect(try await git("rev-parse", "main", in: clones.remote) == mine)
    }

    // MARK: Deleting branches

    func exists(_ ref: String, in folder: String) async throws -> Bool {
        try await !git("for-each-ref", "--format=%(refname)", ref, in: folder).isEmpty
    }

    /// Asks to delete a branch, and waits for that to run or to ask about it.
    func askToDelete(_ ref: String, _ model: RepositoryModel) async {
        model.branch.askToDelete(ref: ref)
        await model.branch.preparingDeletion?.value
        await model.branch.running?.value
    }

    /// Makes a branch with a commit that nothing else has, and goes back to `main`.
    func makeBranchWithACommit(_ name: String, _ clones: Clones) async throws -> String {
        try await git("switch", "--quiet", "--create", name, in: clones.work)
        let id = try await commit("Only on \(name)", in: clones.work)
        try await git("switch", "--quiet", "main", in: clones.work)
        return id
    }

    /// The suite's time limit would fail this if it waited for the house.
    @Test func deletesABranchThatLosesNothingStraightAway() async throws {
        let clones = try await clones()
        try await git("branch", "other", in: clones.work)
        let model = model(clones, fetches: false)
        model.branch.timeToPlayHouse = { _ in .seconds(600) }
        await model.appear()

        await askToDelete("refs/heads/other", model)
        #expect(model.branch.pendingDeletion == nil)
        #expect(model.branch.action == nil)
        #expect(!model.branch.isBusy)
        #expect(model.branch.finished == "Deleted other")
        #expect(try await !exists("refs/heads/other", in: clones.work))

        // History loads again, without the branch's badge.
        await model.check?.value
        await model.load()
        #expect(model.history?.refs.refs.contains { $0.name == "refs/heads/other" } == false)
    }

    @Test func asksBeforeLosingCommitsAndSaysWhichOnes() async throws {
        let clones = try await clones()
        _ = try await makeBranchWithACommit("other", clones)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete("refs/heads/other", model)
        #expect(model.branch.pendingDeletion?.deletion.lostCount == 1)
        #expect(model.branch.pendingDeletion?.commits.map(\.subject) == ["Only on other"])
        #expect(try await exists("refs/heads/other", in: clones.work))

        model.branch.confirmDeletion()
        await model.branch.running?.value
        #expect(model.branch.pendingDeletion == nil)
        #expect(model.branch.finished == "Deleted other")
        #expect(try await !exists("refs/heads/other", in: clones.work))
    }

    // MARK: A branch and its upstream

    func askToDelete(branch: String, upstream: String, _ model: RepositoryModel) async {
        model.branch.askToDelete(branch: "refs/heads/" + branch, upstream: "refs/remotes/" + upstream)
        await model.branch.preparingDeletion?.value
    }

    @Test func startsWithTheBranchAndNotItsUpstream() async throws {
        let clones = try await clones()
        try await git("branch", "--track", "feature", "origin/feature", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete(branch: "feature", upstream: "origin/feature", model)
        let choice = try #require(model.branch.branchChoice)
        let dialog = model.branch.dialog(for: choice)
        #expect(dialog.title == "Delete feature?")
        #expect(dialog.switches.map(\.isOn) == [true, false])
        #expect(dialog.switches.map(\.title.plain) == ["feature", "origin/feature"])
        #expect(dialog.switches.last?.detail.plain == "This deletes the branch on origin, for everyone who uses it.")
        #expect(dialog.terminal == [.command(["branch", "-D", "feature"]), .blank])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .primary])
        #expect(try await exists("refs/heads/feature", in: clones.work))

        model.branch.confirmBranchChoice()
        await model.branch.running?.value
        #expect(model.branch.finished == "Deleted feature")
        #expect(try await !exists("refs/heads/feature", in: clones.work))
        #expect(try await exists("refs/heads/feature", in: clones.remote))
    }

    @Test func deletesBothOnceTheUpstreamsSwitchIsOn() async throws {
        let clones = try await clones()
        try await git("branch", "--track", "feature", "origin/feature", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete(branch: "feature", upstream: "origin/feature", model)
        model.branch.dialog(for: try #require(model.branch.branchChoice)).switches[1].flip()
        let dialog = model.branch.dialog(for: try #require(model.branch.branchChoice))
        #expect(dialog.switches.map(\.isOn) == [true, true])
        #expect(dialog.terminal == [
            .command(["branch", "-D", "feature"]),
            .command(["push", "--delete", "origin", "refs/heads/feature"]),
        ])
        #expect(dialog.buttons.map(\.kind) == [.secondary, .destructive])

        model.branch.confirmBranchChoice()
        #expect(model.branch.action == .deletingFromRemote)
        await model.branch.running?.value
        #expect(model.branch.finished == "Deleted feature and its remote branch")
        #expect(try await !exists("refs/heads/feature", in: clones.work))
        #expect(try await !exists("refs/heads/feature", in: clones.remote))
    }

    @Test func deletesOnlyTheUpstreamWhenTheBranchsSwitchIsOff() async throws {
        let clones = try await clones()
        try await git("branch", "--track", "feature", "origin/feature", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete(branch: "feature", upstream: "origin/feature", model)
        model.branch.branchChoice?.deletesBranch = false
        model.branch.branchChoice?.deletesUpstream = true
        model.branch.confirmBranchChoice()
        await model.branch.running?.value
        #expect(model.branch.finished == "Deleted origin/feature")
        #expect(try await exists("refs/heads/feature", in: clones.work))
        #expect(try await !exists("refs/heads/feature", in: clones.remote))
    }

    @Test func hasNothingToDeleteWithBothSwitchesOff() async throws {
        let clones = try await clones()
        try await git("branch", "--track", "feature", "origin/feature", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete(branch: "feature", upstream: "origin/feature", model)
        model.branch.branchChoice?.deletesBranch = false
        let dialog = model.branch.dialog(for: try #require(model.branch.branchChoice))
        #expect(dialog.buttons.map(\.isEnabled) == [true, false])
        #expect(dialog.terminal == [.blank, .blank])
    }

    @Test func saysWhatDeletingBothLosesWithoutMovingAnything() async throws {
        let clones = try await clones()
        try await git("switch", "--quiet", "--create", "pushed", in: clones.work)
        try await commit("Only on pushed", in: clones.work)
        try await git("push", "--quiet", "--set-upstream", "origin", "pushed", in: clones.work)
        try await git("switch", "--quiet", "main", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete(branch: "pushed", upstream: "origin/pushed", model)
        var dialog = model.branch.dialog(for: try #require(model.branch.branchChoice))
        #expect(dialog.switches.first?.detail.plain == "Its commits are also on origin/pushed.")
        #expect(dialog.cardsAfterSwitches.first?.first == .heading("1 commit stays on origin/pushed", isLost: false))
        #expect(dialog.cardsAfterSwitches.first?.count == 2)

        dialog.switches[1].flip()
        dialog = model.branch.dialog(for: try #require(model.branch.branchChoice))
        #expect(dialog.cardsAfterSwitches.first?.first == .heading("This commit can't be brought back", isLost: true))
        #expect(dialog.cardsAfterSwitches.first?.count == 2)
    }

    @Test func saysWhatsLeftWhenTheUpstreamCantBeDeleted() async throws {
        let clones = try await clones()
        try await git("branch", "--track", "feature", "origin/feature", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete(branch: "feature", upstream: "origin/feature", model)
        model.branch.branchChoice?.deletesUpstream = true
        try FileManager.default.moveItem(atPath: clones.remote, toPath: clones.remote + ".moved")
        model.branch.confirmBranchChoice()
        await model.branch.running?.value
        let failure = try #require(model.branch.failure)
        #expect(failure.title == "Can't delete origin/feature")
        #expect(failure.summary?.plain == "feature is gone, but origin/feature isn't. What git said is below.")
        #expect(model.branch.finished == nil)
    }

    @Test func asksOnlyAboutTheUpstreamWhenAWorktreeHasTheBranchCheckedOut() async throws {
        let clones = try await clones()
        try await git("worktree", "add", "--quiet", "--track", "-b", "feature", clones.folder + "/linked", "origin/feature", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete(branch: "feature", upstream: "origin/feature", model)
        #expect(model.branch.branchChoice == nil)
        #expect(model.branch.pendingDeletion?.deletion.ref == "refs/remotes/origin/feature")
    }

    @Test func goesBackToNoSelectionWhenDeletingLosesTheSelectedCommit() async throws {
        let clones = try await clones()
        let id = try await makeBranchWithACommit("other", clones)
        let model = model(clones, fetches: false)
        await model.appear()
        model.select(commit: try #require(ObjectID(hex: id)))
        #expect(model.selectedCommit.id?.hex == id)

        await askToDelete("refs/heads/other", model)
        model.branch.confirmDeletion()
        await model.branch.running?.value
        await model.check?.value
        await model.load()
        #expect(model.selectedCommit.id == nil)
    }

    @Test func alwaysAsksBeforeDeletingFromARemote() async throws {
        let clones = try await clones()
        try await git("branch", "--track", "feature", "origin/feature", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete("refs/remotes/origin/feature", model)
        #expect(model.branch.pendingDeletion?.deletion.lostCount == 0)
        #expect(try await exists("refs/heads/feature", in: clones.remote))

        model.branch.confirmDeletion()
        #expect(model.branch.action == .deletingFromRemote)
        await model.branch.running?.value
        #expect(model.branch.action == nil)
        #expect(model.branch.finished == "Deleted origin/feature")
        #expect(try await !exists("refs/heads/feature", in: clones.remote))
    }

    @Test func sayingNoLeavesTheBranch() async throws {
        let clones = try await clones()
        _ = try await makeBranchWithACommit("other", clones)
        let model = model(clones, fetches: false)
        await model.appear()
        await askToDelete("refs/heads/other", model)
        // What the dialog's Cancel button does.
        model.branch.pendingDeletion = nil
        model.branch.confirmDeletion()
        #expect(model.branch.running == nil)
        #expect(try await exists("refs/heads/other", in: clones.work))
    }

    @Test func aBranchInAnotherWorktreeSaysWhatGitSaid() async throws {
        let clones = try await clones()
        let folder = clones.folder + "/notes"
        try await git("worktree", "add", "--quiet", folder, "-b", "notes", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()

        await askToDelete("refs/heads/notes", model)
        #expect(model.branch.pendingDeletion == nil)
        #expect(model.branch.failure?.title == "Can't delete notes")
        #expect(model.branch.failure?.message.contains(folder) == true)
        #expect(try await exists("refs/heads/notes", in: clones.work))
    }

    @Test func aBranchThatsAlreadyGoneSaysWhatGitSaid() async throws {
        let clones = try await clones()
        let model = model(clones, fetches: false)
        await model.appear()
        await askToDelete("refs/heads/nothing", model)
        #expect(model.branch.failure?.title == "Can't delete nothing")
    }

    @Test func refusesToDeleteWhileSomethingRuns() async throws {
        let clones = try await clones()
        try await git("branch", "other", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()
        model.branch.isCheckingOut = { true }
        await askToDelete("refs/heads/other", model)
        #expect(try await exists("refs/heads/other", in: clones.work))
    }

    @Test func shortensALongNameForTheTitleRow() {
        #expect(BranchModel.shortened("fix-retry") == "fix-retry")
        let long = "claude/fix-the-login-regression-in-the-session-store"
        #expect(BranchModel.shortened(long) == "claude/fix-the-…he-session-store")
    }

    // MARK: New branches

    @Test func createsABranchAndClosesThePopover() async throws {
        let clones = try await clones()
        let model = model(clones)
        await model.appear()
        model.branch.isCreatingBranch = true
        let refusal = await model.branch.create(NewBranch(name: "fix-retry")) { _, _ in Issue.record("It stays in this worktree.") }
        #expect(refusal == nil)
        #expect(!model.branch.isCreatingBranch)
        #expect(try await git("symbolic-ref", "HEAD", in: clones.work) == "refs/heads/fix-retry")
    }

    @Test func showsTheWorktreeOfANewBranch() async throws {
        let clones = try await clones()
        var reported = 0
        var shown: String?
        let model = RepositoryModel(session: clones.session, worktree: clones.work, reportBranchChange: { reported += 1 })
        await model.appear()
        _ = await model.branch.create(NewBranch(name: "tm/fix", inNewWorktree: true)) { folder, _ in
            // The sidebar has to know about it first.
            #expect(reported == 1)
            shown = folder
        }
        #expect(shown == clones.folder + "/tm-fix")
    }

    @Test func keepsThePopoverOpenWhenGitRefuses() async throws {
        let clones = try await clones()
        try await git("branch", "taken", in: clones.work)
        let model = model(clones)
        await model.appear()
        model.branch.isCreatingBranch = true
        let refusal = await model.branch.create(NewBranch(name: "taken")) { _, _ in }
        #expect(refusal?.contains("taken") == true)
        #expect(model.branch.isCreatingBranch)
    }

    // MARK: Previewing

    @Test func tintsTheCommitsACountWouldMove() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        let mine = try await commit("Mine", in: clones.work)
        try await git("fetch", "--quiet", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()
        let row = try #require(model.history.flatMap { history in
            history.rows.firstIndex { history.graph.id(at: $0).hex == mine }
        })
        #expect(!model.rowContent(row).isPreviewed)

        model.branch.preview(.push)
        await model.branch.previewing?.value
        #expect(model.rowContent(row).isPreviewed)
        #expect((0..<model.rowCount).filter { model.rowContent($0).isPreviewed } == [row])

        model.branch.preview(.pull)
        await model.branch.previewing?.value
        #expect(!model.rowContent(row).isPreviewed)
        #expect((0..<model.rowCount).filter { model.rowContent($0).isPreviewed }.count == 1)

        model.branch.preview(nil)
        #expect((0..<model.rowCount).allSatisfy { !model.rowContent($0).isPreviewed })
    }

    /// The count goes away under the pointer, so nothing else would end the tint.
    @Test func clickingACountEndsTheTint() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        try await commit("Mine", in: clones.work)
        try await git("fetch", "--quiet", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()
        model.branch.preview(.push)
        await model.branch.previewing?.value
        #expect((0..<model.rowCount).contains { model.rowContent($0).isPreviewed })

        // git refuses this one, so history doesn't load again and clear it.
        model.branch.pull(.fastForward)
        #expect((0..<model.rowCount).allSatisfy { !model.rowContent($0).isPreviewed })
        await model.branch.running?.value
    }

    @Test func leavingTheBranchForgetsWhereItStood() async throws {
        let clones = try await clones()
        let model = model(clones, fetches: false)
        await model.appear()
        #expect(model.branch.status != nil)
        try await git("switch", "--quiet", "--detach", in: clones.work)
        await model.branch.refresh()
        #expect(model.branch.status == nil)
    }

    // MARK: What the title row says

    @Test func saysWhereTheBranchStands() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        try await commit("Mine", in: clones.work)
        try await git("fetch", "--quiet", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()
        #expect(model.branch.summary().hasPrefix("origin/main · 1 behind, 1 ahead"))
        #expect(model.branch.pullHelp.hasPrefix("main has diverged from origin/main."))
        #expect(model.branch.pushHelp.hasPrefix("main is behind origin/main,"))
    }

    @Test func tooltipsNameTheBranchTheRemoteAndTheCommand() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        try await git("fetch", "--quiet", in: clones.work)
        let model = model(clones, fetches: false)
        await model.appear()
        #expect(model.branch.pullHelp == "Pull 1 commit from origin/main into main\ngit pull --ff-only")

        try await git("pull", "--quiet", in: clones.work)
        try await commit("Mine", in: clones.work)
        try await commit("Mine too", in: clones.work)
        await model.branch.refresh()
        #expect(model.branch.pushHelp == "Push 2 commits from main to origin/main\ngit push")
    }

    @Test func saysHowLongAgoSomethingWas() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(BranchModel.age(of: now.addingTimeInterval(-10), now: now) == "just now")
        #expect(BranchModel.age(of: now.addingTimeInterval(-240), now: now) == "4 min ago")
        #expect(BranchModel.age(of: now.addingTimeInterval(-7200), now: now) == "2 h ago")
        #expect(BranchModel.age(of: now.addingTimeInterval(-172_800), now: now) == "2 d ago")
    }
}
