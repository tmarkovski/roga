import CommitGraph
import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Keeping commit-graph files up to date, always in copies of the test
/// repositories, because it writes to them.
@Suite(.timeLimit(.minutes(1)))
struct CommitGraphUpkeepTests {
    func commit(in repository: String) async throws {
        try await runGit(
            "-c", "user.name=Ana Kovač", "-c", "user.email=ana@example.com",
            "commit", "--quiet", "--allow-empty", "--message=Newer than the files",
            in: repository
        )
    }

    func chainExists(in repository: String) -> Bool {
        FileManager.default.fileExists(atPath: repository + "/.git/objects/info/commit-graphs/commit-graph-chain")
    }

    func writes(in log: CommandLog) -> Int {
        log.entries.count { $0.arguments.contains("commit-graph") }
    }

    @Test(arguments: Fixture.History.allCases)
    func writesTheFilesOfARepositoryWithoutThem(_ fixture: Fixture.History) async throws {
        let repository = try await copyRepository(try await fixture.repository())
        let session = try await openSession(repository)
        #expect(try await session.updateCommitGraph() == .written)

        try await runGit("commit-graph", "verify", in: repository)
        let history = try #require(try await loadHistory(session).last)
        #expect(history.readCommitGraphFiles)
        #expect(history.graph.count == history.graph.storedCount)
        #expect(history.ids == (try await gitOrder(.topological, in: repository)))
    }

