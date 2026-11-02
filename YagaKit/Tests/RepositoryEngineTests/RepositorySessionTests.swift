import CommitGraph
import Foundation
import GitCore
import TestSupport
import Testing
@testable import RepositoryEngine

@Suite(.timeLimit(.minutes(1)))
struct RepositorySessionTests {
    @Test func readsCommits() async throws {
        let session = try await openSession(try await Fixture.repository("basic"))
        let ids = try [
            Fixture.Basic.main,
            Fixture.Basic.feature,
            // A tree, and an ID the repository doesn't have.
            Fixture.Basic.mainTree,
            String(repeating: "0", count: 40),
        ].map { try #require(ObjectID(hex: $0)) }
        let commits = try await session.commits(ids)

        try #require(commits.count == 4)
        let main = try #require(commits[0])
        #expect(main.id == ids[0])
        #expect(main.subject == "Change the app")
        #expect(main.message == "Change the app\n\nThe body says why.\n")
        #expect(main.author == Signature(name: "Ana Kovač", email: "ana@example.com", time: 1767434400, timeZoneOffset: 0))
        #expect(main.parents == [ObjectID(hex: Fixture.Basic.mainHistory[1])])
        #expect(commits[1]?.author.name == "Sam Lee")
        #expect(commits[2] == nil)
        #expect(commits[3] == nil)
    }

    @Test func listsWorktrees() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let folder = (repository as NSString).deletingLastPathComponent
        try await runGit("worktree", "add", "--quiet", folder + "/notes", "feature", in: repository)
        try await runGit("worktree", "add", "--quiet", "--detach", folder + "/old", "main~2", in: repository)

        // From a linked worktree, the main one still comes first.
        let session = try await openSession(folder + "/notes")
        let main = try #require(ObjectID(hex: Fixture.Basic.main))
        let feature = try #require(ObjectID(hex: Fixture.Basic.feature))
        let first = try #require(ObjectID(hex: Fixture.Basic.mainHistory[2]))
        #expect(try await session.worktrees() == [
            Worktree(path: repository, head: main, branch: "refs/heads/main", isMain: true),
            Worktree(path: folder + "/notes", head: feature, branch: "refs/heads/feature"),
            Worktree(path: folder + "/old", head: first),
        ])
    }

    @Test func loadsEachWorktreesHistory() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let notes = (repository as NSString).deletingLastPathComponent + "/notes"
        try await runGit("worktree", "add", "--quiet", notes, "feature", in: repository)
        let session = try await openSession(repository)

        let main = try #require(try await loadHistory(session).last)
        #expect(main.refs.currentBranch == "refs/heads/main")
        #expect(main.head == main.graph.position(of: try #require(ObjectID(hex: Fixture.Basic.main))))

        var linked: History?
        for try await history in session.history(in: notes, sort: .topological) {
            linked = history
        }
        let history = try #require(linked)
        #expect(history.refs.currentBranch == "refs/heads/feature")
        #expect(history.head == history.graph.position(of: try #require(ObjectID(hex: Fixture.Basic.feature))))
        #expect(Set(history.ids) == Set(main.ids))
    }

    @Test func opensTheGitDirectory() async throws {
        let repository = try await Fixture.repository("basic")
        let session = try await openSession(repository + "/.git")
        #expect(session.location.worktree == nil)
        #expect(session.location.name == "basic")
        #expect(try await session.worktrees().map(\.path) == [repository])
        let history = try #require(try await loadHistory(session).last)
        #expect(history.refs.currentBranch == "refs/heads/main")
        #expect(history.rows.count == 4)
    }

    @Test func outlastsTheWorktreeItWasOpenedFrom() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let notes = (repository as NSString).deletingLastPathComponent + "/notes"
        try await runGit("worktree", "add", "--quiet", notes, "feature", in: repository)
        let session = try await openSession(notes)
        try await runGit("worktree", "remove", notes, in: repository)

        #expect(try await session.worktrees().map(\.path) == [repository])
        let commits = try await session.commits([try #require(ObjectID(hex: Fixture.Basic.feature))])
        #expect(commits.first??.subject == "Add notes")
    }

    @Test func refusesCommitsOnceClosed() async throws {
        let session = try await openSession(try await Fixture.repository("basic"))
        await session.close()
        await #expect(throws: (any Error).self) {
            try await session.commits([try #require(ObjectID(hex: Fixture.Basic.main))])
        }
    }
}
