import GitCore
import GitRunner

/// What deleting a branch would come to, which says whether to ask first.
public struct BranchDeletion: Sendable, Hashable {
    /// Where the branch is, which says how it's deleted.
    public enum Place: Sendable, Hashable {
        case local
        /// On a remote. This has the remote's name and its name for the branch.
        case remote(String, branch: String)
        /// A remote branch whose remote isn't configured any more, so this
        /// repository's copy is all there is to delete.
        case leftBehind
    }

    /// The branch's full name.
    public var ref: String
    public var place: Place
    /// Whether a worktree has the branch checked out, which git refuses to
    /// delete.
    public var isCheckedOut: Bool
    /// How many commits only this branch leads to, rather than another branch,
    /// a tag or a worktree's `HEAD`.
    public var lostCount: Int
    /// The newest of those commits.
    public var lost: [ObjectID]

    public var shortName: String { Ref.shortName(ref) }

    /// Whether someone should agree to this first. Deleting from a remote affects
    /// everyone who uses it, and anything else is only worth asking about when it
    /// loses commits. A branch that git will refuse to delete needs no question.
    public var asksFirst: Bool {
        if isCheckedOut { return false }
        if case .remote = place { return true }
        return lostCount > 0
    }

    /// What deleting it runs, which the alert shows. `-D` is there because the
    /// commits have been counted: `-d` only looks at `HEAD` and the upstream, so it
    /// refuses a branch whose commits are safe on another branch.
    public var arguments: [String] {
        switch place {
        case .local: ["branch", "-D"] + Self.safe(shortName)
        case .remote(let remote, let branch): ["push", "--delete", remote, Ref.branchPrefix + branch]
        case .leftBehind: Self.deletingCopy(of: shortName)
        }
    }

    /// Finds out what deleting a branch would come to.
    ///
    /// - Parameters:
    ///   - name: The full name of the branch or remote branch.
    ///   - limit: The most commits to list.
    static func prepare(ref name: String, limit: Int, in worktree: String, worktrees: [Worktree], git: Git) async throws -> BranchDeletion {
        let lost = try await LostCommits.find(
            from: [name],
            leaving: try await LostCommits.leaving([name], in: worktree, git: git),
            keeping: ["--all"],
            limit: limit,
            in: worktree,
            git: git
        )
        return BranchDeletion(
            ref: name,
            place: try await place(of: name, in: worktree, git: git),
            isCheckedOut: worktrees.contains { $0.branch == name },
            lostCount: lost.count,
            lost: lost.newest
        )
    }

    /// Says where a branch or remote branch is, which says how it's deleted.
    static func place(of name: String, in directory: String, git: Git) async throws -> Place {
        guard name.hasPrefix(Ref.remoteBranchPrefix) else { return .local }
        let remotes = try await RefDetailsLoader.remoteAddresses(git: git, in: directory)
        let short = Ref.shortName(name)
        let remote = RemoteDetails.remoteName(of: short, amongLongestFirst: remotes.keys.sorted { $0.count > $1.count })
        return remotes[remote] == nil ? .leftBehind : .remote(remote, branch: String(short.dropFirst(remote.count + 1)))
    }

    /// Deletes the branch. When a remote no longer has it, because someone else
    /// deleted it first, git refuses and leaves this repository's copy until a
    /// fetch prunes it, so that copy is what's left to delete.
    func run(in worktree: String, git: Git) async throws {
        do {
            _ = try await git.run(RemoteCommands.asked(arguments, in: worktree))
        } catch {
            guard case .remote(let remote, let branch) = place, await Self.isGone(branch, from: remote, in: worktree, git: git) else { throw error }
            _ = try await git.run(RemoteCommands.asked(Self.deletingCopy(of: shortName), in: worktree))
        }
    }

    /// Whether a remote answers that it has no such branch, rather than not
    /// answering, which `git ls-remote --exit-code` tells apart by its status.
    private static func isGone(_ branch: String, from remote: String, in worktree: String, git: Git) async -> Bool {
        var command = RemoteCommands.asked(["ls-remote", "--exit-code", remote, Ref.branchPrefix + branch], in: worktree)
        command.successStatuses = [0, 2]
        return (try? await git.run(command).status) == 2
    }

    /// `-r` deletes this repository's copy of a remote branch, whatever `-d` would
    /// say about its commits.
    private static func deletingCopy(of shortName: String) -> [String] {
        ["branch", "-d", "-r"] + safe(shortName)
    }

    /// A ref can be named like an option, even if git won't create a branch with
    /// such a name. Only those get `--end-of-options`, so that the alert shows the
    /// command as someone would type it.
    private static func safe(_ shortName: String) -> [String] {
        shortName.hasPrefix("-") ? ["--end-of-options", shortName] : [shortName]
    }
}

/// The commits that only some tips lead to, which go when those tips do.
struct LostCommits {
    var count: Int
    /// The newest of them.
    var newest: [ObjectID]

    /// - Parameters:
    ///   - tips: What's going, as revisions.
    ///   - leaving: The full names of the refs that are going, which don't keep
    ///     the commits.
    ///   - keeping: What does keep them, as arguments to `git rev-list`. An option
    ///     that lists refs, such as `--all`, comes first, because `--exclude` only
    ///     applies to the next one.
    ///   - limit: The most commits to list.
    static func find(
        from tips: [String],
        leaving: [String],
        keeping: [String],
        limit: Int,
        in directory: String,
        git: Git
    ) async throws -> LostCommits {
        guard !tips.isEmpty else { return LostCommits(count: 0, newest: []) }
        let commits = tips + ["--not"] + leaving.map { "--exclude=" + $0 } + keeping + ["--"]
        let count = try await git.text(GitCommand(["rev-list", "--count"] + commits, in: directory))
        let newest = try await git.text(GitCommand(["rev-list", "--max-count=\(limit)"] + commits, in: directory))
        return LostCommits(count: Int(count) ?? 0, newest: newest.split(separator: "\n").compactMap { ObjectID(hex: String($0)) })
    }

    /// Adds the symbolic refs that point to refs that are going. One such as
    /// `origin/HEAD` goes when its branch goes, so it doesn't keep the commits.
    static func leaving(_ names: [String], in directory: String, git: Git) async throws -> [String] {
        let refs = try await RefsLoader.load(git: git, in: directory)
        return names + refs.refs.filter { $0.symbolicTarget.map(names.contains) ?? false }.map(\.name)
    }
}