    @Test func leavesFilesAloneOnceTheyreUpToDate() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let log = CommandLog()
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make(log: log))
        #expect(try await session.updateCommitGraph() == .written)
        #expect(try await session.updateCommitGraph() == .upToDate)
        #expect(writes(in: log) == 1)
    }

    @Test func addsCommitsNewerThanTheFiles() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let session = try await openSession(repository)
        #expect(try await session.updateCommitGraph() == .written)

        try await commit(in: repository)
        let before = try #require(try await loadHistory(session).last)
        #expect(before.graph.count == before.graph.storedCount + 1)

        #expect(try await session.updateCommitGraph() == .written)
        let after = try #require(try await loadHistory(session).last)
        #expect(after.graph.count == after.graph.storedCount)
        #expect(after.ids == (try await gitOrder(.topological, in: repository)))
    }

    @Test func doesntWriteForADetachedHeadsOwnCommits() async throws {
        // --reachable follows refs, so writing could never add this commit.
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let log = CommandLog()
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make(log: log))
        #expect(try await session.updateCommitGraph() == .written)

        try await runGit("checkout", "--quiet", "--detach", in: repository)
        try await commit(in: repository)
        #expect(try await session.updateCommitGraph() == .upToDate)
        #expect(writes(in: log) == 1)
    }

    @Test func doesntWriteForTagsThatLeadToTrees() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let session = try await openSession(repository)
        #expect(try await session.updateCommitGraph() == .written)

        try await runGit("tag", "light-tree", "main^{tree}", in: repository)
        try await runGit("tag", "--annotate", "--message=A tree", "annotated-tree", "main^{tree}", in: repository)
        #expect(try await session.updateCommitGraph() == .upToDate)
    }

    @Test func replacesDamagedFiles() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        try await runGit("commit-graph", "write", "--reachable", in: repository)
        let file = repository + "/.git/objects/info/commit-graph"
        try FileManager.default.removeItem(atPath: file)
        try Data(repeating: 0, count: 100).write(to: URL(filePath: file))

        let session = try await openSession(repository)
        #expect(try await session.updateCommitGraph() == .written)
        let history = try #require(try await loadHistory(session).last)
        #expect(history.readCommitGraphFiles)
    }

    @Test func hasNothingToWriteWithoutCommits() async throws {
        let repository = try makeTemporaryFolder()
        try await runGit("init", "--quiet", in: repository)
        #expect(try await openSession(repository).updateCommitGraph() == .upToDate)
        #expect(!chainExists(in: repository))
    }

    @Test func worksFromTheGitDirectoryAndFromALinkedWorktree() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let notes = (repository as NSString).deletingLastPathComponent + "/notes"
        try await runGit("worktree", "add", "--quiet", notes, "feature", in: repository)

        #expect(try await openSession(repository + "/.git").updateCommitGraph() == .written)
        #expect(chainExists(in: repository))

        try await runGit("-C", notes, "-c", "user.name=Ana Kovač", "-c", "user.email=ana@example.com", "commit", "--quiet", "--allow-empty", "--message=In a worktree", in: repository)
        #expect(try await openSession(notes).updateCommitGraph() == .written)
        #expect(try await openSession(repository).updateCommitGraph() == .upToDate)
    }

    @Test func skipsAShallowClone() async throws {
        let repository = try await copyRepository(try await Fixture.History.single.repository())
        try await runGit("fetch", "--quiet", "--depth=3", "origin", in: repository)
        #expect(try await openSession(repository).updateCommitGraph() == .skipped(.shallowClone))
        #expect(!chainExists(in: repository))
    }

    @Test func skipsARepositoryWithReplaceRefs() async throws {
        let repository = try await copyRepository(try await Fixture.History.single.repository())
        try await runGit("replace", "--graft", "main~5", "main~20", in: repository)
        #expect(try await openSession(repository).updateCommitGraph() == .skipped(.replaceRefs))
        #expect(!chainExists(in: repository))
    }

    @Test func skipsARepositoryWithGrafts() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        try Data().write(to: URL(filePath: repository + "/.git/info/grafts"))
        #expect(try await openSession(repository).updateCommitGraph() == .skipped(.grafts))
        #expect(!chainExists(in: repository))
    }

    @Test func skipsARepositoryThatTurnedTheFilesOff() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        try await runGit("config", "core.commitGraph", "false", in: repository)
        #expect(try await openSession(repository).updateCommitGraph() == .skipped(.turnedOffInGit))
        #expect(!chainExists(in: repository))
    }

    @Test func skipsAFolderItCantWriteTo() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let info = repository + "/.git/objects/info"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: info)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: info) }

        #expect(try await openSession(repository).updateCommitGraph() == .skipped(.cannotWrite(folder: info)))
    }

    @Test func doesntNeedToWriteToAReadOnlyFolderWhenUpToDate() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        try await runGit("commit-graph", "write", "--reachable", in: repository)
        let info = repository + "/.git/objects/info"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: info)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: info) }

        #expect(try await openSession(repository).updateCommitGraph() == .upToDate)
    }

    @Test func failsWhileAnotherGitHoldsTheLock() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let session = try await openSession(repository)
        #expect(try await session.updateCommitGraph() == .written)

        try await commit(in: repository)
        let lock = repository + "/.git/objects/info/commit-graphs/commit-graph-chain.lock"
        try Data().write(to: URL(filePath: lock))
        await #expect(throws: GitError.self) { try await session.updateCommitGraph() }

        // Trying again works once the other git is done.
        try FileManager.default.removeItem(atPath: lock)
        #expect(try await session.updateCommitGraph() == .written)
    }

    @Test func runsOneUpdateAtATime() async throws {
        let repository = try await copyRepository(try await Fixture.History.single.repository())
        let log = CommandLog()
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make(log: log))
        async let first = session.updateCommitGraph()
        async let second = session.updateCommitGraph()
        let updates = try await [first, second]
        #expect(updates.contains(.written))
        #expect(writes(in: log) == 1)
    }

    @Test func leavesTheConfigurationAndChangedPathsAlone() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let configuration = try Data(contentsOf: URL(filePath: repository + "/.git/config"))
        let session = try await openSession(repository)
        #expect(try await session.updateCommitGraph() == .written)

        #expect(try Data(contentsOf: URL(filePath: repository + "/.git/config")) == configuration)
        let history = try #require(try await loadHistory(session).last)
        for path in history.graph.paths {
            #expect(try Data(contentsOf: URL(filePath: path)).range(of: Data("BDAT".utf8)) == nil)
        }
    }

    @Test func stopsWhenTheSessionCloses() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        let folder = try makeTemporaryFolder()
        let real = try await TestGit.installation()
        // A git that takes a long time to write, and otherwise is real git.
        let script = folder + "/git"
        try """
        #!/bin/sh
        for argument in "$@"; do
            if [ "$argument" = commit-graph ]; then
                touch \(folder)/started
                exec sleep 60
            fi
        done
        exec \(real.executable) "$@"
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let installation = try await GitInstallation.locate(configuredPath: script, searchPath: real.searchPath)
        let session = try await RepositorySession.open(
            containing: repository,
            git: Git(installation: installation, environment: TestGit.isolatedEnvironment)
        )

        let update = Task { try await session.updateCommitGraph() }
        while !FileManager.default.fileExists(atPath: folder + "/started") {
            try await Task.sleep(for: .milliseconds(5))
        }
        await session.close()
        await #expect(throws: CancellationError.self) { try await update.value }
    }
}
