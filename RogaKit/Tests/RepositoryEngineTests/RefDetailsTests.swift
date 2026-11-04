import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Reading what the refs panel lists, against real git.
@Suite(.timeLimit(.minutes(1)))
struct RefDetailsTests {
    /// A repository with one commit on main, and a session for it.
    func makeRepository() async throws -> (RepositorySession, String) {
        let repository = try makeTemporaryFolder() + "/repository"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: repository)
        try await runGit("config", "user.name", "Ana", in: repository)
        try await runGit("config", "user.email", "ana@example.com", in: repository)
        try await commit("First", in: repository)
        return (try await openSession(repository), repository)
    }

    func commit(_ message: String, in repository: String) async throws {
        try await runGit("commit", "--quiet", "--allow-empty", "--message=" + message, in: repository)
    }

    func id(_ revision: String, in repository: String) async throws -> ObjectID {
        try #require(ObjectID(hex: try await runGit("rev-parse", revision, in: repository)))
    }

    @Test func comparesABranchWithoutAnUpstreamWithTheMainBranch() async throws {
        let (session, repository) = try await makeRepository()
        try await runGit("switch", "--quiet", "--create", "agent/fix-login", in: repository)
        for number in 1...3 { try await commit("Fix \(number)", in: repository) }
        try await runGit("switch", "--quiet", "main", in: repository)
        for number in 1...2 { try await commit("Main \(number)", in: repository) }

        let details = try await session.refDetails(in: repository)
        #expect(details.currentBranch == "refs/heads/main")
        #expect(details.branches.map(\.shortName) == ["agent/fix-login", "main"])
        #expect(details.branches[0].comparison == BranchComparison(other: "main", ahead: 3, behind: 2))
        #expect(details.branches[0].tip == (try await id("agent/fix-login", in: repository)))
        #expect(details.branches[0].date != nil)
        // The main branch has nothing to be compared with.
        #expect(details.branches[1].comparison == nil)
    }

    @Test func comparesABranchWithItsUpstreamWhenItHasOne() async throws {
        let (_, server) = try await makeRepository()
        let clone = (server as NSString).deletingLastPathComponent + "/clone"
        try await TestGit.make().run(GitCommand("clone", "--quiet", server, clone))
        try await runGit("config", "user.name", "Ana", in: clone)
        try await runGit("config", "user.email", "ana@example.com", in: clone)
        try await commit("Local", in: clone)
        try await commit("Server", in: server)
        try await runGit("fetch", "--quiet", in: clone)

        let details = try await openSession(clone).refDetails(in: clone)
        let main = try #require(details.branches.first)
        #expect(main.comparison == BranchComparison(other: "origin/main", ahead: 1, behind: 1))
    }

    @Test func aBranchWhoseUpstreamIsGoneIsComparedWithTheMainBranch() async throws {
        let (_, server) = try await makeRepository()
        try await runGit("branch", "feature", in: server)
        let clone = (server as NSString).deletingLastPathComponent + "/clone"
        try await TestGit.make().run(GitCommand("clone", "--quiet", server, clone))
        try await runGit("config", "user.name", "Ana", in: clone)
        try await runGit("config", "user.email", "ana@example.com", in: clone)
        try await runGit("switch", "--quiet", "feature", in: clone)
        try await commit("Mine", in: clone)
        try await runGit("branch", "--quiet", "--delete", "feature", in: server)
        try await runGit("fetch", "--quiet", "--prune", in: clone)

        let details = try await openSession(clone).refDetails(in: clone)
        let feature = try #require(details.branches.first { $0.shortName == "feature" })
        #expect(feature.comparison == BranchComparison(other: "main", ahead: 1, behind: 0))
    }

    @Test func saysWhichWorktreeHasEachBranch() async throws {
        let (session, repository) = try await makeRepository()
        let folder = (repository as NSString).deletingLastPathComponent + "/fix-login"
        try await runGit("worktree", "add", "--quiet", "-b", "agent/fix-login", folder, in: repository)
        try await runGit("branch", "elsewhere", in: repository)

        let fromMain = try await session.refDetails(in: repository)
        #expect(fromMain.currentBranch == "refs/heads/main")
        #expect(fromMain.branches.map(\.worktree) == [folder, nil, repository])

        // The lists are the repository's, and only the current branch differs.
        let fromLinked = try await session.refDetails(in: folder)
        #expect(fromLinked.currentBranch == "refs/heads/agent/fix-login")
        #expect(fromLinked.branches == fromMain.branches)
    }

    @Test func aDeletedWorktreeDoesntCount() async throws {
        let (session, repository) = try await makeRepository()
        let folder = (repository as NSString).deletingLastPathComponent + "/gone"
        try await runGit("worktree", "add", "--quiet", "-b", "orphan", folder, in: repository)
        try FileManager.default.removeItem(atPath: folder)

        let details = try await session.refDetails(in: repository)
        #expect(details.branches.first { $0.shortName == "orphan" }?.worktree == nil)
    }

    @Test func listsRemotesWithTheirBranchesAndWithoutTheirCredentials() async throws {
        let (_, server) = try await makeRepository()
        try await runGit("branch", "agent/fix", in: server)
        let clone = (server as NSString).deletingLastPathComponent + "/clone"
        try await TestGit.make().run(GitCommand("clone", "--quiet", "file://" + server, clone))
        try await runGit("remote", "add", "fork", "https://ana:secret-token@example.com/ana/repo.git", in: clone)
        try await runGit("update-ref", "refs/remotes/removed/old", "HEAD", in: clone)

        let details = try await openSession(clone).refDetails(in: clone)
        #expect(details.remotes.map(\.name) == ["fork", "origin", "removed"])
        #expect(details.remotes[0].address == "example.com/ana/repo.git")
        #expect(details.remotes[0].branches.isEmpty)
        #expect(details.remotes[1].address == server)
        // origin/HEAD says which is the main branch, and isn't a branch itself.
        #expect(details.remotes[1].branches.map(\.shortName) == ["agent/fix", "main"])
        #expect(details.remotes[1].branches.allSatisfy { $0.date != nil })
        #expect(details.remotes[2].address == nil)
        #expect(details.remotes[2].branches.map(\.name) == ["refs/remotes/removed/old"])
    }

    @Test func aRepositoryWithoutRemotesHasNone() async throws {
        let (session, repository) = try await makeRepository()
        #expect(try await session.refDetails(in: repository).remotes.isEmpty)
    }

    @Test func showsTheSubjectOfTheCommitATagPointsTo() async throws {
        let (session, repository) = try await makeRepository()
        try await commit("Second", in: repository)
        try await runGit("tag", "light", "HEAD~1", in: repository)
        try await runGit("tag", "--message=The release notes", "annotated", in: repository)
        try await runGit("tag", "--message=A tree", "on-a-tree", "HEAD^{tree}", in: repository)
        try await runGit("tag", "--message=A tag", "on-a-tag", "annotated", in: repository)

        let tags = try await session.refDetails(in: repository).tags
        func tag(_ name: String) throws -> TagDetails { try #require(tags.first { $0.shortName == name }) }

        #expect(try tag("light").subject == "First")
        #expect(try tag("light").commit == (try await id("HEAD~1", in: repository)))
        // The commit's subject rather than the tag's message.
        #expect(try tag("annotated").subject == "Second")
        #expect(try tag("annotated").commit == (try await id("HEAD", in: repository)))
        #expect(try tag("annotated").date != nil)
        #expect(try tag("on-a-tree").commit == nil)
        #expect(try tag("on-a-tree").subject == nil)
        #expect(try tag("on-a-tag").commit == nil)
    }

    @Test func listsStashesFromTheLatest() async throws {
        let (session, repository) = try await makeRepository()
        #expect(try await session.refDetails(in: repository).stashes.isEmpty)

        let file = repository + "/a.txt"
        try Data("one\n".utf8).write(to: URL(filePath: file))
        try await runGit("add", "a.txt", in: repository)
        try await commit("Add a file", in: repository)
        try Data("two\n".utf8).write(to: URL(filePath: file))
        try await runGit("stash", "push", "--quiet", "--message=Try another way", in: repository)
        try Data("three\n".utf8).write(to: URL(filePath: file))
        try await runGit("stash", "push", "--quiet", in: repository)

        let stashes = try await session.refDetails(in: repository).stashes
        #expect(stashes.map(\.name) == ["stash@{0}", "stash@{1}"])
        #expect(stashes[0].message.hasPrefix("WIP on main: "))
        #expect(stashes[1].message == "On main: Try another way")
        #expect(stashes[1].commit == (try await id("stash@{1}", in: repository)))
        #expect(stashes.allSatisfy { $0.date != nil })
    }

    @Test func aRepositoryWithoutCommitsHasNothingToList() async throws {
        let repository = try makeTemporaryFolder() + "/repository"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: repository)
        let details = try await openSession(repository).refDetails(in: repository)
        #expect(details == RefDetails())
    }

    @Test func worksInABareRepository() async throws {
        let (_, server) = try await makeRepository()
        let bare = (server as NSString).deletingLastPathComponent + "/bare.git"
        try await TestGit.make().run(GitCommand("clone", "--quiet", "--bare", server, bare))
        let details = try await openSession(bare).refDetails(in: bare)
        #expect(details.branches.map(\.shortName) == ["main"])
    }

    /// The tag on a tree is the case that would download something: a clone
    /// without trees doesn't have what the tag points to.
    @Test func doesntDownloadAnythingInAPartialClone() async throws {
        let (_, server) = try await makeRepository()
        try Data("x\n".utf8).write(to: URL(filePath: server + "/a.txt"))
        try await runGit("add", "a.txt", in: server)
        try await commit("Add a file", in: server)
        try await runGit("tag", "--message=A tree", "on-a-tree", "HEAD^{tree}", in: server)
        try await runGit("tag", "--message=A commit", "on-a-commit", in: server)
        try await runGit("config", "uploadpack.allowFilter", "true", in: server)
        try await runGit("config", "uploadpack.allowAnySHA1InWant", "true", in: server)
        let clone = (server as NSString).deletingLastPathComponent + "/clone"
        try await TestGit.make().run(GitCommand("clone", "--quiet", "--filter=tree:0", "--no-checkout", "file://" + server, clone))

        func objects() async throws -> String { try await runGit("count-objects", "-v", in: clone) }
        let before = try await objects()
        let details = try await openSession(clone).refDetails(in: clone)
        #expect(try await objects() == before)
        #expect(details.tags.first { $0.shortName == "on-a-commit" }?.subject == "Add a file")
        #expect(details.tags.first { $0.shortName == "on-a-tree" }?.commit == nil)
    }
}
