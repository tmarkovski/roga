import CommitGraph
import Foundation
import GitCore
import GitRunner
import HistoryUI
import RepositoryEngine
import TestSupport
import Testing
@testable import RogaUI

/// Several commits, a branch's review and a stash in the panels under history
/// (decision 54). The `basic` repository has three commits on main, and a branch
/// called feature with one commit, which left main after its second.
@Suite(.timeLimit(.minutes(1)))
struct ReviewSelectionTests {
    let main = Fixture.Basic.mainHistory.map { ObjectID(hex: $0)! }
    let feature = ObjectID(hex: Fixture.Basic.feature)!

    /// A model of the `basic` repository with its history loaded.
    func loadedModel() async throws -> RepositoryModel {
        let repository = try await Fixture.repository("basic")
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        let model = RepositoryModel(session: session, worktree: repository)
        await model.load()
        return model
    }

    func row(of id: ObjectID, in model: RepositoryModel) throws -> Int {
        let history = try #require(model.history)
        let position = try #require(history.graph.position(of: id))
        return try #require(history.rows.firstIndex(of: position))
    }

    func rows(_ ids: ObjectID..., in model: RepositoryModel) throws -> IndexSet {
        IndexSet(try ids.map { try row(of: $0, in: model) })
    }

    @discardableResult
    func runGit(_ arguments: String..., in folder: String) async throws -> String {
        try await TestGit.make().text(GitCommand(arguments, in: folder))
    }

    @Test func aRunOfCommitsIsOneDiffFromTheOldestOnesParent() async throws {
        let model = try await loadedModel()
        model.selectRows(try rows(main[0], main[1], in: model))
        await model.selectedCommit.loading?.value

        let comparison = try #require(model.selectedCommit.comparison)
        #expect(comparison.kind == .run(count: 2, oldest: main[1]))
        #expect(comparison.from == main[2])
        #expect(comparison.to == main[0])
        #expect(model.selectedCommit.files.all.map(\.path) == ["src/app.txt"])
        #expect(model.selectedCommit.files.all.first?.lines == .init(added: 2, removed: 0))
        #expect(model.selectedCommit.selectedFile.file?.path == "src/app.txt")
        #expect(model.selectedCommit.id == nil)
        #expect(model.selectedRow == nil)
    }

    @Test func aRunDownToTheFirstCommitComparesWithNothing() async throws {
        let model = try await loadedModel()
        model.selectRows(try rows(main[1], main[2], in: model))
        await model.selectedCommit.loading?.value

        let comparison = try #require(model.selectedCommit.comparison)
        #expect(comparison.from == nil)
        #expect(comparison.to == main[1])
        #expect(model.selectedCommit.files.all.map(\.path) == ["README.md", "src/app.txt"])
        #expect(model.selectedCommit.files.all.map(\.status) == [.added, .added])
    }

    @Test func twoCommitsOnDifferentLinesAreComparedAndCanBeSwapped() async throws {
        let model = try await loadedModel()
        model.selectRows(try rows(main[0], feature, in: model))
        await model.selectedCommit.loading?.value

        let comparison = try #require(model.selectedCommit.comparison)
        #expect(comparison.kind == .pair)
        // From the lower row to the upper one.
        let older = try row(of: main[0], in: model) > row(of: feature, in: model) ? main[0] : feature
        #expect(comparison.from == older)
        #expect(Set([comparison.from, comparison.to]) == Set([main[0], feature]))
        #expect(model.selectedCommit.fromInfo?.id == comparison.from)
        #expect(model.selectedCommit.info?.id == comparison.to)
        #expect(model.selectedCommit.files.all.map(\.path).sorted() == ["NOTES.md", "src/app.txt"])

        let swapped = try #require(comparison.swapped)
        model.compare(swapped)
        await model.selectedCommit.loading?.value
        #expect(model.selectedCommit.comparison?.from == comparison.to)
        #expect(model.selectedRows == (try rows(main[0], feature, in: model)))
    }

    @Test func commitsThatArentOneLineDontMakeOneDiff() async throws {
        let model = try await loadedModel()
        model.selectRows(try rows(main[0], feature, main[2], in: model))
        #expect(model.selectedCommit.subject == .scattered(3))
        await model.selectedCommit.loading?.value
        #expect(model.selectedCommit.files.all.isEmpty)
        #expect(model.selectedCommit.selectedFile.file == nil)
        #expect(!model.canFilterFiles)
    }

    @Test func oneRowOfSeveralGoesBackToOneCommit() async throws {
        let model = try await loadedModel()
        model.selectRows(try rows(main[0], main[1], in: model))
        let row = try row(of: main[0], in: model)
        model.selectRows(IndexSet(integer: row))
        #expect(model.selectedCommit.id == main[0])
        #expect(model.selectedRow == row)
    }

