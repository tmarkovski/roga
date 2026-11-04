import Foundation
import GitCore
import GitRunner

/// What deleting a linked worktree would come to, which says whether to ask first.
public struct WorktreeDeletion: Sendable, Hashable {
    /// How much goes with the worktree's folder.
    public struct Scope: Sendable, Hashable {
        /// Whether the worktree's branch goes too.
        public var deletesBranch: Bool
        /// Whether the branch it tracks goes from its remote too. The worktree's own
        /// branch can stay when this one goes.
        public var deletesRemoteBranch: Bool

        public init(deletesBranch: Bool = false, deletesRemoteBranch: Bool = false) {
            self.deletesBranch = deletesBranch
            self.deletesRemoteBranch = deletesRemoteBranch
        }

        /// Only the folder. The commits stay on the branch.
        public static let worktree = Scope()
        /// Everything local: the folder and its branch. A remote branch stays,
        /// because it may be on its way to being a pull request.
        public static let worktreeAndBranch = Scope(deletesBranch: true)
        /// Those, and the branch on its remote.
        public static let everything = Scope(deletesBranch: true, deletesRemoteBranch: true)
    }

    /// Every way there is of deleting one worktree, worked out before anything is
    /// asked, so that a dialog can say what each would come to without waiting.
    public struct Choice: Sendable, Hashable {
        /// Deleting the worktree's branch, if it has one that can go.
        public var branch: BranchDeletion?
        /// Deleting the branch it tracks from its remote, if it tracks one.
        public var remoteBranch: BranchDeletion?
        /// What's chosen to start with. It goes as far as it can without losing any
        /// commits, and it never reaches a remote.
        public var startingScope: Scope
        var deletions: [Scope: WorktreeDeletion]

        /// What a scope comes to. Something the worktree doesn't have stays out of it.
        public func deletion(for scope: Scope) -> WorktreeDeletion {
            let possible = Scope(
                deletesBranch: scope.deletesBranch && branch != nil,
                deletesRemoteBranch: scope.deletesRemoteBranch && remoteBranch != nil
            )
            // Every scope the worktree can have was worked out.
            return deletions[possible]!
        }

        /// The scope that goes furthest. Every other scope's lost commits are among
        /// this one's.
        public var widest: Scope {
            Scope(deletesBranch: branch != nil, deletesRemoteBranch: remoteBranch != nil)
        }

        /// How many commands the scope that goes furthest runs.
        public var mostCommands: Int {
            deletion(for: widest).commands.count
        }

        /// Whether someone should see this before anything happens. With something
        /// to choose, they always do. A deletion that git will refuse needs no
        /// question.
        public var asksFirst: Bool {
            if deletion(for: .worktree).isRefused { return false }
            return branch != nil || deletion(for: startingScope).asksFirst
        }
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
    /// Whether git counts the worktree as having submodules, which it only removes
    /// when forced. It can without any being checked out, because `git submodule
    /// deinit` leaves their copies in the worktree's git directory.
    public var hasSubmodules: Bool
    /// How many submodules are checked out in the worktree.
    public var submoduleCount: Int
    /// The first of them.
    public var submodules: [String]

    /// Whether someone should agree to this first. Deleting from a remote affects
    /// everyone who uses it, and anything else is only worth asking about when
    /// something can't be brought back. That includes ignored files, which can be
    /// real data rather than build products, and submodules, because forcing git
    /// also takes whatever is only in them, and nothing has looked. A deletion that
    /// git will refuse needs no question.
    public var asksFirst: Bool {
        if isRefused { return false }
        if case .remote = remoteBranch?.place { return true }
        return lostCount > 0 || uncommittedFiles > 0 || ignoredCount > 0 || hasSubmodules
    }

    /// What removes the worktree. A single `--force` gets past uncommitted files and
    /// submodules, and git still refuses a locked worktree.
    public var removeArguments: [String] {
        ["worktree", "remove"] + (uncommittedFiles > 0 || hasSubmodules ? ["--force"] : []) + [worktree]
    }

    /// Everything it runs, in order, which the dialog shows.
    public var commands: [[String]] {
        [removeArguments] + [branch, remoteBranch].compactMap { $0?.arguments }
    }

