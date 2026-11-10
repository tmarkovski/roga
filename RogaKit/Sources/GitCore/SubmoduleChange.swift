/// What Roga knows about a submodule's row beyond the two commits it compares
/// (decision 75). In a commit, a comparison, a stash and under Staged, both are
/// commits that the parent records. Under Unstaged, the old one is the commit the
/// worktree's index records, and the new one is the commit checked out in the
/// submodule.
public struct SubmoduleChange: Sendable, Hashable {
    /// What `git status` says about a submodule's checkout. It costs nothing more
    /// to know, because git looks inside every checked-out submodule anyway.
    public struct Checkout: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// It's on another commit than the one the index records.
        public static let commitChanged = Checkout(rawValue: 1)
        /// It has changes to files it tracks.
        public static let modifiedFiles = Checkout(rawValue: 2)
        /// It has files it doesn't track.
        public static let untrackedFiles = Checkout(rawValue: 4)

        /// Whether it has uncommitted files of its own, which the parent can't
        /// stage.
        public var hasFilesInside: Bool {
            !isDisjoint(with: [.modifiedFiles, .untrackedFiles])
        }
    }

    /// How the row's two commits stand to each other, which takes reading the
    /// submodule's own repository.
    public enum Distance: Sendable, Hashable {
        /// `ahead` commits lead to the new one and not to the old one, and
        /// `behind` commits the other way around.
        case counted(ahead: Int, behind: Int)
        /// The submodule isn't checked out in the worktree, so there's nothing
        /// to read its commits from.
        case notCheckedOut
        /// The checkout doesn't have one of the commits, as before it has
        /// fetched what a pull recorded.
        case commitMissing
    }

    /// What `git status` says, for a row under Unstaged, and nil for every other
    /// row, whose two commits are both recorded.
    public var checkout: Checkout?
    /// How the two commits stand, or nil until the submodule has been read.
    public var distance: Distance?
    /// How many uncommitted files the checkout has, or nil until they've been
    /// counted. Only a row under Unstaged has them.
    public var filesInside: Int?

    public init(checkout: Checkout? = nil, distance: Distance? = nil, filesInside: Int? = nil) {
        self.checkout = checkout
        self.distance = distance
        self.filesInside = filesInside
    }
}

/// What staging a submodule's row under Unstaged would do, which says what the
/// panels offer for it (decision 75).
public enum SubmoduleStaging: Sendable, Hashable {
    /// The checkout has commits the index doesn't record, and staging records
    /// them.
    case recordsNewCommits
    /// The checkout is missing commits the index records, so staging would take
    /// them away. Updating the checkout is what's wanted, unless someone means
    /// to go back.
    case takesCommitsAway
    /// The checkout has commits of its own and is missing some too, so staging
    /// takes some away and updating leaves the others.
    case takesSomeAndAddsSome
    /// The checkout is on the recorded commit, with files of its own changed,
    /// which belong to the submodule's own commits.
    case nothingToStage
    /// The submodule hasn't been read yet, so nobody knows.
    case unknown

    /// Whether staging everything leaves the row out, because doing it without
    /// looking is how a branch loses an update someone else made.
    public var isLeftOutOfStagingAll: Bool {
        switch self {
        case .takesCommitsAway, .takesSomeAndAddsSome, .unknown: true
        case .recordsNewCommits, .nothingToStage: false
        }
    }
}

extension DiffFile {
    /// What staging this row would do, when it's a submodule under Unstaged
    /// that's checked out, and nil for every other row, which stages as any file
    /// does. A submodule whose folder is gone is one of those, because staging
    /// it records that it was removed.
    public var submoduleStaging: SubmoduleStaging? {
        guard oldMode == Self.submoduleMode, newMode == Self.submoduleMode, let checkout = submodule?.checkout else { return nil }
        guard checkout.contains(.commitChanged) else { return .nothingToStage }
        switch submodule?.distance {
        case nil:
            return .unknown
        case .counted(_, let behind) where behind == 0:
            return .recordsNewCommits
        case .counted(let ahead, _):
            return ahead == 0 ? .takesCommitsAway : .takesSomeAndAddsSome
        case .commitMissing:
            // Nothing can count them, and it's nearly always a checkout that
            // hasn't fetched the commit a pull recorded.
            return .takesCommitsAway
        case .notCheckedOut:
            return .unknown
        }
    }
}

/// What the diff panel shows of a submodule's row: the commits between the two
/// it compares, read from the copy checked out in a worktree (decision 75).
public struct SubmoduleDetails: Sendable, Hashable {
    /// One of the submodule's own commits.
    public struct Commit: Sendable, Hashable, Identifiable {
        public var id: ObjectID
        public var subject: String
        public var author: String
        /// When it was written, in seconds since 1970.
        public var time: Int64

        public init(id: ObjectID, subject: String, author: String, time: Int64) {
            self.id = id
            self.subject = subject
            self.author = author
            self.time = time
        }
    }

    /// One of the checkout's uncommitted files, by its path in the submodule.
    public struct File: Sendable, Hashable {
        public var status: DiffFile.Status
        public var path: String

        public init(status: DiffFile.Status, path: String) {
            self.status = status
            self.path = path
        }
    }

    /// The commit on the old side, or nil when the submodule wasn't there.
    public var from: ObjectID?
    /// The commit on the new side, or nil when the submodule isn't there.
    public var to: ObjectID?
    /// Whether `to` is the commit checked out rather than one that's recorded,
    /// which it is for a row under Unstaged.
    public var comparesCheckout: Bool
    public var distance: SubmoduleChange.Distance
    /// The commits that lead to `to` and not to `from`, newest first, up to as
    /// many as were asked for.
    public var added: [Commit]
    /// The commits that lead to `from` and not to `to`, newest first.
    public var removed: [Commit]
    /// The checkout's uncommitted files, which only a row under Unstaged has.
    public var filesInside: [File]
    /// How many of the commits that lead to `to` and not to `from` aren't on
    /// any of the submodule's remote branches, or nil when nobody looked,
    /// because the commits are in history already or there are none.
    public var unpushed: Int?

    public init(
        from: ObjectID?,
        to: ObjectID?,
        comparesCheckout: Bool,
        distance: SubmoduleChange.Distance,
        added: [Commit] = [],
        removed: [Commit] = [],
        filesInside: [File] = [],
        unpushed: Int? = nil
    ) {
        self.from = from
        self.to = to
        self.comparesCheckout = comparesCheckout
        self.distance = distance
        self.added = added
        self.removed = removed
        self.filesInside = filesInside
        self.unpushed = unpushed
    }

    /// What a row says of the same submodule, so that the panel and the row
    /// can't disagree.
    public func change(checkout: SubmoduleChange.Checkout?) -> SubmoduleChange {
        let hasFiles = comparesCheckout && checkout?.hasFilesInside == true
        return SubmoduleChange(checkout: checkout, distance: distance, filesInside: hasFiles ? filesInside.count : nil)
    }
}
