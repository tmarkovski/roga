/// How far a worktree's branch is from the main branch on the remote, as in
/// `4 ahead, 12 behind origin/main`, which the branch row says under the
/// branch's name (decision 118).
///
/// It compares with the remote's branch rather than the local `main`, which
/// goes stale unless someone pulls it, while the fetches Roga makes by itself
/// keep the remote's current.
public struct MainDistance: Sendable, Hashable {
    /// The full name of the branch it's compared with, as in
    /// `refs/remotes/origin/main`.
    public var base: String
    /// The commit `base` was on.
    public var baseCommit: ObjectID
    /// The commit `HEAD` was on.
    public var head: ObjectID
    /// How many commits the branch has that `base` doesn't.
    public var ahead: Int
    /// How many commits `base` has that the branch doesn't.
    public var behind: Int
    /// The files that merging `base` into the branch would conflict in, by
    /// their paths. It's empty when the merge would go cleanly or there's
    /// nothing to merge, and nil when git couldn't say, as in a partial clone
    /// that hasn't got the files' contents.
    public var conflicts: [String]?

    public init(base: String, baseCommit: ObjectID, head: ObjectID, ahead: Int = 0, behind: Int = 0, conflicts: [String]? = []) {
        self.base = base
        self.baseCommit = baseCommit
        self.head = head
        self.ahead = ahead
        self.behind = behind
        self.conflicts = conflicts
    }

    /// The short name of `base`, as in `origin/main`.
    public var baseName: String { Ref.shortName(base) }

    /// Whether a merge of `base` would have to combine the two, which is the
    /// only time it can conflict. Otherwise it would fast-forward, or there's
    /// nothing to bring in.
    public var hasDiverged: Bool { ahead > 0 && behind > 0 }
}

/// Reads what finding the main branch on the remote takes, for `MainDistance`.
public enum MainBranchParser {
    /// What `git for-each-ref` should list: every remote's `HEAD`, which names
    /// that remote's main branch, and a local `main` or `master` for a
    /// repository whose remotes don't have one. `*` matches across slashes in
    /// these patterns.
    public static let patterns = ["refs/remotes/*/HEAD", Ref.branchPrefix + "main", Ref.branchPrefix + "master"]

    /// The format to pass to `git for-each-ref --format`, whose fields are
    /// separated by NUL bytes: the name, what it points to when it's a
    /// symbolic ref, and its upstream.
    public static let format = "%(refname)%00%(symref)%00%(upstream)"

    /// The branch on a remote to compare with, and the local branch that is
    /// the main branch, which has nothing of its own to compare.
    public struct Main: Sendable, Hashable {
        /// The full name of the branch to compare with, as in
        /// `refs/remotes/origin/main`.
        public var base: String
        /// The full name of the local branch it stands for, as in
        /// `refs/heads/main`, whether or not there is one.
        public var local: String
    }

    /// Finds the main branch, as `RefList.mainBranch` does: the branch a
    /// remote's `HEAD` names, preferring origin's. Without a remote's `HEAD`,
    /// it's a local `main` or `master`, compared through its upstream when it
    /// has one, and as it is when it hasn't.
    ///
    /// - Returns: The main branch, or nil when there's none.
    public static func parse(_ output: [UInt8]) throws(ParseError) -> Main? {
        var remoteHeads: [(name: String, target: String)] = []
        var locals: [String: String] = [:]
        for line in output.split(separator: UInt8(ascii: "\n")) {
            let fields = line.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count == 3 else {
                throw ParseError("git for-each-ref printed a line with \(fields.count) fields instead of 3.")
            }
            if fields[0].hasPrefix(Ref.remoteBranchPrefix), fields[0].hasSuffix("/HEAD"), !fields[1].isEmpty {
                remoteHeads.append((fields[0], fields[1]))
            } else if fields[0].hasPrefix(Ref.branchPrefix) {
                locals[fields[0]] = fields[2]
            }
        }
        let origin = Ref.remoteBranchPrefix + "origin/HEAD"
        if let head = remoteHeads.first(where: { $0.name == origin }) ?? remoteHeads.first {
            let folder = head.name.dropLast("HEAD".count)
            guard head.target.hasPrefix(folder) else { return nil }
            return Main(base: head.target, local: Ref.branchPrefix + head.target.dropFirst(folder.count))
        }
        for name in [Ref.branchPrefix + "main", Ref.branchPrefix + "master"] {
            if let upstream = locals[name] {
                return Main(base: upstream.isEmpty ? name : upstream, local: name)
            }
        }
        return nil
    }
}

/// Reads what `git merge-tree --write-tree --name-only -z --no-messages` says
/// about a merge it tried without touching the worktree or the index.
public enum MergeTreeParser {
    /// - Parameter output: What git printed: the tree the merge would make,
    ///   then each file that would conflict, once, each ended by a NUL byte.
    /// - Returns: The files that would conflict, in the order git listed them.
    public static func conflicts(in output: [UInt8]) throws(ParseError) -> [String] {
        let fields = output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard let tree = fields.first, ObjectID(hex: tree) != nil else {
            throw ParseError("git merge-tree didn't start with the tree the merge would make.")
        }
        return Array(fields.dropFirst())
    }
}