    /// Finds out what each way of deleting a worktree would come to.
    ///
    /// - Parameters:
    ///   - path: The worktree's folder.
    ///   - limit: The most commits and ignored files to list.
    ///   - directory: The repository's git directory, which lasts longer than the
    ///     worktree.
    static func prepare(
        worktree path: String,
        limit: Int,
        in directory: String,
        worktrees: [Worktree],
        git: Git
    ) async throws -> Choice {
        // A worktree that's no longer listed gets git's own answer.
        let worktree = worktrees.first { $0.path == path } ?? Worktree(path: path)
        // A branch without commits yet has nothing for `git branch -D` to delete.
        let branch = worktree.head == nil ? nil : worktree.branch
        let tracked = branch == nil ? [:] : try await remoteBranches(in: directory, git: git)
        let remoteBranch = branch.flatMap { tracked[$0] }

        // git doesn't look for changes or submodules in a folder that's gone.
        var changes = WorktreeChanges()
        var submodules = Submodules()
        if FileManager.default.fileExists(atPath: path) {
            changes = try await contents(of: path, git: git)
            submodules = try await self.submodules(of: path, git: git)
        }

        let branchDeletion = try await deletion(of: branch, in: directory, git: git)
        let remoteDeletion = try await deletion(of: remoteBranch, in: directory, git: git)
        let refs = branch == nil ? [] : try await RefsLoader.load(git: git, in: directory).refs
        let whatStays = WorktreeDeletion(
            worktree: path,
            isRefused: worktree.isLocked || worktree.isMain,
            uncommittedFiles: changes.fileCount,
            ignoredCount: changes.ignored.count,
            ignored: Array(changes.ignored.prefix(limit)),
            lostCount: 0,
            lost: [],
            hasSubmodules: submodules.hasCopies || !submodules.checkedOut.isEmpty,
            submoduleCount: submodules.checkedOut.count,
            submodules: Array(submodules.checkedOut.prefix(limit))
        )
        // `--all` would count this worktree's own `HEAD`, which is going, so this
        // lists the refs and the other worktrees' `HEAD`s instead.
        let keeping = ["--glob=refs/*"] + worktrees.filter { $0.path != path }.compactMap { $0.head?.hex }

        var scopes = [Scope.worktree]
        if branch != nil { scopes.append(.worktreeAndBranch) }
        if remoteBranch != nil { scopes += [Scope(deletesRemoteBranch: true), .everything] }
        let deletions = try await withThrowingTaskGroup(of: (Scope, WorktreeDeletion).self) { group in
            for scope in scopes {
                group.addTask {
                    var leaving: [String] = []
                    if scope.deletesBranch, let branch { leaving.append(branch) }
                    if scope.deletesRemoteBranch, let remoteBranch { leaving.append(remoteBranch) }
                    let lost = try await LostCommits.find(
                        from: (worktree.head.map { [$0.hex] } ?? []) + (scope.deletesRemoteBranch ? [remoteBranch].compactMap(\.self) : []),
                        leaving: LostCommits.leaving(leaving, among: refs),
                        keeping: keeping,
                        limit: limit,
                        in: directory,
                        git: git
                    )
                    var deletion = whatStays
                    deletion.branch = scope.deletesBranch ? branchDeletion : nil
                    deletion.remoteBranch = scope.deletesRemoteBranch ? remoteDeletion : nil
                    deletion.lostCount = lost.count
                    deletion.lost = lost.newest
                    return (scope, deletion)
                }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        return Choice(
            branch: branchDeletion,
            remoteBranch: remoteDeletion,
            startingScope: deletions[.worktreeAndBranch]?.lostCount == 0 ? .worktreeAndBranch : .worktree,
            deletions: deletions
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

    /// What makes `git worktree remove` refuse a worktree unless it's forced.
    private struct Submodules {
        /// The ones checked out in the worktree.
        var checkedOut: [String] = []
        /// Whether the worktree's git directory holds copies of any.
        var hasCopies = false
    }

    /// Looks for submodules the two ways git does, which is the folder of copies in
    /// the worktree's git directory and any checked out in the worktree. A submodule
    /// that was never checked out here is neither, so git doesn't mind it.
    private static func submodules(of worktree: String, git: Git) async throws -> Submodules {
        let list = GitCommand(SubmoduleListParser.arguments, in: worktree)
        let recorded: [String]
        do {
            recorded = try SubmoduleListParser.parse(try await git.run(list).output)
        } catch let error as ParseError {
            throw RepositoryError.unexpectedOutput(list, error.description)
        }
        let copies = try await git.text(GitCommand("rev-parse", "--path-format=absolute", "--git-path", "modules", in: worktree))
        var isFolder: ObjCBool = false
        return Submodules(
            checkedOut: recorded.filter { FileManager.default.fileExists(atPath: "\(worktree)/\($0)/.git") },
            hasCopies: FileManager.default.fileExists(atPath: copies, isDirectory: &isFolder) && isFolder.boolValue
        )
    }
}