    @Test func reviewsABranchSinceItLeftMain() async throws {
        let model = try await loadedModel()
        #expect(model.reviewBase(for: "refs/heads/main") == nil)
        #expect(model.reviewBase(for: "refs/heads/feature")?.refs == ["refs/heads/main"])

        model.review(branch: "refs/heads/feature")
        await model.selecting?.value
        await model.selectedCommit.loading?.value

        let comparison = try #require(model.selectedCommit.comparison)
        #expect(comparison.kind == .branch(name: "refs/heads/feature", against: "refs/heads/main", count: 1, hasMore: false))
        #expect(comparison.from == main[1])
        #expect(comparison.to == feature)
        #expect(model.reviewedBranch == "refs/heads/feature")
        #expect(model.selectedRows == (try rows(feature, in: model)))
        #expect(model.selectedCommit.files.all.map(\.path) == ["NOTES.md"])
        #expect(model.refs.selectedRef == "refs/heads/feature")

        // History marks where the branch left main.
        #expect(model.mark?.commit == main[1])
        let marked = model.rowContent(try row(of: main[1], in: model)).badges.last
        #expect(marked == CommitRowContent.Badge(title: "merge base", kind: .mark))

        // Clicking the branch's one commit shows that commit, and the mark goes.
        model.selectRows(try rows(feature, in: model))
        #expect(model.selectedCommit.id == feature)
        #expect(model.mark == nil)
        #expect(model.rowContent(try row(of: main[1], in: model)).badges.allSatisfy { $0.kind != .mark })
    }

    @Test func aReviewFollowsTheBranchWhenItMoves() async throws {
        let repository = try makeTemporaryFolder() + "/basic"
        try await runGit("clone", "--quiet", "--no-local", try await Fixture.repository("basic"), repository, in: try makeTemporaryFolder())
        try await runGit("branch", "--quiet", "feature", "origin/feature", in: repository)
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        let model = RepositoryModel(session: session, worktree: repository)
        await model.load()
        model.review(branch: "refs/heads/feature")
        await model.selecting?.value
        #expect(model.selectedCommit.comparison?.to == feature)

        // An agent commits on the branch in another worktree.
        let other = try makeTemporaryFolder() + "/feature"
        try await runGit("worktree", "add", "--quiet", other, "feature", in: repository)
        try await runGit("-c", "user.name=Ana", "-c", "user.email=ana@example.com", "commit", "--quiet", "--allow-empty", "--message=More", in: other)
        let tip = try #require(ObjectID(hex: try await runGit("rev-parse", "feature", in: repository)))
        model.reload()
        await model.load()
        await model.selecting?.value

        let comparison = try #require(model.selectedCommit.comparison)
        #expect(comparison.to == tip)
        #expect(comparison.kind == .branch(name: "refs/heads/feature", against: "refs/heads/main", count: 2, hasMore: false))
        #expect(model.selectedRows.count == 2)
    }

    @Test func showsAStashWithTheCommitItWasMadeOnMarked() async throws {
        let repository = try makeTemporaryFolder() + "/basic"
        try await runGit("clone", "--quiet", "--no-local", try await Fixture.repository("basic"), repository, in: try makeTemporaryFolder())
        try Data("yaga\nmore\n".utf8).write(to: URL(filePath: repository + "/README.md"))
        try await runGit("add", "README.md", in: repository)
        try Data("one\ntwo\nthree\n".utf8).write(to: URL(filePath: repository + "/src/app.txt"))
        try await runGit("-c", "user.name=Ana", "-c", "user.email=ana@example.com", "stash", "push", "--quiet", "--message=Try it", in: repository)
        let commit = try #require(ObjectID(hex: try await runGit("rev-parse", "stash@{0}", in: repository)))
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        let model = RepositoryModel(session: session, worktree: repository)
        await model.load()
        model.selectRow(try row(of: feature, in: model))

        let stash = StashDetails(position: 0, commit: commit, message: "On main: Try it")
        model.select(stash: stash)
        await model.selecting?.value
        await model.selectedCommit.loading?.value

        #expect(model.selectedCommit.stash == stash)
        #expect(model.selectedRows.isEmpty)
        #expect(model.selectedCommit.stashBase == main[0])
        guard case .loaded(let groups) = model.selectedCommit.files else {
            Issue.record("Files aren't loaded: \(model.selectedCommit.files)")
            return
        }
        #expect(groups.map(\.group) == [.staged, .unstaged])
        #expect(groups.map { $0.files.map(\.path) } == [["README.md"], ["src/app.txt"]])
        // The first file is selected, from its group.
        #expect(model.selectedCommit.selectedFile.group == .staged)
        #expect(model.selectedCommit.hashToCopy == commit)
        #expect(model.mark?.commit == main[0])
        #expect(model.mark?.title == "stash@{0}")

        // The arrow keys go from one group to the next.
        model.selectFile(by: 1)
        #expect(model.selectedCommit.selectedFile.group == .unstaged)
        #expect(model.selectedCommit.selectedFile.file?.path == "src/app.txt")

        // A row in history shows its commit again.
        model.selectRow(try row(of: main[0], in: model))
        #expect(model.selectedCommit.id == main[0])
        #expect(model.mark == nil)
    }
}
