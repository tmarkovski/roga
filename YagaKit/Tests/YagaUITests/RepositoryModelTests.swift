import CommitGraph
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
