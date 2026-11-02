import GitRunner
import RepositoryEngine

/// Measures bringing a repository's commit-graph files up to date, at the low
/// priority the app runs it at (decision 6). This writes to the repository,
/// so give it a copy.
struct CommitGraphBenchmark {
    var repository: String

    init(arguments: [String]) throws {
        guard let repository = arguments.first else { throw UsageError(description: "Name a repository") }
        self.repository = repository
    }

    func run() async throws {
        let git = Git(installation: try await GitInstallation.locate())
        let session = try await RepositorySession.open(containing: repository, git: git)
        print("git \(git.installation.version), updating the commit-graph files of \(repository)")
        let clock = ContinuousClock()
        let start = clock.now
        let update = try await session.updateCommitGraph()
        print("\(update) after \(clock.now - start)")
        await session.close()
    }
}
