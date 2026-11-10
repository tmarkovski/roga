/// How a branch stands against the commit `HEAD` is on, and against the branch it
/// tracks, which says what a menu can offer for it without running git.
public struct RefRelation: Sendable, Hashable {
    /// The branch this one tracks, when it still exists.
    public struct Upstream: Sendable, Hashable {
        /// Its full name.
        public var name: String
        /// How many commits the branch has that it doesn't.
        public var ahead: Int
        /// How many commits it has that the branch doesn't.
        public var behind: Int
        /// The remote it's on, or nil when git can't say.
        public var remote: String?
        /// What it's called on its remote, without `refs/heads/`, or nil when git
        /// can't say.
        public var branchOnRemote: String?

        public init(name: String, ahead: Int = 0, behind: Int = 0, remote: String? = nil, branchOnRemote: String? = nil) {
            self.name = name
            self.ahead = ahead
            self.behind = behind
            self.remote = remote
            self.branchOnRemote = branchOnRemote
        }
    }

    /// How many commits it has that `HEAD` doesn't.
    public var ahead: Int
    /// How many commits `HEAD` has that it doesn't.
    public var behind: Int
    public var upstream: Upstream?
    /// The remote git's settings send this branch's pushes to, when they say.
    public var pushRemote: String?

    public init(ahead: Int, behind: Int, upstream: Upstream? = nil, pushRemote: String? = nil) {
        self.ahead = ahead
        self.behind = behind
        self.upstream = upstream
        self.pushRemote = pushRemote
    }

    /// The remote the branch pushes to and pulls from: the one it tracks, or,
    /// before it has been pushed, the one its first push will go to.
    public var remote: String? {
        upstream?.remote ?? pushRemote
    }
}

/// Reads how every branch and remote branch stands against `HEAD`, from
/// `git for-each-ref`.
public enum RefRelationParser {
    /// The format to pass to `git for-each-ref --format`. Each ref is a line, and
    /// its fields are separated by NUL bytes.
    ///
    /// `head` is an object ID, because that's what stays true for as long as the
    /// answer is used, which a name like `HEAD` wouldn't say.
    public static func format(comparingWith head: ObjectID) -> String {
        "%(refname)%00%(ahead-behind:\(head.hex))%00%(upstream)%00%(upstream:track,nobracket)%00%(upstream:remotename)%00%(upstream:remoteref)%00%(push:remotename)"
    }

    /// - Returns: Each ref's relation, by its full name.
    public static func parse(_ output: [UInt8]) throws(ParseError) -> [String: RefRelation] {
        var relations: [String: RefRelation] = [:]
        for line in output.split(separator: UInt8(ascii: "\n")) {
            let fields = line.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 7 else {
                throw ParseError("git for-each-ref printed a line with \(fields.count) fields instead of 7.")
            }
            let name = String(decoding: fields[0], as: UTF8.self)
            let numbers = String(decoding: fields[1], as: UTF8.self).split(separator: " ").map { Int($0) }
            guard numbers.count == 2, let ahead = numbers[0], let behind = numbers[1] else {
                throw ParseError("git for-each-ref printed something other than two numbers for how far \(name) is from HEAD.")
            }
            let track = String(decoding: fields[3], as: UTF8.self)
            var upstream: RefRelation.Upstream?
            if !fields[2].isEmpty, track != "gone" {
                let counts = try BranchListParser.counts(track: track, of: name)
                let remote = String(decoding: fields[4], as: UTF8.self)
                let onRemote = String(decoding: fields[5], as: UTF8.self)
                upstream = RefRelation.Upstream(
                    name: String(decoding: fields[2], as: UTF8.self),
                    ahead: counts.ahead,
                    behind: counts.behind,
                    remote: remote.isEmpty ? nil : remote,
                    branchOnRemote: onRemote.isEmpty ? nil : Ref.shortName(onRemote)
                )
            }
            let pushRemote = String(decoding: fields[6], as: UTF8.self)
            relations[name] = RefRelation(ahead: ahead, behind: behind, upstream: upstream, pushRemote: pushRemote.isEmpty ? nil : pushRemote)
        }
        return relations
    }
}
