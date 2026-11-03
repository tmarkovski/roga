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
        var place = Place.local
        if name.hasPrefix(Ref.remoteBranchPrefix) {
            let remotes = try await RefDetailsLoader.remoteAddresses(git: git, in: worktree)
            let short = Ref.shortName(name)
            let remote = RemoteDetails.remoteName(of: short, amongLongestFirst: remotes.keys.sorted { $0.count > $1.count })
            place = remotes[remote] == nil ? .leftBehind : .remote(remote, branch: String(short.dropFirst(remote.count + 1)))
        }
        // A symbolic ref such as `origin/HEAD` goes when its branch goes, so it
        // doesn't keep the commits.
        let refs = try await RefsLoader.load(git: git, in: worktree)
        let leaving = [name] + refs.refs.filter { $0.symbolicTarget == name }.map(\.name)
        let commits = [name, "--not"] + leaving.map { "--exclude=" + $0 } + ["--all", "--"]
        let count = try await git.text(GitCommand(["rev-list", "--count"] + commits, in: worktree))
        let newest = try await git.text(GitCommand(["rev-list", "--max-count=\(limit)"] + commits, in: worktree))
        return BranchDeletion(
            ref: name,
            place: place,
            isCheckedOut: worktrees.contains { $0.branch == name },
            lostCount: Int(count) ?? 0,
            lost: newest.split(separator: "\n").compactMap { ObjectID(hex: String($0)) }
        )
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
