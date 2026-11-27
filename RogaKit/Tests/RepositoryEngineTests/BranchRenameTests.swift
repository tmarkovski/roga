import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Renaming a branch here and nowhere else, and pushing it afterwards to the
/// upstream it kept (decision 120), against real git.
@Suite(.timeLimit(.minutes(1)))
struct BranchRenameTests {
    struct Clones {
        /// The repository everyone pushes to, whose branch is `main`.
        var remote: String
        /// A clone on `agent/fix`, which has been pushed and tracks
        /// `origin/agent/fix`.
        var work: String
        var session: RepositorySession
    }

    func clones() async throws -> Clones {
        let root = try makeTemporaryFolder()
        let seed = root + "/seed"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: seed)
        try await configure(seed)
        try await runGit("commit", "--quiet", "--allow-empty", "--message=First", in: seed)
        try await runGit("clone", "--quiet", "--bare", seed, root + "/remote.git", in: root)
        try await runGit("clone", "--quiet", root + "/remote.git", root + "/work", in: root)
        let work = root + "/work"
        try await configure(work)
        try await runGit("switch", "--quiet", "--create", "agent/fix", in: work)
        try await runGit("commit", "--quiet", "--allow-empty", "--message=Mine", in: work)
        try await runGit("push", "--quiet", "--set-upstream", "origin", "agent/fix", in: work)
        return Clones(remote: root + "/remote.git", work: work, session: try await openSession(work))
    }

    func configure(_ repository: String) async throws {
        try await runGit("config", "user.name", "Ana", in: repository)
        try await runGit("config", "user.email", "ana@example.com", in: repository)
        // What a new clone has anyway, said here so that nobody's own
        // settings change what these tests find.
        try await runGit("config", "push.default", "simple", in: repository)
    }

    /// The remote's branches, by their short names.
    func remoteBranches(_ clones: Clones) async throws -> [String] {
        try await runGit("for-each-ref", "--format=%(refname:short)", "refs/heads/", in: clones.remote)
            .split(separator: "\n").map(String.init)
    }

    @Test func renamesTheBranchHereAndKeepsItsUpstream() async throws {
        let clones = try await clones()
        try await clones.session.rename(BranchRename(branch: "agent/fix", name: "fix-login"), in: clones.work)
        let status = try #require(try await clones.session.branchStatus(in: clones.work))
        #expect(status.branch == "refs/heads/fix-login")
        #expect(status.upstream == "refs/remotes/origin/agent/fix")
        #expect(status.upstreamOnRemote == "refs/heads/agent/fix")
        // Nothing happens on the remote.
        #expect(try await remoteBranches(clones) == ["agent/fix", "main"])
    }

    @Test func aRenamedBranchPushesToItsUpstreamByName() async throws {
        let clones = try await clones()
        try await clones.session.rename(BranchRename(branch: "agent/fix", name: "fix-login"), in: clones.work)
        try await runGit("commit", "--quiet", "--allow-empty", "--message=More", in: clones.work)
        let status = try #require(try await clones.session.branchStatus(in: clones.work))
        // A plain push refuses, since the names differ.
        await #expect(throws: GitError.self) { try await clones.session.push(.toUpstream, in: clones.work) }
        let push = try #require(status.push(main: "refs/remotes/origin/main"))
        try await clones.session.push(push, in: clones.work)
        let head = try await runGit("rev-parse", "HEAD", in: clones.work)
        #expect(try await runGit("rev-parse", "agent/fix", in: clones.remote) == head)
        #expect(try await remoteBranches(clones) == ["agent/fix", "main"])
        // The remote branch here has moved too, so there's nothing left to push.
        #expect(try await clones.session.branchStatus(in: clones.work)?.ahead == 0)
    }

    @Test func refusesANameAnotherBranchHas() async throws {
        let clones = try await clones()
        await #expect(throws: GitError.self) {
            try await clones.session.rename(BranchRename(branch: "agent/fix", name: "main"), in: clones.work)
        }
        #expect(try await clones.session.branchStatus(in: clones.work)?.branch == "refs/heads/agent/fix")
    }

    @Test func aBranchWithoutAnUpstreamStaysWithoutOne() async throws {
        let clones = try await clones()
        try await runGit("switch", "--quiet", "--create", "agent/new", in: clones.work)
        try await clones.session.rename(BranchRename(branch: "agent/new", name: "new-idea"), in: clones.work)
        let status = try #require(try await clones.session.branchStatus(in: clones.work))
        #expect(status.branch == "refs/heads/new-idea")
        #expect(status.upstream == nil)
        #expect(status.upstreamOnRemote == nil)
        #expect(status.push == .firstTime(remote: "origin"))
    }
}
