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
    /// all of them, at utility priority because nobody waits for it.
    ///
    /// - Returns: The counts by each branch's full name, for the branches that
    ///   have an upstream or had one that's gone.
    @concurrent
    static func upstreams(of branches: [String], git: Git, in directory: String) async throws -> [String: UpstreamCounts] {
        guard !branches.isEmpty else { return [:] }
        var command = GitCommand(["for-each-ref", "--format=" + BranchStatusParser.format] + branches, in: directory)
        command.priority = .utility
        command.environment["GIT_NO_LAZY_FETCH"] = "1"
        let output = try await git.run(command).output
        var upstreams: [String: UpstreamCounts] = [:]
        for branch in branches {
            let entry: BranchStatusParser.Entry?
            do {
                entry = try BranchStatusParser.parse(output, branch: branch)
            } catch {
                throw RepositoryError.unexpectedOutput(command, error.description)
            }
            guard let entry, entry.upstream != nil || entry.upstreamIsGone else { continue }
            upstreams[branch] = UpstreamCounts(ahead: entry.counts.ahead, behind: entry.counts.behind, isGone: entry.upstreamIsGone)
        }
        return upstreams
    }

    private static func setting(_ name: String, git: Git, in directory: String) async throws -> String? {
        var command = GitCommand("config", "--get", name, in: directory)
        command.successStatuses = [0, 1]
        let value = try await git.text(command)
        return value.isEmpty ? nil : value
    }
}
