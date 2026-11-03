import GitCore
import GitRunner

/// Loads what the refs panel lists: every branch, remote, tag and stash.
///
/// The panel loads this without anyone asking for a download, so none of these
/// commands may start one, as `ChangesLoader.status` explains. They only read
/// commits and the objects that refs point to, which a partial clone has, so
/// git has no reason to fetch anything, even a version that ignores the
/// variable.
enum RefDetailsLoader {
    /// - Parameters:
    ///   - directory: The worktree whose current branch to read.
    ///   - worktrees: The repository's worktrees, which say where each branch
    ///     is checked out.
    @concurrent
    static func load(git: Git, in directory: String, worktrees: [Worktree]) async throws -> RefDetails {
        let refs = try await RefsLoader.load(git: git, in: directory)
        let main = refs.mainBranch

        async let branches = branches(comparingWith: main, git: git, in: directory)
        async let remotesAndTags = remotesAndTags(git: git, in: directory)
        async let addresses = remoteAddresses(git: git, in: directory)
        async let stashes = refs.refs.contains { $0.name == "refs/stash" } ? stashes(git: git, in: directory) : []

        let places = Dictionary(
            worktrees.filter { !$0.isPrunable }.compactMap { worktree in worktree.branch.map { ($0, worktree.path) } },
            uniquingKeysWith: { first, _ in first }
        )
        var listed = try await branches
        for index in listed.indices {
            listed[index].worktree = places[listed[index].name]
        }
        let others = try await remotesAndTags
        return RefDetails(
            currentBranch: refs.currentBranch,
            branches: listed,
            remotes: RemoteDetails.grouping(others.remoteBranches, addresses: try await addresses),
            tags: others.tags,
            stashes: try await stashes
        )
    }

    private static func branches(comparingWith main: Ref?, git: Git, in directory: String) async throws -> [BranchDetails] {
        var command = GitCommand("for-each-ref", "--format=" + BranchListParser.format(comparingWith: main?.peeled), Ref.branchPrefix, in: directory)
        command.environment["GIT_NO_LAZY_FETCH"] = "1"
        let entries = try await parse(command, git: git, with: BranchListParser.parse)
        return entries.map { entry in
            var comparison: BranchComparison?
            if let upstream = entry.upstream, let counts = entry.upstreamCounts {
                comparison = BranchComparison(other: Ref.shortName(upstream), ahead: counts.ahead, behind: counts.behind)
            } else if let main, main.name != entry.name, let counts = entry.baseCounts {
                comparison = BranchComparison(other: main.shortName, ahead: counts.ahead, behind: counts.behind)
            }
            return BranchDetails(name: entry.name, tip: entry.tip, date: entry.date, comparison: comparison)
        }
    }

    private static func remotesAndTags(git: Git, in directory: String) async throws -> RemoteAndTagListParser.Result {
        var command = GitCommand("for-each-ref", "--format=" + RemoteAndTagListParser.format, Ref.remoteBranchPrefix, Ref.tagPrefix, in: directory)
        command.environment["GIT_NO_LAZY_FETCH"] = "1"
        return try await parse(command, git: git, with: RemoteAndTagListParser.parse)
    }

    static func remoteAddresses(git: Git, in directory: String) async throws -> [String: String] {
        try await remoteURLs(git: git, in: directory).mapValues(RemoteAddress.shown)
    }

    static func remoteURLs(git: Git, in directory: String) async throws -> [String: String] {
        var command = GitCommand(RemoteListParser.arguments, in: directory)
        command.successStatuses = [0, 1]
        return try await parse(command, git: git, with: RemoteListParser.parse)
    }

    private static func stashes(git: Git, in directory: String) async throws -> [StashDetails] {
        var command = GitCommand(StashListParser.arguments, in: directory)
        command.environment["GIT_NO_LAZY_FETCH"] = "1"
        return try await parse(command, git: git, with: StashListParser.parse)
    }

    private static func parse<Result>(
        _ command: GitCommand,
        git: Git,
        with parser: ([UInt8]) throws(ParseError) -> Result
    ) async throws -> Result {
        let output = try await git.run(command).output
        do {
            return try parser(output)
        } catch {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
    }
}
