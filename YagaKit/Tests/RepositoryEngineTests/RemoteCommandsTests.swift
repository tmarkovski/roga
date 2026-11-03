import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Fetching, pulling and pushing, between clones of a bare copy of the `basic`
/// repository. `other` stands for someone else pushing to the remote.
@Suite(.timeLimit(.minutes(1)))
struct RemoteCommandsTests {
    struct Clones {
        var folder: String
        var remote: String
        var work: String
        var other: String
        var log: CommandLog
        var session: RepositorySession
    }

    func clones() async throws -> Clones {
        let fixture = try await Fixture.repository("basic")
        let folder = try makeTemporaryFolder()
        let remote = folder + "/remote.git"
        try await runGit("clone", "--quiet", "--bare", "--no-local", fixture, remote, in: fixture)
        try await runGit("clone", "--quiet", remote, folder + "/work", in: folder)
        try await runGit("clone", "--quiet", remote, folder + "/other", in: folder)
        let log = CommandLog()
        let session = try await RepositorySession.open(containing: folder + "/work", git: try await TestGit.make(log: log))
        return Clones(folder: folder, remote: remote, work: folder + "/work", other: folder + "/other", log: log, session: session)
    }

    @discardableResult
    func commit(_ message: String, in folder: String, file: String? = nil, text: String = "") async throws -> String {
        if let file { try text.write(toFile: folder + "/" + file, atomically: true, encoding: .utf8) }
        try await runGit("add", "--all", in: folder)
        try await runGit("-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--quiet", "--allow-empty", "-m", message, in: folder)
        return try await runGit("rev-parse", "HEAD", in: folder)
    }

    /// Puts a commit on the remote's `main`, from someone else.
    @discardableResult
    func pushFromOther(_ clones: Clones, _ message: String = "From someone else", file: String? = nil, text: String = "") async throws -> String {
        let id = try await commit(message, in: clones.other, file: file, text: text)
        try await runGit("push", "--quiet", in: clones.other)
        return id
    }

    func head(of clones: Clones) async throws -> String {
        try await runGit("rev-parse", "HEAD", in: clones.work)
    }

    func fetchCount(_ clones: Clones) -> Int {
        clones.log.entries.filter { $0.arguments.contains("fetch") }.count
    }

    /// Starts a quiet fetch that won't finish by itself, because the remote takes
    /// longer to answer than a test may run, and returns once git has started.
    func startStuckQuietFetch(_ clones: Clones) async throws -> Task<FetchRecord, Never> {
        let script = clones.folder + "/slow-upload-pack"
        try "#!/bin/sh\nsleep 120\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        try await runGit("config", "remote.origin.uploadpack", script, in: clones.work)
        let session = clones.session
        let fetch = Task { await session.fetchQuietly(from: "origin") }
        while fetchCount(clones) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        return fetch
    }

    // MARK: Where a branch stands

    @Test func readsWhatEachBranchTracks() async throws {
        let clones = try await clones()
        try await runGit("branch", "--no-track", "agent", in: clones.work)
        let refs = try await clones.session.refs(in: clones.work).refs
        #expect(refs.first { $0.name == "refs/heads/main" }?.upstream == "refs/remotes/origin/main")
        #expect(refs.first { $0.name == "refs/heads/agent" }?.upstream == nil)
        #expect(refs.first { $0.name == "refs/remotes/origin/main" }?.upstream == nil)
    }

    @Test func saysHowFarABranchIsFromItsUpstream() async throws {
        let clones = try await clones()
        var status = try #require(try await clones.session.branchStatus(in: clones.work))
        #expect(status.branch == "refs/heads/main")
        #expect(status.upstream == "refs/remotes/origin/main")
        #expect(status.ahead == 0 && status.behind == 0)
        #expect(status.remote == "origin")
        #expect(status.pullRebase == nil)

        try await pushFromOther(clones)
        try await commit("Mine", in: clones.work)
        try await commit("Mine too", in: clones.work)
        try await runGit("fetch", "--quiet", in: clones.work)
        status = try #require(try await clones.session.branchStatus(in: clones.work))
        #expect(status.ahead == 2 && status.behind == 1)
    }

    @Test func aDetachedHeadHasNoStatus() async throws {
        let clones = try await clones()
        try await runGit("switch", "--quiet", "--detach", in: clones.work)
        #expect(try await clones.session.branchStatus(in: clones.work) == nil)
    }

    @Test func aBranchWithoutCommitsHasNoStatus() async throws {
        let clones = try await clones()
        try await runGit("switch", "--quiet", "--orphan", "fresh", in: clones.work)
        #expect(try await clones.session.branchStatus(in: clones.work) == nil)
    }

