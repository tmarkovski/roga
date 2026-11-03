import GitCore
import GitRunner

/// What checking out a branch came to.
public enum BranchCheckout: Sendable, Hashable {
    /// The worktree is on the branch now. This has the branch's full name, which
    /// for a remote branch is the local branch's.
    case checkedOut(String)
    /// Another worktree has the branch checked out, which git doesn't allow
    /// twice, so nothing changed. This has that worktree's folder.
    case inOtherWorktree(String)

    /// Switches to a local branch. A remote branch goes through the local branch
    /// of the same name, as `git switch <name>` does: it's created to track the
    /// remote branch, or if it's there already, switched to as it is.
    static func run(ref name: String, in worktree: String, worktrees: [Worktree], git: Git) async throws -> BranchCheckout {
        let refs = try await RefsLoader.load(git: git, in: worktree)
        var local = name
        if name.hasPrefix(Ref.remoteBranchPrefix) {
            let remotes = try await RefDetailsLoader.remoteAddresses(git: git, in: worktree)
            let short = Ref.shortName(name)
            let remote = RemoteDetails.remoteName(of: short, amongLongestFirst: remotes.keys.sorted { $0.count > $1.count })
            let branch = String(short.dropFirst(remote.count + 1))
            local = Ref.branchPrefix + branch
            if !refs.refs.contains(where: { $0.name == local }) {
                // On its own, --track would take the name from after the first
                // slash, which is wrong for a remote with a slash in its name.
                try await run(["switch", "--create=" + branch, "--track", name], in: worktree, git: git)
                return .checkedOut(local)
            }
        }
        // git says the same about a worktree that's gone, but only it can say
        // what to do about that one.
        if local != refs.currentBranch, let other = worktrees.first(where: { $0.branch == local && !$0.isPrunable }) {
            return .inOtherWorktree(other.path)
        }
        // A ref can be named like an option, even if git won't create a branch
        // with such a name.
        try await run(["switch", "--end-of-options", Ref.shortName(local)], in: worktree, git: git)
        return .checkedOut(local)
    }

    private static func run(_ arguments: [String], in worktree: String, git: Git) async throws {
        var command = GitCommand(arguments, in: worktree)
        command.takesOptionalLocks = true
        _ = try await git.run(command)
    }
}
