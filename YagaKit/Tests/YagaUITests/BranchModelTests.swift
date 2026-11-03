import CommitGraph
import Foundation
import GitCore
import GitRunner
import HistoryUI
import RepositoryEngine
import TestSupport
import Testing
@testable import YagaUI

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
        let folder = FileManager.default.temporaryDirectory.appending(path: "yaga-tests-\(UUID().uuidString)")
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
        RepositoryModel(session: clones.session, worktree: clones.work, fetchesByItself: { fetches })
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
        #expect(model.branch.finished == "Pulled 1")
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
        #expect(model.branch.conflict == BranchModel.Conflict(pull: .merge, files: ["conflict.txt"]))

        model.branch.undoPull()
        await model.branch.running?.value
        #expect(model.branch.conflict == nil)
        #expect(try await git("rev-parse", "HEAD", in: clones.work) == mine)
        #expect(try await clones.session.stoppedPull(in: clones.work) == nil)
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
        #expect(model.branch.failure?.title == "Can't Pull main")
        #expect(model.branch.failure?.message.isEmpty == false)
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
        #expect(model.branch.finished == "Pushed 1")
        #expect(try await git("rev-parse", "main", in: clones.remote) == mine)
    }

    @Test func aRejectedPushFetchesWhichCorrectsTheCounts() async throws {
        let clones = try await clones()
        try await commit("Mine", in: clones.work)
        let model = model(clones)
        await model.appear()
        await model.branch.quietFetch?.value
        await model.check?.value
        // Someone pushes after yaga fetched, so the count hasn't noticed.
        try await pushFromOther(clones)
        #expect(model.branch.status?.push == .toUpstream)

        model.branch.push()
        await model.branch.running?.value
        #expect(model.branch.failure?.title == "Can't Push main")
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
        #expect(model.branch.forcePush == BranchModel.ForcePush(branch: "main", upstream: "origin/main", count: 1, subjects: ["First try"]))
        #expect(try await git("rev-parse", "main", in: clones.remote) != mine)

        model.branch.confirmForcePush()
        await model.branch.running?.value
        #expect(model.branch.forcePush == nil)
        #expect(try await git("rev-parse", "main", in: clones.remote) == mine)
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
