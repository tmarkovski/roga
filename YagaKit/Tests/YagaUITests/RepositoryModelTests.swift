import AppKit
import CommitGraph
import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import YagaUI

/// The models a window keeps for the worktrees it showed, and how they load
/// history.
@Suite(.timeLimit(.minutes(1)))
struct RepositoryModelTests {
    func openSession() async throws -> RepositorySession {
        try await RepositorySession.open(containing: try await Fixture.repository("basic"), git: try await TestGit.make())
    }

    func selection(_ number: Int) -> WorktreeSelection {
        WorktreeSelection(repository: "/work/yaga/.git", worktree: "/work/\(number)")
    }

    @Test func keepsTheModelsOfRecentWorktrees() async throws {
        let session = try await openSession()
        let recent = RecentWorktrees()
        let models = (0..<RecentWorktrees.limit).map { recent.model(for: selection($0), session: session) }
        #expect(recent.model(for: selection(0), session: session) === models[0])

        // The first was shown again, so the second one goes to make room.
        _ = recent.model(for: selection(RecentWorktrees.limit), session: session)
        #expect(recent.model(for: selection(0), session: session) === models[0])
        #expect(recent.model(for: selection(2), session: session) === models[2])
        #expect(recent.model(for: selection(1), session: session) !== models[1])
    }

    @Test func replacesAModelWhoseSessionWasReplaced() async throws {
        let recent = RecentWorktrees()
        let model = recent.model(for: selection(0), session: try await openSession())
        #expect(recent.model(for: selection(0), session: try await openSession()) !== model)
    }

    @Test func loadsHistoryOncePerRequest() async throws {
        let repository = try await Fixture.repository("basic")
        let model = RepositoryModel(session: try await openSession(), worktree: repository)
        await model.load()
        #expect(model.history?.isComplete == true)
        let version = model.historyVersion

        await model.load()
        #expect(model.historyVersion == version)
        model.sort = .date
        await model.load()
        #expect(model.historyVersion > version)
        #expect(model.history?.sort == .date)
    }

    /// A model of a copy of the `basic` repository, which can be changed.
    func modelOfACopy(keepsCommitGraphCurrent: Bool = true) async throws -> (RepositoryModel, repository: String) {
        let repository = try makeTemporaryFolder() + "/basic"
        _ = try await TestGit.make().run(GitCommand("clone", "--quiet", "--no-local", try await Fixture.repository("basic"), repository))
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        return (RepositoryModel(session: session, worktree: repository, keepsCommitGraphCurrent: { keepsCommitGraphCurrent }), repository)
    }

    func chainExists(in repository: String) -> Bool {
        FileManager.default.fileExists(atPath: repository + "/.git/objects/info/commit-graphs/commit-graph-chain")
    }

    @Test func keepingTheCommitGraphUpToDateIsOnByDefault() throws {
        // Nothing writes to these settings, so they leave no file behind.
        let settings = try #require(UserDefaults(suiteName: "yaga-tests-never-written"))
        #expect(settings.keepsCommitGraphCurrent)
    }

    @Test func keepsTheCommitGraphUpToDate() async throws {
        let (model, repository) = try await modelOfACopy()
        model.updateCommitGraph()
        #expect(model.commitGraphState == .updating)
        #expect(model.slowHistoryExplanation?.contains("writing one in the background") == true)
        await model.commitGraphUpdate?.value

        #expect(model.commitGraphState == .finished(.written))
        #expect(model.slowHistoryExplanation == nil)
        #expect(chainExists(in: repository))

        model.updateCommitGraph()
        await model.commitGraphUpdate?.value
        #expect(model.commitGraphState == .finished(.upToDate))
    }

    @Test func leavesTheCommitGraphAloneWhenTurnedOff() async throws {
        let (model, repository) = try await modelOfACopy(keepsCommitGraphCurrent: false)
        model.updateCommitGraph()
        #expect(model.commitGraphUpdate == nil)
        #expect(model.commitGraphState == .turnedOff)
        #expect(model.slowHistoryExplanation?.contains("Settings") == true)
        #expect(!chainExists(in: repository))
    }

    @Test func saysWhyItWontWriteTheCommitGraph() async throws {
        let (model, repository) = try await modelOfACopy()
        _ = try await TestGit.make().run(GitCommand("config", "core.commitGraph", "false", in: repository))
        model.updateCommitGraph()
        await model.commitGraphUpdate?.value
        #expect(model.commitGraphState == .finished(.skipped(.turnedOffInGit)))
        #expect(model.slowHistoryExplanation?.contains("core.commitGraph") == true)
    }

    @Test func onlyCallsHistorySlowInALargeRepository() async throws {
        let (model, _) = try await modelOfACopy(keepsCommitGraphCurrent: false)
        await model.load()
        #expect(model.history?.readCommitGraphFiles == false)
        #expect(!model.historyWasSlowToLoad)
    }

    @Test func loadsHistoryAgainAfterALoadWasCancelled() async throws {
        let repository = try await Fixture.repository("basic")
        let model = RepositoryModel(session: try await openSession(), worktree: repository)
        // Like switching to another worktree before history has loaded.
        let cancelled = Task { await model.load() }
        cancelled.cancel()
        await cancelled.value
        #expect(model.history?.isComplete != true)

        await model.load()
        #expect(model.history?.isComplete == true)
    }

    /// A model of the `basic` repository with its history loaded.
    func loadedModel() async throws -> RepositoryModel {
        let model = RepositoryModel(session: try await openSession(), worktree: try await Fixture.repository("basic"))
        await model.load()
        return model
    }

    func row(of hex: String, in model: RepositoryModel) throws -> Int {
        let history = try #require(model.history)
        let id = try #require(ObjectID(hex: hex))
        let position = try #require(history.graph.position(of: id))
        return try #require(history.rows.firstIndex(of: position))
    }

