import GitCore
import GitRunner

/// Reads where a worktree's branch stands against its upstream. The title row
/// shows this whenever it looks at the worktree, so like `RefDetailsLoader`, it
/// may not start a download.
enum BranchStatusLoader {
    /// - Returns: The status, or nil when the worktree isn't on a branch, or
    ///   its branch has no commits yet.
    @concurrent
    static func load(git: Git, in directory: String) async throws -> BranchStatus? {
        var head = GitCommand("symbolic-ref", "--quiet", "HEAD", in: directory)
        head.successStatuses = [0, 1]
        let branch = try await git.text(head)
        guard !branch.isEmpty else { return nil }

        var command = GitCommand("for-each-ref", "--format=" + BranchStatusParser.format, branch, in: directory)
        command.environment["GIT_NO_LAZY_FETCH"] = "1"
        async let remotes = RefDetailsLoader.remoteURLs(git: git, in: directory)
        async let branchRebase = setting("branch.\(Ref.shortName(branch)).rebase", git: git, in: directory)
        async let pullRebase = setting("pull.rebase", git: git, in: directory)
        let output = try await git.run(command).output

        let entry: BranchStatusParser.Entry?
        do {
            entry = try BranchStatusParser.parse(output, branch: branch)
        } catch {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
        guard let entry else { return nil }

        let names = try await remotes.keys
        let tracked = entry.trackedRemote.flatMap { names.contains($0) ? $0 : nil }
        let remote = tracked ?? (names.contains("origin") ? "origin" : nil)
        let branchSetting = try await branchRebase
        let pullSetting = try await pullRebase
        return BranchStatus(
            branch: branch,
            upstream: entry.upstream,
            upstreamIsGone: entry.upstreamIsGone,
            ahead: entry.counts.ahead,
            behind: entry.counts.behind,
            remote: remote,
            pushRemote: entry.pushRemote.flatMap { names.contains($0) ? $0 : nil } ?? remote,
            pullRebase: branchSetting ?? pullSetting
        )
    }

    /// Reads how far each of `branches` is from its upstream, with one git for
    /// all of them, at utility priority because nobody waits for it. When some
    /// have never had an upstream, two more gits find the main branch and how
    /// far those are ahead of it.
    @concurrent
    static func upstreams(of branches: [String], git: Git, in directory: String) async throws -> BranchCounts {
        guard !branches.isEmpty else { return BranchCounts() }
        var command = GitCommand(["for-each-ref", "--format=" + BranchStatusParser.format] + branches, in: directory)
        command.priority = .utility
        command.environment["GIT_NO_LAZY_FETCH"] = "1"
        let output = try await git.run(command).output
        var counts = BranchCounts()
        var untracked: [String] = []
        for branch in branches {
            let entry: BranchStatusParser.Entry?
            do {
                entry = try BranchStatusParser.parse(output, branch: branch)
            } catch {
                throw RepositoryError.unexpectedOutput(command, error.description)
            }
            guard let entry else { continue }
            if entry.upstream != nil || entry.upstreamIsGone {
                counts.upstreams[branch] = UpstreamCounts(ahead: entry.counts.ahead, behind: entry.counts.behind, isGone: entry.upstreamIsGone)
            } else {
                untracked.append(branch)
            }
        }
        if !untracked.isEmpty {
            counts.aheadOfMain = try await aheadOfMain(untracked, git: git, in: directory)
        }
        return counts
    }

    /// How many commits each of `branches` has that neither the main branch nor
    /// its upstream has, for the ones that have any. Counting against the
    /// upstream too leaves out what the main branch hasn't pulled yet, for a
    /// branch made from its upstream, and counting against the main branch
    /// leaves out what it hasn't pushed, for a branch made from it.
    private static func aheadOfMain(_ branches: [String], git: Git, in directory: String) async throws -> [String: MainCounts] {
        let refs = try await RefsLoader.load(git: git, in: directory, priority: .utility)
        guard let main = refs.mainBranch else { return [:] }
        let upstream = main.upstream.flatMap { name in refs.refs.first { $0.name == name } }
        let bases = [main.peeled] + [upstream?.peeled].compactMap(\.self)

        var command = GitCommand(["for-each-ref", "--format=" + AheadOfMainParser.format(comparingWith: bases)] + branches, in: directory)
        command.priority = .utility
        command.environment["GIT_NO_LAZY_FETCH"] = "1"
        let output = try await git.run(command).output
        let ahead: [String: Int]
        do {
            ahead = try AheadOfMainParser.parse(output, bases: bases.count)
        } catch {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
        return ahead.mapValues { MainCounts(main: main.shortName, ahead: $0) }
    }

    private static func setting(_ name: String, git: Git, in directory: String) async throws -> String? {
        var command = GitCommand("config", "--get", name, in: directory)
        command.successStatuses = [0, 1]
        let value = try await git.text(command)
        return value.isEmpty ? nil : value
    }
}
