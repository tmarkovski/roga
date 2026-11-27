import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// How far a worktree's branch is from the main branch on the remote, and
/// whether merging that would conflict (decision 120), against real git.
@Suite(.timeLimit(.minutes(1)))
struct MainDistanceTests {
    struct Clones {
        /// The repository everyone pushes to, whose branch is `main`.
        var remote: String
        /// A clone on `agent/fix`, a branch made from `main`.
        var work: String
        /// Another clone, on `main`, which stands for someone else pushing.
        var other: String
        var session: RepositorySession
    }

    func clones() async throws -> Clones {
        let root = try makeTemporaryFolder()
        let seed = root + "/seed"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: seed)
        try await configure(seed)
        try write("one\ntwo\nthree\n", to: "a.txt", in: seed)
        try await commit("First", in: seed)
        try await runGit("clone", "--quiet", "--bare", seed, root + "/remote.git", in: root)
        try await runGit("clone", "--quiet", root + "/remote.git", root + "/work", in: root)
        try await runGit("clone", "--quiet", root + "/remote.git", root + "/other", in: root)
        try await configure(root + "/work")
        try await configure(root + "/other")
        try await runGit("switch", "--quiet", "--create", "agent/fix", in: root + "/work")
        return Clones(remote: root + "/remote.git", work: root + "/work", other: root + "/other", session: try await openSession(root + "/work"))
    }

    func configure(_ repository: String) async throws {
        try await runGit("config", "user.name", "Ana", in: repository)
        try await runGit("config", "user.email", "ana@example.com", in: repository)
    }

    func write(_ text: String, to path: String, in repository: String) throws {
        let file = URL(filePath: repository + "/" + path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    @discardableResult
    func commit(_ message: String, in repository: String) async throws -> ObjectID {
        try await runGit("add", "--all", in: repository)
        try await runGit("commit", "--quiet", "--allow-empty", "--message=" + message, in: repository)
        return try #require(ObjectID(hex: try await runGit("rev-parse", "HEAD", in: repository)))
    }

    /// Someone else changes `a.txt` on `main` and pushes it, and the work
    /// clone fetches it.
    func pushToMain(_ clones: Clones, text: String = "one\ntwo\nthree\n", message: String = "On main") async throws {
        try write(text, to: "a.txt", in: clones.other)
        try await commit(message, in: clones.other)
        try await runGit("push", "--quiet", in: clones.other)
        try await runGit("fetch", "--quiet", in: clones.work)
    }

    func distance(_ clones: Clones, after previous: MainDistance? = nil) async throws -> MainDistance? {
        try await clones.session.mainDistance(of: "refs/heads/agent/fix", after: previous, in: clones.work)
    }

    @Test func comparesWithTheBranchTheRemotesHeadNames() async throws {
        let clones = try await clones()
        try write("mine\n", to: "b.txt", in: clones.work)
        try await commit("Mine", in: clones.work)
        let distance = try #require(try await distance(clones))
        #expect(distance.base == "refs/remotes/origin/main")
        #expect(distance.baseName == "origin/main")
        #expect(distance.ahead == 1)
        #expect(distance.behind == 0)
        #expect(distance.conflicts == [])
    }

    @Test func countsWhatTheRemotesMainHasThatTheBranchHasnt() async throws {
        let clones = try await clones()
        try await pushToMain(clones, text: "one\ntwo\nthree\nfour\n")
        try await pushToMain(clones, text: "one\ntwo\nthree\nfour\nfive\n")
        // The local main hasn't pulled, and it's the remote's that counts.
        let distance = try #require(try await distance(clones))
        #expect(distance.ahead == 0)
        #expect(distance.behind == 2)
        #expect(distance.conflicts == [])
    }

    @Test func namesTheFilesAMergeWouldConflictIn() async throws {
        let clones = try await clones()
        try write("one\nTWO\nthree\n", to: "a.txt", in: clones.work)
        try write("mine\n", to: "b.txt", in: clones.work)
        try await commit("Mine", in: clones.work)
        try await pushToMain(clones, text: "one\n2\nthree\n")
        let distance = try #require(try await distance(clones))
        #expect(distance.ahead == 1)
        #expect(distance.behind == 1)
        #expect(distance.conflicts == ["a.txt"])
    }

    @Test func aMergeThatGoesCleanlyHasNoConflicts() async throws {
        let clones = try await clones()
        try write("mine\n", to: "b.txt", in: clones.work)
        try await commit("Mine", in: clones.work)
        try await pushToMain(clones, text: "one\ntwo\nthree\nfour\n")
        let distance = try #require(try await distance(clones))
        #expect(distance.hasDiverged)
        #expect(distance.conflicts == [])
    }

    @Test func triesTheMergeWithoutTouchingTheWorktreeOrTheIndex() async throws {
        let clones = try await clones()
        try write("one\nTWO\nthree\n", to: "a.txt", in: clones.work)
        try await commit("Mine", in: clones.work)
        try await pushToMain(clones, text: "one\n2\nthree\n")
        try write("uncommitted\n", to: "a.txt", in: clones.work)
        let index = try Data(contentsOf: URL(filePath: clones.work + "/.git/index"))
        _ = try await distance(clones)
        #expect(try Data(contentsOf: URL(filePath: clones.work + "/.git/index")) == index)
        #expect(try String(contentsOfFile: clones.work + "/a.txt", encoding: .utf8) == "uncommitted\n")
        #expect(try await runGit("status", "--porcelain", in: clones.work) == " M a.txt")
    }

    @Test func comesBackAsItWasWhileNothingHasMoved() async throws {
        let clones = try await clones()
        try await commit("Mine", in: clones.work)
        let first = try #require(try await distance(clones))
        // A made-up count shows whether it was worked out again.
        var previous = first
        previous.ahead = 99
        #expect(try await distance(clones, after: previous)?.ahead == 99)
        try await commit("More", in: clones.work)
        #expect(try await distance(clones, after: previous)?.ahead == 2)
    }

    @Test func theMainBranchItselfHasNothingToCompare() async throws {
        let clones = try await clones()
        #expect(try await clones.session.mainDistance(of: "refs/heads/main", after: nil, in: clones.other) == nil)
    }

    @Test func withoutARemotesHeadItComparesWithMainsUpstream() async throws {
        let clones = try await clones()
        try await runGit("remote", "set-head", "origin", "--delete", in: clones.work)
        try await pushToMain(clones, text: "one\ntwo\nthree\nfour\n")
        let distance = try #require(try await distance(clones))
        #expect(distance.base == "refs/remotes/origin/main")
        #expect(distance.behind == 1)
    }

    @Test func withoutARemoteItComparesWithTheLocalMain() async throws {
        let clones = try await clones()
        try await runGit("remote", "remove", "origin", in: clones.work)
        try await commit("Mine", in: clones.work)
        let distance = try #require(try await distance(clones))
        #expect(distance.base == "refs/heads/main")
        #expect(distance.ahead == 1)
    }

    @Test func aRemotesHeadThatNamesAnotherBranchComparesWithThat() async throws {
        let clones = try await clones()
        try await runGit("push", "--quiet", "origin", "main:refs/heads/trunk", in: clones.other)
        try await runGit("fetch", "--quiet", in: clones.work)
        try await runGit("remote", "set-head", "origin", "trunk", in: clones.work)
        try await commit("Mine", in: clones.work)
        let distance = try #require(try await distance(clones))
        #expect(distance.base == "refs/remotes/origin/trunk")
        #expect(distance.ahead == 1)
    }
}