    @Test func showsTheSelectedCommit() async throws {
        let model = try await loadedModel()
        #expect(model.selectedCommit.id == nil)

        model.selectRow(try row(of: Fixture.Basic.main, in: model))
        #expect(model.selectedCommit.id == ObjectID(hex: Fixture.Basic.main))
        await model.selectedCommit.loading?.value

        #expect(model.selectedCommit.info?.subject == "Change the app")
        #expect(model.selectedCommit.info?.body == "The body says why.")
        guard case .loaded(let files) = model.selectedCommit.files else {
            Issue.record("Files aren't loaded: \(model.selectedCommit.files)")
            return
        }
        #expect(files.map(\.path) == ["src/app.txt"])
        #expect(files.first?.lines == .init(added: 1, removed: 0))
        #expect(model.selectedCommit.problem == nil)
    }

    @Test func clearsThePanelWhenNoRowIsSelected() async throws {
        let model = try await loadedModel()
        model.selectRow(0)
        await model.selectedCommit.loading?.value
        #expect(model.selectedCommit.info != nil)

        model.selectRow(nil)
        #expect(model.selectedRow == nil)
        #expect(model.selectedCommit.id == nil)
        #expect(model.selectedCommit.info == nil)
    }

    @Test func showsTheLastCommitSelected() async throws {
        // Stepping through history, faster than git can answer.
        let model = try await loadedModel()
        for row in 0..<model.rowCount { model.selectRow(row) }
        let last = model.selectedCommit.id
        await model.selectedCommit.loading?.value

        #expect(model.selectedCommit.info?.id == last)
        let parents = try #require(model.selectedCommit.info?.parents)
        #expect(parents.isEmpty == (last == ObjectID(hex: Fixture.Basic.mainHistory[2])))
        guard case .loaded(let files) = model.selectedCommit.files else {
            Issue.record("Files aren't loaded: \(model.selectedCommit.files)")
            return
        }
        #expect(files.map(\.path) == ["README.md"])
    }

    @Test func goesToAParent() async throws {
        let model = try await loadedModel()
        let parent = try #require(ObjectID(hex: Fixture.Basic.mainHistory[1]))
        #expect(model.hasCommit(parent))
        model.select(commit: parent)
        #expect(model.selectedCommit.id == parent)
        #expect(model.selectedRow == (try row(of: Fixture.Basic.mainHistory[1], in: model)))
    }

    @Test func ignoresACommitThatHistoryDoesntHave() async throws {
        let model = try await loadedModel()
        let unknown = ObjectID(hex: String(repeating: "1", count: 40))!
        #expect(!model.hasCommit(unknown))
        model.select(commit: unknown)
        #expect(model.selectedCommit.id == nil)
        #expect(model.selectedRow == nil)
    }

    @Test func saysWhenACommitIsMissing() async throws {
        let session = try await openSession()
        let commit = SelectedCommit(session: session)
        commit.show(ObjectID(hex: String(repeating: "1", count: 40))!)
        await commit.loading?.value
        #expect(commit.info == nil)
        #expect(commit.problem?.contains("missing") == true)
    }

    @Test func findsTheSelectedCommitInItsNewRow() async throws {
        let (model, repository) = try await modelOfACopy(keepsCommitGraphCurrent: false)
        await model.load()
        // The oldest commit stays in the last row.
        model.select(commit: try #require(ObjectID(hex: Fixture.Basic.mainHistory[2])))
        let selected = model.selectedCommit.id
        let before = try #require(model.selectedRow)
        #expect(before == model.rowCount - 1)

        _ = try await TestGit.make().run(GitCommand(
            ["-c", "user.name=A", "-c", "user.email=a@example.com", "commit", "--quiet", "--allow-empty", "--message=New"],
            in: repository
        ))
        model.reload()
        await model.load()

        #expect(model.selectedCommit.id == selected)
        #expect(model.selectedRow == before + 1)
    }

    @Test func dropsASelectedCommitThatsGone() async throws {
        let (model, repository) = try await modelOfACopy(keepsCommitGraphCurrent: false)
        let git = try await TestGit.make()
        // A clone only has a remote branch for feature, and removing it leaves
        // its commit out of history.
        await model.load()
        model.select(commit: try #require(ObjectID(hex: Fixture.Basic.feature)))
        await model.selectedCommit.loading?.value
        #expect(model.selectedCommit.info != nil)

        _ = try await git.run(GitCommand("update-ref", "-d", "refs/remotes/origin/feature", in: repository))
        model.reload()
        await model.load()
        #expect(model.selectedCommit.id == nil)
        #expect(model.selectedRow == nil)
    }

    @Test func keepsTheSelectionWhileHistoryHasntReachedTheCommit() async throws {
        // History loads with its first rows and then the rest, so a commit far
        // down isn't in the rows at first.
        let repository = try await Fixture.History.single.repository()
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        let model = RepositoryModel(session: session, worktree: repository)
        await model.load()
        let last = model.rowCount - 1
        #expect(last > 300)
        model.selectRow(last)
        let selected = model.selectedCommit.id

        model.sort = .date
        await model.load()
        #expect(model.selectedCommit.id == selected)
        let row = try #require(model.selectedRow)
        let history = try #require(model.history)
        #expect(history.graph.id(at: history.rows[row]) == selected)
    }

    @Test func copiesTheFullHash() async throws {
        let model = try await loadedModel()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("yaga-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        model.selectedCommit.copyHash(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == nil)

        model.select(commit: try #require(ObjectID(hex: Fixture.Basic.main)))
        model.selectedCommit.copyHash(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == Fixture.Basic.main)
    }
}
