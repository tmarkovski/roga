import Foundation
import GitCore
import GitRunner

/// What deleting a linked worktree would come to, which says whether to ask first.
public struct WorktreeDeletion: Sendable, Hashable {
    /// How much goes with the worktree's folder.
    public enum Scope: Sendable, Hashable, CaseIterable {
        /// Only the folder. The commits stay on the branch.
        case worktree
        /// Everything local: the folder and its branch. A remote branch stays,
        /// because it may be on its way to being a pull request.
        case worktreeAndBranch
        /// Those, and the branch on its remote.
        case everything
    }

    /// Where a deletion stopped, once the worktree was gone. That step and any
    /// after it didn't happen.
    public struct Stopped: Error, Sendable, Hashable {
        public enum Step: Sendable, Hashable {
            case branch
            case remoteBranch
        }

        public var step: Step
        /// What git said.
        public var message: String

        public init(at step: Step, message: String) {
            self.step = step
            self.message = message
        }
    }

    /// The worktree's folder.
    public var worktree: String
    /// Whether git will refuse whatever anyone answers: a locked worktree, which
    /// `--force` doesn't get past, or the main worktree.
    public var isRefused: Bool
    /// Deleting the worktree's branch, unless it stays.
    public var branch: BranchDeletion?
    /// Deleting the branch from its remote, unless it stays.
    public var remoteBranch: BranchDeletion?
    /// The short name of the branch or remote branch that's worth saying stays.
    public var staying: String?
    /// How many files have uncommitted changes, which git can't bring back.
    public var uncommittedFiles: Int
    /// How many files and folders git ignores, which go with the folder.
    public var ignoredCount: Int
    /// The first of them.
    public var ignored: [String]
    /// How many commits nothing else leads to once this is done.
    public var lostCount: Int
    /// The newest of those commits.
    public var lost: [ObjectID]

    /// Whether someone should agree to this first. Deleting from a remote affects
    /// everyone who uses it, and anything else is only worth asking about when
    /// something can't be brought back. That includes ignored files, which can be
    /// real data rather than build products. A deletion that git will refuse needs
    /// no question.
    public var asksFirst: Bool {
        if isRefused { return false }
        if case .remote = remoteBranch?.place { return true }
        return lostCount > 0 || uncommittedFiles > 0 || ignoredCount > 0
    }

    /// What removes the worktree. A single `--force` is only for uncommitted files,
    /// so git still refuses a locked worktree.
    public var removeArguments: [String] {
        ["worktree", "remove"] + (uncommittedFiles > 0 ? ["--force"] : []) + [worktree]
    }

    /// Everything it runs, in order, which the alert shows.
    public var commands: [[String]] {
        [removeArguments] + [branch, remoteBranch].compactMap { $0?.arguments }
    }

    /// Finds out what deleting a worktree would come to.
    ///
    /// - Parameters:
    ///   - path: The worktree's folder.
    ///   - scope: How much goes with it.
    ///   - limit: The most commits and ignored files to list.
    ///   - directory: The repository's git directory, which lasts longer than the
    ///     worktree.
    static func prepare(
        worktree path: String,
        scope: Scope,
        limit: Int,
        in directory: String,
        worktrees: [Worktree],
        git: Git
    ) async throws -> WorktreeDeletion {
        // A worktree that's no longer listed gets git's own answer.
        let worktree = worktrees.first { $0.path == path } ?? Worktree(path: path)
        // A branch without commits yet has nothing for `git branch -D` to delete.
        let branch = worktree.head == nil ? nil : worktree.branch
        var remoteBranch: String?
        if scope != .worktree, let branch { remoteBranch = try await remoteBranches(in: directory, git: git)[branch] }

        var changes = WorktreeChanges()
        if FileManager.default.fileExists(atPath: path) {
            changes = try await contents(of: path, git: git)
        }

        var leaving: [String] = []
        if scope != .worktree, let branch { leaving.append(branch) }
        if scope == .everything, let remoteBranch { leaving.append(remoteBranch) }
        // `--all` would count this worktree's own `HEAD`, which is going, so this
        // lists the refs and the other worktrees' `HEAD`s instead.
        let lost = try await LostCommits.find(
            from: (worktree.head.map { [$0.hex] } ?? []) + (scope == .everything ? [remoteBranch].compactMap(\.self) : []),
            leaving: leaving.isEmpty ? [] : try await LostCommits.leaving(leaving, in: directory, git: git),
            keeping: ["--glob=refs/*"] + worktrees.filter { $0.path != path }.compactMap { $0.head?.hex },
            limit: limit,
            in: directory,
            git: git
        )

        var staying: String?
        switch scope {
        case .worktree: staying = branch
        case .worktreeAndBranch: staying = remoteBranch
        case .everything: staying = nil
        }
        return WorktreeDeletion(
            worktree: path,
            isRefused: worktree.isLocked || worktree.isMain,
            branch: try await deletion(of: scope == .worktree ? nil : branch, in: directory, git: git),
            remoteBranch: try await deletion(of: scope == .everything ? remoteBranch : nil, in: directory, git: git),
            staying: staying.map(Ref.shortName),
            uncommittedFiles: changes.fileCount,
            ignoredCount: changes.ignored.count,
            ignored: Array(changes.ignored.prefix(limit)),
            lostCount: lost.count,
            lost: lost.newest
        )
    }

    /// Lists the remote branch each branch tracks, by their full names.
    static func remoteBranches(in directory: String, git: Git) async throws -> [String: String] {
        let command = GitCommand(RemoteBranchListParser.arguments, in: directory)
        do {
            return try RemoteBranchListParser.parse(try await git.run(command).output)
        } catch let error as ParseError {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
    }

    /// The step for a branch or remote branch. The commits were counted for the
    /// whole deletion, so there's nothing for this to say about them.
    private static func deletion(of name: String?, in directory: String, git: Git) async throws -> BranchDeletion? {
        guard let name else { return nil }
        return BranchDeletion(ref: name, place: try await BranchDeletion.place(of: name, in: directory, git: git), isCheckedOut: false, lostCount: 0, lost: [])
    }

    /// Lists what's in a worktree that git can't bring back. `--ignore-submodules`
    /// matches what `git worktree remove` checks, `--untracked-files=all` counts
    /// untracked files even for someone who turned them off, and `matching` lists
    /// an ignored folder without going through what's in it.
    private static func contents(of worktree: String, git: Git) async throws -> WorktreeChanges {
        let command = GitCommand(
            StatusParser.arguments + ["--untracked-files=all", "--ignored=matching", "--ignore-submodules=none"],
            in: worktree
        )
        do {
            return try StatusParser.parse(try await git.run(command).output)
        } catch let error as ParseError {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
    }
}
