import Foundation
import GitCore
import GitRunner

/// What removing a linked worktree would lose for good, because git doesn't
/// have it anywhere else (decision 22).
///
/// yaga looks for itself because `git worktree remove` only refuses over what
/// its own `git status` lists, and a submodule. It deletes ignored files without
/// a word, and untracked files too when `status.showUntrackedFiles` is off. It
/// also says nothing about commits that only the worktree's detached `HEAD` leads
/// to, or a rebase that's partway through, and those go with the worktree.
public struct WorktreeLosses: Sendable, Hashable {
    /// The worktree's folder is gone already, so there's nothing left to lose.
    public var folderIsMissing = false
    /// The branch the worktree has checked out, by its full name, which doesn't
    /// go with the worktree unless someone asks. It's nil for a detached `HEAD`.
    public var branch: String?
    /// The main branch, when it has all of `branch`'s commits, so that deleting
    /// `branch` too would lose nothing. It's nil when `branch` is the main branch.
    public var mergedInto: String?
    /// The tracked files with uncommitted changes, each one once.
    public var changedFiles: [String] = []
    public var untrackedFiles: [String] = []
    /// What's ignored. A folder that's ignored as a whole is one item, and its
    /// name ends in a slash.
    public var ignored: [String] = []
    /// How many commits only the worktree's detached `HEAD` leads to.
    public var detachedCommits = 0
    /// A merge or a rebase that's partway through in the worktree.
    public var stoppedPull: StoppedPull?
    /// Whether the worktree has submodules checked out. git can't say whether
    /// they're safe to delete, so it refuses to remove them unless forced.
    public var hasSubmodules = false

    public init(
        folderIsMissing: Bool = false,
        branch: String? = nil,
        mergedInto: String? = nil,
        changedFiles: [String] = [],
        untrackedFiles: [String] = [],
        ignored: [String] = [],
        detachedCommits: Int = 0,
        stoppedPull: StoppedPull? = nil,
        hasSubmodules: Bool = false
    ) {
        self.folderIsMissing = folderIsMissing
        self.branch = branch
        self.mergedInto = mergedInto
        self.changedFiles = changedFiles
        self.untrackedFiles = untrackedFiles
        self.ignored = ignored
        self.detachedCommits = detachedCommits
        self.stoppedPull = stoppedPull
        self.hasSubmodules = hasSubmodules
    }

    /// Whether git has to be forced, because it refuses otherwise. Untracked
    /// files count even when `status.showUntrackedFiles` means it wouldn't
    /// refuse, because they're lost all the same.
    public var needsForce: Bool {
        !changedFiles.isEmpty || !untrackedFiles.isEmpty || hasSubmodules
    }

    /// Whether anything would be lost at all.
    public var isEmpty: Bool {
        !needsForce && ignored.isEmpty && detachedCommits == 0 && stoppedPull == nil
    }

    /// Looks through a worktree, without changing anything. It lists every
    /// untracked file whatever the user's settings say, because someone asked to
    /// delete them, and only needs to read each ignored folder's name.
    @concurrent
    static func load(in worktree: String, git: Git) async throws -> WorktreeLosses {
        guard FileManager.default.fileExists(atPath: worktree) else { return WorktreeLosses(folderIsMissing: true) }
        var losses = WorktreeLosses()

        let status = try await ChangesLoader.status(in: worktree, git: git, listsEveryUntrackedFile: true)
        var seen: Set<String> = []
        losses.changedFiles = (status.conflicted + status.unstaged + status.staged).map(\.path).filter { seen.insert($0).inserted }
        losses.untrackedFiles = status.untracked.map(\.path)

        let ignored = GitCommand("ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory", in: worktree)
        losses.ignored = try await git.run(ignored).output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }

        var branch = GitCommand("symbolic-ref", "--quiet", "HEAD", in: worktree)
        branch.successStatuses = [0, 1]
        let name = try await git.text(branch)
        if name.isEmpty {
            let commits = GitCommand("rev-list", "--count", "HEAD", "--not", "--branches", "--tags", "--remotes", in: worktree)
            losses.detachedCommits = Int(try await git.text(commits)) ?? 0
        } else {
            losses.branch = name
        }

        losses.stoppedPull = try await RemoteCommands.stoppedPull(in: worktree, git: git)
        losses.hasSubmodules = try await hasSubmodules(in: worktree, git: git)
        return losses
    }

    /// Says which main branch has all of a branch's commits: the local one, or
    /// else the remote one, for a branch that was merged on a host and hasn't been
    /// pulled yet. A squash or a rebase makes new commits, so a branch merged
    /// that way doesn't count, because git can't tell.
    ///
    /// A branch that has no commits yet isn't among the refs, and the main
    /// branch doesn't count as merged into itself.
    static func mainBranch(holdingAllOf branch: String, in repository: String, git: Git) async throws -> String? {
        let refs = try await RefsLoader.load(git: git, in: repository)
        guard let main = refs.mainBranch, main.name != branch, refs.refs.contains(where: { $0.name == branch }) else { return nil }
        for base in [main, refs.remoteMainBranch].compactMap(\.self) {
            let missing = GitCommand("rev-list", "--count", branch, "--not", base.name, in: repository)
            if try await git.text(missing) == "0" { return base.shortName }
        }
        return nil
    }

    /// Goes by what makes git refuse: a folder for the worktree's submodules in
    /// its git directory, or a submodule in its index that has files checked out.
    private static func hasSubmodules(in worktree: String, git: Git) async throws -> Bool {
        let modules = GitCommand("rev-parse", "--path-format=absolute", "--git-path", "modules", in: worktree)
        if FileManager.default.fileExists(atPath: try await git.text(modules)) { return true }
        let files = GitCommand("ls-files", "-z", "--format=%(objectmode) %(path)", in: worktree)
        let submodule = Array("160000 ".utf8)
        return try await git.run(files).output.split(separator: 0).contains { file in
            guard file.starts(with: submodule) else { return false }
            let path = String(decoding: file.dropFirst(submodule.count), as: UTF8.self)
            return FileManager.default.fileExists(atPath: worktree + "/" + path + "/.git")
        }
    }
}