    @Test func aBranchThatWasNeverPushedKnowsWhereItWouldGo() async throws {
        let clones = try await clones()
        try await runGit("switch", "--quiet", "-c", "agent", in: clones.work)
        let status = try #require(try await clones.session.branchStatus(in: clones.work))
        #expect(status.upstream == nil && !status.upstreamIsGone)
        #expect(status.remote == "origin")
        #expect(status.push == .firstTime(remote: "origin"))
    }

    @Test func aRepositoryWithoutRemotesHasNothingToFetch() async throws {
        let clones = try await clones()
        try await runGit("remote", "remove", "origin", in: clones.work)
        let status = try #require(try await clones.session.branchStatus(in: clones.work))
        #expect(status.remote == nil && status.pushRemote == nil && status.push == nil)
    }

    @Test func noticesAnUpstreamThatsGone() async throws {
        let clones = try await clones()
        try await runGit("switch", "--quiet", "-c", "agent", in: clones.work)
        try await runGit("push", "--quiet", "--set-upstream", "origin", "agent", in: clones.work)
        try await runGit("push", "--quiet", "--delete", "origin", "agent", in: clones.other)
        try await runGit("fetch", "--quiet", "--prune", in: clones.work)
        let status = try #require(try await clones.session.branchStatus(in: clones.work))
        #expect(status.upstream == nil && status.upstreamIsGone)
        #expect(status.push == .firstTime(remote: "origin"))
    }

    @Test func aBranchsOwnRebaseSettingComesFirst() async throws {
        let clones = try await clones()
        try await runGit("config", "pull.rebase", "true", in: clones.work)
        #expect(try await clones.session.branchStatus(in: clones.work)?.pullRebase == "true")
        try await runGit("config", "branch.main.rebase", "false", in: clones.work)
        #expect(try await clones.session.branchStatus(in: clones.work)?.pullRebase == "false")
    }

    @Test func listsTheCommitsBetweenTwoRefs() async throws {
        let clones = try await clones()
        let theirs = try await pushFromOther(clones)
        try await commit("Mine", in: clones.work)
        let mine = try await head(of: clones)
        try await runGit("fetch", "--quiet", in: clones.work)
        let upstream = "refs/remotes/origin/main"
        #expect(try await clones.session.commits(from: "HEAD", to: upstream, limit: 10, in: clones.work).map(\.hex) == [theirs])
        #expect(try await clones.session.commits(from: upstream, to: "HEAD", limit: 10, in: clones.work).map(\.hex) == [mine])
    }

    // MARK: Fetching by itself

    @Test func fetchesQuietlyWithoutWritingFetchHead() async throws {
        let clones = try await clones()
        let theirs = try await pushFromOther(clones)
        let record = await clones.session.fetchQuietly(from: "origin")
        #expect(record.failure == nil)
        #expect(record.lastFetched != nil)
        #expect(try await runGit("rev-parse", "origin/main", in: clones.work) == theirs)
        #expect(!FileManager.default.fileExists(atPath: clones.work + "/.git/FETCH_HEAD"))
    }

    @Test func fetchesQuietlyAtMostOnceAMinute() async throws {
        let clones = try await clones()
        _ = await clones.session.fetchQuietly(from: "origin")
        _ = await clones.session.fetchQuietly(from: "origin")
        #expect(fetchCount(clones) == 1)
        _ = await clones.session.fetchQuietly(from: "origin", minimumInterval: .zero)
        #expect(fetchCount(clones) == 2)
    }

    @Test func fetchingQuietlyWhileOneRunsWaitsForIt() async throws {
        let clones = try await clones()
        let session = clones.session
        async let first = session.fetchQuietly(from: "origin", minimumInterval: .zero)
        async let second = session.fetchQuietly(from: "origin", minimumInterval: .zero)
        _ = await (first, second)
        #expect(fetchCount(clones) == 1)
    }

    @Test func aQuietFetchRecordsItsFailureAndKeepsTheLastDate() async throws {
        let clones = try await clones()
        let worked = await clones.session.fetchQuietly(from: "origin")
        try await runGit("remote", "set-url", "origin", clones.folder + "/gone.git", in: clones.work)
        let failed = await clones.session.fetchQuietly(from: "origin", minimumInterval: .zero)
        #expect(failed.failure?.isEmpty == false)
        #expect(failed.lastFetched == worked.lastFetched)
    }

    @Test func stopsAQuietFetchThatTakesTooLong() async throws {
        let clones = try await clones()
        let record = await clones.session.fetchQuietly(from: "origin", timeLimit: .zero)
        #expect(record.failure == RepositoryError.fetchTookTooLong.description)
    }

