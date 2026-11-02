import CommitGraph
import Foundation
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

    /// A model of a copy of the `basic` repository, whose settings start
    /// out empty, and which can be changed.
    func modelOfACopy(keepsCommitGraphCurrent: Bool? = nil) async throws -> (RepositoryModel, repository: String) {
        let repository = try makeTemporaryFolder() + "/basic"
        _ = try await TestGit.make().run(GitCommand("clone", "--quiet", "--no-local", try await Fixture.repository("basic"), repository))
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        let defaults = try #require(UserDefaults(suiteName: "yaga-tests-\(UUID().uuidString)"))
        if let keepsCommitGraphCurrent {
            defaults.set(keepsCommitGraphCurrent, forKey: UserDefaults.keepsCommitGraphCurrentKey)
        }
        return (RepositoryModel(session: session, worktree: repository, defaults: defaults), repository)
    }

    func chainExists(in repository: String) -> Bool {
        FileManager.default.fileExists(atPath: repository + "/.git/objects/info/commit-graphs/commit-graph-chain")
    }

    @Test func keepsTheCommitGraphUpToDateByDefault() async throws {
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
}
