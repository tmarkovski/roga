import Foundation
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
    ///   - commonDirectory: The repository's git directory, which holds the
    ///     branches' reflogs.
    ///   - worktrees: The repository's worktrees, which say where each branch
    ///     is checked out.
    @concurrent
    static func load(git: Git, in directory: String, commonDirectory: String, worktrees: [Worktree]) async throws -> RefDetails {
        let refs = try await RefsLoader.load(git: git, in: directory)

        async let branches = branches(comparingWithMainOf: refs, git: git, in: directory, commonDirectory: commonDirectory)
        async let remoteBranches = remoteBranches(comparingWithMainOf: refs, git: git, in: directory)
        async let tags = tags(git: git, in: directory)
        async let addresses = remoteAddresses(git: git, in: directory)
        async let stashes = refs.refs.contains { $0.name == "refs/stash" } ? stashes(git: git, in: directory) : []

        let checkouts = Dictionary(
            worktrees.filter { !$0.isPrunable }.compactMap { worktree in worktree.branch.map { ($0, worktree) } },
            uniquingKeysWith: { first, _ in first }
        )
        var listed = try await branches
        for index in listed.indices {
            guard let worktree = checkouts[listed[index].name] else { continue }
            listed[index].worktree = worktree.path
            listed[index].isWorktreeLocked = worktree.isLocked
        }
        var remotes = RemoteDetails.grouping(try await remoteBranches, addresses: try await addresses)
        // A remote's own main branch isn't merged into the main branch, however
        // far behind it is, and neither is another remote's of the same name.
        let main = refs.mainBranch
        let mainName = main.flatMap { $0.kind == .branch ? $0.shortName : nil }
        let mainRefs = Set([main?.name, main?.upstream, refs.remoteMainBranch?.name].compactMap(\.self))
        for remote in remotes.indices {
            for index in remotes[remote].branches.indices {
                let branch = remotes[remote].branches[index]
                if branch.isMerged, mainRefs.contains(branch.name) || branch.shortName == mainName {
                    remotes[remote].branches[index].isMerged = false
                }
            }
        }
        return RefDetails(
            currentBranch: refs.currentBranch,
            branches: listed,
            remotes: remotes,
            tags: try await tags,
            stashes: try await stashes
        )
    }

    /// Every branch, with how far it is from its upstream, or else from the
    /// main branch. A branch is behind the main branch by what the main branch
    /// has that it doesn't, and ahead by the fewest commits it has that the
    /// main branch, its upstream or the remote's main branch doesn't, as on a
    /// worktree's tab, so that what the main branch hasn't pulled yet doesn't
    /// count for a branch made from the remote.
    private static func branches(
        comparingWithMainOf refs: RefList,
        git: Git,
        in directory: String,
        commonDirectory: String
    ) async throws -> [BranchDetails] {
        let main = refs.mainBranch
        let others = Array(refs.mainBranchCommits.dropFirst())
        let format = BranchListParser.format(comparingWith: main?.peeled, alsoAheadOf: others)
        var command = GitCommand("for-each-ref", "--format=" + format, Ref.branchPrefix, in: directory)
        command.environment["GIT_NO_LAZY_FETCH"] = "1"
        let entries = try await parse(command, git: git) { output throws(ParseError) in
            try BranchListParser.parse(output, others: others.count)
        }
        return entries.map { entry in
            var fromMain: BranchComparison?
            if let main, main.name != entry.name, let counts = entry.baseCounts {
                fromMain = BranchComparison(other: main.shortName, ahead: counts.ahead, behind: counts.behind)
            }
            var comparison = fromMain
            if let upstream = entry.upstream, let counts = entry.upstreamCounts {
                comparison = BranchComparison(other: Ref.shortName(upstream), ahead: counts.ahead, behind: counts.behind)
            }
            // Only a branch whose commits are all in the main branch can be
            // merged, so only those need their reflog read.
            let isMerged = fromMain?.ahead == 0
                && hasMoved(entry.name, to: entry.tip, commonDirectory: commonDirectory) == true
            return BranchDetails(
                name: entry.name,
                tip: entry.tip,
                date: entry.date,
                comparison: comparison,
                upstream: entry.upstream,
                goneUpstream: entry.goneUpstream,
                main: fromMain,
                isMerged: isMerged
            )
        }
    }

    /// Whether a branch has moved since it was made, from the first line of its
    /// reflog, which git keeps in the common directory's `logs` folder, as
    /// `<old> <new> <who> <when>\t<what>`. A branch's first line is usually its
    /// making, with an `<old>` of zeros and the commit it was made at as `<new>`,
    /// so it has moved if its tip is somewhere else now. Once git has expired the
    /// oldest lines, or lost them as a worktree's branch can, the first line is a
    /// move from `<old>` to `<new>`, so it has moved. A rename keeps the reflog,
    /// and adds to its end.
    ///
    /// - Returns: Nil when the branch has no reflog, as when
    ///   `core.logAllRefUpdates` is off or the refs are kept in a reftable,
    ///   which means there's no telling.
    static func hasMoved(_ name: String, to tip: ObjectID, commonDirectory: String) -> Bool? {
        guard let handle = FileHandle(forReadingAtPath: commonDirectory + "/logs/" + name) else { return nil }
        defer { try? handle.close() }
        // The two object IDs fit in the first 130 bytes, even with SHA-256.
        guard let start = try? handle.read(upToCount: 160) else { return nil }
        let fields = start.split(separator: UInt8(ascii: " "), maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2, let made = ObjectID(hexDigits: fields[1]) else { return nil }
        let wasMade = fields[0].allSatisfy { $0 == UInt8(ascii: "0") }
        return !wasMade || made != tip
    }

    /// Every remote branch, with how far it is from the main branch, as a local
    /// branch is. One whose commits are all in the main branch, which has moved
    /// on past it, counts as merged. A remote branch has no reflog to say
    /// whether it ever had commits of its own, but one with none that the main
    /// branch has moved past is as safe to delete as a merged one.
    private static func remoteBranches(comparingWithMainOf refs: RefList, git: Git, in directory: String) async throws -> [RemoteBranchDetails] {
        let main = refs.mainBranch
        let bases = refs.mainBranchCommits
        let format = RemoteAndTagListParser.remoteBranchFormat(comparingWith: bases.first, alsoAheadOf: Array(bases.dropFirst()))
        var command = GitCommand("for-each-ref", "--format=" + format, Ref.remoteBranchPrefix, in: directory)
        command.environment["GIT_NO_LAZY_FETCH"] = "1"
        let result = try await parse(command, git: git) { output throws(ParseError) in
            try RemoteAndTagListParser.parse(output, counts: bases.count)
        }
        return result.remoteBranches.map { branch in
            var branch = branch
            guard let main, let counts = result.mainCounts[branch.name] else { return branch }
            branch.main = BranchComparison(other: main.shortName, ahead: counts.ahead, behind: counts.behind)
            // On one of the main branch's own commits, it's where main is
            // rather than merged into it. The local main branch can be behind
            // its upstream, so being behind main isn't enough.
            branch.isMerged = counts.ahead == 0 && !bases.contains(branch.tip)
            return branch
        }
    }

    private static func tags(git: Git, in directory: String) async throws -> [TagDetails] {
        var command = GitCommand("for-each-ref", "--format=" + RemoteAndTagListParser.format, Ref.tagPrefix, in: directory)
        command.environment["GIT_NO_LAZY_FETCH"] = "1"
        return try await parse(command, git: git, with: { output throws(ParseError) in try RemoteAndTagListParser.parse(output) }).tags
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