    @Test func aPushStopsAQuietFetchRatherThanWaitingForIt() async throws {
        let clones = try await clones()
        let fetch = try await startStuckQuietFetch(clones)
        try await commit("Mine", in: clones.work)

        try await clones.session.push(.toUpstream, in: clones.work)

        // Stopping it says nothing about the remote.
        #expect(await fetch.value.failure == nil)
        let local = try await head(of: clones)
        #expect(try await runGit("rev-parse", "main", in: clones.remote) == local)
    }

    @Test func aStoppedQuietFetchDoesntCountTowardTheMinute() async throws {
        let clones = try await clones()
        let fetch = try await startStuckQuietFetch(clones)
        try await commit("Mine", in: clones.work)
        try await clones.session.push(.toUpstream, in: clones.work)
        _ = await fetch.value

        try await runGit("config", "--unset", "remote.origin.uploadpack", in: clones.work)
        _ = await clones.session.fetchQuietly(from: "origin")
        #expect(fetchCount(clones) == 2)
    }

    @Test func aFetchSomeoneAskedForThrows() async throws {
        let clones = try await clones()
        try await clones.session.fetch(from: "origin", in: clones.work)
        #expect(await clones.session.lastFetch().failure == nil)
        try await runGit("remote", "set-url", "origin", clones.folder + "/gone.git", in: clones.work)
        await #expect(throws: GitError.self) {
            try await clones.session.fetch(from: "origin", in: clones.work)
        }
        #expect(await clones.session.lastFetch().failure != nil)
    }

    @Test func aFetchSomeoneAskedForCountsTowardTheMinute() async throws {
        let clones = try await clones()
        try await clones.session.fetch(from: "origin", in: clones.work)
        _ = await clones.session.fetchQuietly(from: "origin")
        #expect(fetchCount(clones) == 1)
    }

    @Test func beforeFetchingItSaysWhenSomeoneElseDid() async throws {
        let clones = try await clones()
        #expect(await clones.session.lastFetch().lastFetched == nil)
        try await runGit("fetch", "--quiet", in: clones.work)
        #expect(await clones.session.lastFetch().lastFetched != nil)
    }

    // MARK: Pulling

    @Test func fastForwardsABranchThatsBehind() async throws {
        let clones = try await clones()
        let theirs = try await pushFromOther(clones)
        try await clones.session.pull(.fastForward, in: clones.work)
        #expect(try await head(of: clones) == theirs)
    }

    @Test func aFastForwardRefusesADivergedBranchAndChangesNothing() async throws {
        let clones = try await clones()
        try await pushFromOther(clones)
        let mine = try await commit("Mine", in: clones.work)
        await #expect(throws: GitError.self) {
            try await clones.session.pull(.fastForward, in: clones.work)
        }
        #expect(try await head(of: clones) == mine)
        #expect(try await clones.session.stoppedPull(in: clones.work) == nil)
    }

    @Test func rebasesADivergedBranch() async throws {
        let clones = try await clones()
        let theirs = try await pushFromOther(clones)
        try await commit("Mine", in: clones.work)
        try await clones.session.pull(.rebase, in: clones.work)
        #expect(try await runGit("rev-parse", "HEAD~1", in: clones.work) == theirs)
        #expect(try await runGit("log", "-1", "--format=%s", in: clones.work) == "Mine")
    }

    @Test func mergesADivergedBranchWithoutAskingForAMessage() async throws {
        let clones = try await clones()
        let theirs = try await pushFromOther(clones)
        let mine = try await commit("Mine", in: clones.work)
        try await runGit("config", "user.name", "T", in: clones.work)
        try await runGit("config", "user.email", "t@example.com", in: clones.work)
        // Merging was asked for, whatever this says.
        try await runGit("config", "pull.ff", "only", in: clones.work)
        try await clones.session.pull(.merge, in: clones.work)
        #expect(try await runGit("rev-parse", "HEAD^1", in: clones.work) == mine)
        #expect(try await runGit("rev-parse", "HEAD^2", in: clones.work) == theirs)
    }

    @Test func followsTheUsersConfiguration() async throws {
        let clones = try await clones()
        let theirs = try await pushFromOther(clones)
        try await commit("Mine", in: clones.work)
        try await runGit("config", "pull.rebase", "true", in: clones.work)
        try await clones.session.pull(.configured, in: clones.work)
        #expect(try await runGit("rev-parse", "HEAD~1", in: clones.work) == theirs)
    }

    @Test func undoesAPullThatStoppedOnAConflict() async throws {
        for (pull, stopped) in [(Pull.merge, StoppedPull.merge), (.rebase, .rebase)] {
            let clones = try await clones()
            try await pushFromOther(clones, file: "conflict.txt", text: "theirs\n")
            let mine = try await commit("Mine", in: clones.work, file: "conflict.txt", text: "mine\n")
            try await runGit("config", "user.name", "T", in: clones.work)
            try await runGit("config", "user.email", "t@example.com", in: clones.work)

            await #expect(throws: GitError.self) {
                try await clones.session.pull(pull, in: clones.work)
            }
            #expect(try await clones.session.stoppedPull(in: clones.work) == stopped)

            try await clones.session.undo(stopped, in: clones.work)
            #expect(try await clones.session.stoppedPull(in: clones.work) == nil)
            #expect(try await head(of: clones) == mine)
            #expect(try String(contentsOfFile: clones.work + "/conflict.txt", encoding: .utf8) == "mine\n")
        }
    }

    // MARK: Pushing

    @Test func pushesToTheUpstream() async throws {
        let clones = try await clones()
        let mine = try await commit("Mine", in: clones.work)
        try await clones.session.push(.toUpstream, in: clones.work)
        #expect(try await runGit("rev-parse", "main", in: clones.remote) == mine)
    }

    @Test func aFirstPushSetsTheUpstream() async throws {
        let clones = try await clones()
        try await runGit("switch", "--quiet", "-c", "agent", in: clones.work)
        let mine = try await commit("Mine", in: clones.work)
        try await clones.session.push(.firstTime(remote: "origin"), in: clones.work)
        #expect(try await runGit("rev-parse", "agent", in: clones.remote) == mine)
        let status = try #require(try await clones.session.branchStatus(in: clones.work))
        #expect(status.upstream == "refs/remotes/origin/agent")
        #expect(status.ahead == 0 && status.behind == 0)
    }

    @Test func gitRejectsAPushOverCommitsItHasntFetched() async throws {
        let clones = try await clones()
        let theirs = try await pushFromOther(clones)
        try await commit("Mine", in: clones.work)
        await #expect(throws: GitError.self) {
            try await clones.session.push(.toUpstream, in: clones.work)
        }
        #expect(try await runGit("rev-parse", "main", in: clones.remote) == theirs)
    }

    @Test func forcePushOverwritesCommitsTheBranchHasSeen() async throws {
        let clones = try await clones()
        // The branch has this commit, and then it's rewritten.
        try await commit("First try", in: clones.work)
        try await runGit("push", "--quiet", in: clones.work)
        try await runGit("reset", "--quiet", "--hard", "HEAD~1", in: clones.work)
        let mine = try await commit("Second try", in: clones.work)
        try await clones.session.push(.forceWithLease, in: clones.work)
        #expect(try await runGit("rev-parse", "main", in: clones.remote) == mine)
    }

    /// The reason for `--force-if-includes`: with a fetch by itself, the remote
    /// branch can have moved to commits nobody here has seen, which a lease alone
    /// would overwrite.
    @Test func forcePushRefusesCommitsThatOnlyAQuietFetchHasSeen() async throws {
        let clones = try await clones()
        let theirs = try await pushFromOther(clones)
        try await commit("Mine", in: clones.work)
        _ = await clones.session.fetchQuietly(from: "origin")
        await #expect(throws: GitError.self) {
            try await clones.session.push(.forceWithLease, in: clones.work)
        }
        #expect(try await runGit("rev-parse", "main", in: clones.remote) == theirs)
    }

    // MARK: New branches

    @Test func createsABranchAndSwitchesToIt() async throws {
        let clones = try await clones()
        let before = try await head(of: clones)
        try await clones.session.create(NewBranch(name: "fix-retry"), in: clones.work)
        #expect(try await runGit("symbolic-ref", "HEAD", in: clones.work) == "refs/heads/fix-retry")
        #expect(try await head(of: clones) == before)
    }

    @Test func createsABranchInANewWorktreeBesideThisOne() async throws {
        let clones = try await clones()
        try await clones.session.create(NewBranch(name: "tm/fix", inNewWorktree: true), in: clones.work)
        #expect(try await runGit("symbolic-ref", "HEAD", in: clones.work) == "refs/heads/main")
        let worktree = try #require(try await clones.session.worktrees().first { $0.branch == "refs/heads/tm/fix" })
        #expect(worktree.path == clones.folder + "/tm-fix")
    }

    @Test func gitRefusesABranchThatExists() async throws {
        let clones = try await clones()
        try await runGit("branch", "taken", in: clones.work)
        await #expect(throws: GitError.self) {
            try await clones.session.create(NewBranch(name: "taken"), in: clones.work)
        }
    }
}
