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

    @Test func aBranchFromTheRemoteIsntAheadByWhatMainHasntPulled() async throws {
        let (_, server) = try await makeRepository()
        let clone = (server as NSString).deletingLastPathComponent + "/clone"
        try await TestGit.make().run(GitCommand("clone", "--quiet", server, clone))
        try await runGit("config", "user.name", "Ana", in: clone)
        try await runGit("config", "user.email", "ana@example.com", in: clone)
        // The clone's main has a commit it hasn't pushed, and is missing one
        // from the server, which the agent's branch starts from.
        try await commit("Local", in: clone)
        try await commit("Server", in: server)
        try await runGit("fetch", "--quiet", in: clone)
        try await runGit("switch", "--quiet", "--no-track", "--create", "agent", "origin/main", in: clone)
        for number in 1...2 { try await commit("Agent \(number)", in: clone) }

        let details = try await openSession(clone).refDetails(in: clone)
        let agent = try #require(details.branches.first { $0.shortName == "agent" })
        #expect(agent.comparison == BranchComparison(other: "main", ahead: 2, behind: 1))
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
        #expect(feature.upstream == nil)
        #expect(feature.goneUpstream == "refs/remotes/origin/feature")
        let main = try #require(details.branches.first { $0.shortName == "main" })
        #expect(main.upstream == "refs/remotes/origin/main")
        #expect(main.goneUpstream == nil)
    }

    @Test func aBranchWhoseCommitsAreAllInMainIsMerged() async throws {
        let (session, repository) = try await makeRepository()
        // done's commit is merged, fresh was made from main before that and has
        // nothing of its own, and open has a commit main doesn't.
        try await runGit("branch", "fresh", in: repository)
        try await runGit("switch", "--quiet", "--create", "done", in: repository)
        try await commit("Done", in: repository)
        try await runGit("switch", "--quiet", "--create", "open", "main", in: repository)
        try await commit("Open", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
        try await runGit("merge", "--quiet", "--no-ff", "--no-edit", "done", in: repository)

        let details = try await session.refDetails(in: repository)
        func branch(_ name: String) throws -> BranchDetails { try #require(details.branches.first { $0.shortName == name }) }
        #expect(try branch("done").isMerged)
        #expect(try branch("done").main == BranchComparison(other: "main", ahead: 0, behind: 1))
        // Its reflog says it never moved, so it hasn't been merged, however far
        // behind main it is.
        #expect(try !branch("fresh").isMerged)
        #expect(try branch("fresh").main == BranchComparison(other: "main", ahead: 0, behind: 2))
        #expect(try !branch("open").isMerged)
        #expect(try !branch("main").isMerged)
        #expect(try branch("main").main == nil)
    }

    @Test func aBranchWhoseReflogHasLostItsFirstLinesIsMergedOnceItsInMain() async throws {
        let (session, repository) = try await makeRepository()
        try await runGit("switch", "--quiet", "--create", "trimmed", in: repository)
        try await commit("One", in: repository)
        try await commit("Two", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
        try await runGit("merge", "--quiet", "--no-ff", "--no-edit", "trimmed", in: repository)
        // Only its last line is left, which moves it from one commit to the next.
        let reflog = repository + "/.git/logs/refs/heads/trimmed"
        let lines = try String(contentsOfFile: reflog, encoding: .utf8).split(separator: "\n")
        try Data((String(try #require(lines.last)) + "\n").utf8).write(to: URL(filePath: reflog))

        let details = try await session.refDetails(in: repository)
        #expect(details.branches.first { $0.shortName == "trimmed" }?.isMerged == true)
    }

    @Test func aBranchWithoutAReflogIsntMerged() async throws {
        let (session, repository) = try await makeRepository()
        try await runGit("switch", "--quiet", "--create", "done", in: repository)
        try await commit("Done", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
        try await runGit("merge", "--quiet", "--no-ff", "--no-edit", "done", in: repository)
        try FileManager.default.removeItem(atPath: repository + "/.git/logs/refs/heads/done")

        let details = try await session.refDetails(in: repository)
        #expect(details.branches.first { $0.shortName == "done" }?.isMerged == false)
    }

    @Test func aRemoteBranchThatMainHasMovedPastIsMerged() async throws {
        let (_, server) = try await makeRepository()
        try await runGit("switch", "--quiet", "--create", "done", in: server)
        try await commit("Done", in: server)
        try await runGit("switch", "--quiet", "--create", "open", "main", in: server)
        try await commit("Open", in: server)
        try await runGit("switch", "--quiet", "main", in: server)
        try await runGit("merge", "--quiet", "--no-ff", "--no-edit", "done", in: server)
        let clone = (server as NSString).deletingLastPathComponent + "/clone"
        try await TestGit.make().run(GitCommand("clone", "--quiet", server, clone))
        // Another remote's main branch isn't merged, however far behind it is.
        try await runGit("update-ref", "refs/remotes/fork/main", "origin/main~1", in: clone)
        // later is merged on the server after the clone, and the clone fetches
        // without pulling, so its main is behind origin/main.
        try await runGit("switch", "--quiet", "--create", "later", in: server)
        try await commit("Later", in: server)
        try await runGit("switch", "--quiet", "main", in: server)
        try await runGit("merge", "--quiet", "--no-ff", "--no-edit", "later", in: server)
        try await runGit("fetch", "--quiet", in: clone)

        let details = try await openSession(clone).refDetails(in: clone)
        let branches = details.remotes.flatMap(\.branches)
        func branch(_ name: String) throws -> RemoteBranchDetails { try #require(branches.first { $0.name == "refs/remotes/" + name }) }
        #expect(try branch("origin/done").isMerged)
        #expect(try branch("origin/done").main == BranchComparison(other: "main", ahead: 0, behind: 1))
        #expect(try branch("origin/later").isMerged)
        #expect(try !branch("origin/open").isMerged)
        #expect(try !branch("origin/main").isMerged)
        #expect(try !branch("fork/main").isMerged)
    }

    @Test func saysWhenTheWorktreeThatHasABranchIsLocked() async throws {
        let (session, repository) = try await makeRepository()
        let folder = (repository as NSString).deletingLastPathComponent + "/locked"
        try await runGit("worktree", "add", "--quiet", "-b", "agent/locked", folder, in: repository)
        try await runGit("worktree", "lock", "--reason=An agent is working", folder, in: repository)

        let details = try await session.refDetails(in: repository)
        #expect(details.branches.first { $0.shortName == "agent/locked" }?.isWorktreeLocked == true)
        #expect(details.branches.first { $0.shortName == "main" }?.isWorktreeLocked == false)
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
