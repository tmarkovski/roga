import GitCore
import GitRunner

/// What a stash holds, read from the commits git keeps for it (decision 56). The
/// stash's commit has the worktree's tracked files as they were, and its parents are
/// the commit `HEAD` was on, a commit of the index, and a commit of the untracked
/// files when the stash kept them. So each part is what changed from one of those
/// commits to another.
public struct StashContents: Sendable, Equatable {
    /// One part of a stash, under the heading uncommitted changes would have.
    public struct Part: Sendable, Equatable {
        public var group: WorktreeChanges.Group
        public var files: [DiffFile]
        /// Where the files' patches come from.
        public var source: PatchSource

        public init(group: WorktreeChanges.Group, files: [DiffFile], source: PatchSource) {
            self.group = group
            self.files = files
            self.source = source
        }
    }

    /// The commit `HEAD` was on when the stash was made.
    public var base: ObjectID
    /// Staged, Unstaged and Untracked, in that order, leaving out the ones with
    /// no files.
    public var parts: [Part]

    public init(base: ObjectID, parts: [Part]) {
        self.base = base
        self.parts = parts
    }

    /// How many files the parts list, which counts a file once for each part
    /// it's in.
    public var fileCount: Int {
        parts.reduce(0) { $0 + $1.files.count }
    }

    /// Reads the parts of the stash whose commit is `stash`.
    ///
    /// - Parameter parents: The stash commit's parents.
    /// - Throws: `RepositoryError.notAStash` when the commit doesn't have the
    ///   parents a stash has.
    static func load(stash: ObjectID, parents: [ObjectID], format: ObjectFormat, git: Git, directory: String) async throws -> StashContents {
        guard parents.count >= 2 else { throw RepositoryError.notAStash(stash) }
        let base = parents[0]
        let index = parents[1]
        let untracked = parents.count > 2 ? parents[2] : nil
        let stagedSource = PatchSource.commits(from: base, to: index, group: .staged)
        let unstagedSource = PatchSource.commits(from: index, to: stash, group: .unstaged)
        async let staged = DiffLoader.changedFiles(from: base, to: index, format: format, git: git, directory: directory)
        async let unstaged = DiffLoader.changedFiles(from: index, to: stash, format: format, git: git, directory: directory)
        // The untracked files' commit has no parent, so all of its files are new.
        var untrackedPart: Part?
        if let untracked {
            let files = try await DiffLoader.changedFiles(from: nil, to: untracked, format: format, git: git, directory: directory)
            untrackedPart = Part(group: .untracked, files: files, source: .commits(from: nil, to: untracked, group: .untracked))
        }
        let parts = [
            Part(group: .staged, files: try await staged, source: stagedSource),
            Part(group: .unstaged, files: try await unstaged, source: unstagedSource),
            untrackedPart,
        ]
        return StashContents(base: base, parts: parts.compactMap(\.self).filter { !$0.files.isEmpty })
    }
}

/// A branch's own commits, compared with the branches it'll go into (decision 56):
/// everything from where it left them to its tip, as one diff.
public struct BranchReview: Sendable, Equatable {
    /// The branch's full name.
    public var branch: String
    /// The commit the branch points to.
    public var tip: ObjectID
    /// Where the branch left the ones it's compared with, which is their merge base,
    /// or nil when they have no commit in common.
    public var base: ObjectID?
    /// The commits the branch has that the others don't, from the newest, up to
    /// the limit it was read with.
    public var commits: [ObjectID]
    /// Whether the branch has more commits than that.
    public var hasMore: Bool

    public init(branch: String, tip: ObjectID, base: ObjectID?, commits: [ObjectID], hasMore: Bool = false) {
        self.branch = branch
        self.tip = tip
        self.base = base
        self.commits = commits
        self.hasMore = hasMore
    }

    /// Reads a branch's commits since it left the others, by their full names. With
    /// more than one, such as `main` and `origin/main`, the base is the latest commit
    /// any of them shares with the branch, which is what `git merge-base` gives for
    /// one commit and a merge of the others.
    ///
    /// - Parameter limit: The most commits to list.
    /// - Throws: `RepositoryError.noSuchRef` when the branch isn't there any more.
    static func load(branch: String, against others: [String], limit: Int, git: Git, directory: String) async throws -> BranchReview {
        var resolve = GitCommand(["rev-parse", "--verify", "--quiet", branch + "^{commit}"], in: directory)
        resolve.successStatuses = [0, 1]
        guard let tip = ObjectID(hex: try await git.text(resolve)) else { throw RepositoryError.noSuchRef(branch) }
        guard !others.isEmpty else { return BranchReview(branch: branch, tip: tip, base: nil, commits: []) }

        // It exits with 1 when there's no commit in common.
        var mergeBase = GitCommand(["merge-base", tip.hex] + others, in: directory)
        mergeBase.successStatuses = [0, 1]
        async let base = git.text(mergeBase)
        let list = GitCommand(["rev-list", "--max-count=\(limit + 1)", tip.hex, "--not"] + others, in: directory)
        let commits = try await git.text(list).split(separator: "\n").compactMap { ObjectID(hex: String($0)) }
        return BranchReview(
            branch: branch,
            tip: tip,
            base: ObjectID(hex: try await base),
            commits: Array(commits.prefix(limit)),
            hasMore: commits.count > limit
        )
    }
}
