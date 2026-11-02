/// Reads the local branches that `git for-each-ref refs/heads/` lists.
public enum BranchListParser {
    /// A branch, and the counts that say how far it is from other branches.
    public struct Entry: Sendable, Hashable {
        public var name: String
        public var tip: ObjectID
        public var date: Int64?
        /// The full name of its upstream, unless it has none or that's gone.
        public var upstream: String?
        /// How far it is from its upstream, if it has one.
        public var upstreamCounts: Counts?
        /// How far it is from the commit that the format asked about.
        public var baseCounts: Counts?
    }

    public struct Counts: Sendable, Hashable {
        public var ahead: Int
        public var behind: Int

        public init(ahead: Int, behind: Int) {
            self.ahead = ahead
            self.behind = behind
        }
    }

    /// The format to pass to `git for-each-ref --format`. Each branch is a
    /// line, and its fields are separated by NUL bytes: the name, the object,
    /// the date, the upstream, how far it is from the upstream, and how far it
    /// is from `base`.
    ///
    /// `base` is an object ID rather than a branch's name, because a ref name
    /// can have a parenthesis in it, which would end the field.
    public static func format(comparingWith base: ObjectID?) -> String {
        let counts = base.map { "%(ahead-behind:\($0.hex))" } ?? ""
        return "%(refname)%00%(objectname)%00%(committerdate:unix)%00%(upstream)%00%(upstream:track,nobracket)%00" + counts
    }

    public static func parse(_ output: [UInt8]) throws(ParseError) -> [Entry] {
        var entries: [Entry] = []
        for line in output.split(separator: UInt8(ascii: "\n")) {
            let fields = line.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 6 else {
                throw ParseError("git for-each-ref printed a line with \(fields.count) fields instead of 6.")
            }
            let name = String(decoding: fields[0], as: UTF8.self)
            guard let tip = ObjectID(hexDigits: fields[1]) else {
                throw ParseError("git for-each-ref printed \(name) without an object ID.")
            }
            let track = String(decoding: fields[4], as: UTF8.self)
            let hasUpstream = !fields[3].isEmpty && track != "gone"
            entries.append(Entry(
                name: name,
                tip: tip,
                date: Int64(String(decoding: fields[2], as: UTF8.self)),
                upstream: hasUpstream ? String(decoding: fields[3], as: UTF8.self) : nil,
                upstreamCounts: hasUpstream ? try counts(track: track, of: name) : nil,
                baseCounts: try counts(aheadBehind: String(decoding: fields[5], as: UTF8.self), of: name)
            ))
        }
        return entries
    }

    /// Reads `ahead 3, behind 2`, `ahead 3` or `behind 2`, or nothing when the
    /// two are the same. for-each-ref doesn't translate these.
    private static func counts(track: String, of name: String) throws(ParseError) -> Counts {
        var counts = Counts(ahead: 0, behind: 0)
        guard !track.isEmpty else { return counts }
        for part in track.split(separator: ", ") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else {
                throw ParseError("git for-each-ref printed \"\(track)\" for how far \(name) is from its upstream.")
            }
            switch words[0] {
            case "ahead": counts.ahead = count
            case "behind": counts.behind = count
            default: throw ParseError("git for-each-ref printed \"\(track)\" for how far \(name) is from its upstream.")
            }
        }
        return counts
    }

    /// Reads two numbers with a space between them, or nothing when the format
    /// didn't ask.
    private static func counts(aheadBehind text: String, of name: String) throws(ParseError) -> Counts? {
        guard !text.isEmpty else { return nil }
        let numbers = text.split(separator: " ").map { Int($0) }
        guard numbers.count == 2, let ahead = numbers[0], let behind = numbers[1] else {
            throw ParseError("git for-each-ref printed \"\(text)\" for how far \(name) is from the main branch.")
        }
        return Counts(ahead: ahead, behind: behind)
    }
}

/// Reads the remote-tracking branches and tags that
/// `git for-each-ref refs/remotes/ refs/tags/` lists.
public enum RemoteAndTagListParser {
    public struct Result: Sendable, Hashable {
        public var remoteBranches: [RemoteBranchDetails] = []
        public var tags: [TagDetails] = []
    }

    /// The format to pass to `git for-each-ref --format`. Each ref is a line,
    /// and its fields are separated by NUL bytes: the name, the object, its
    /// type, what type of object an annotated tag points to and which object
    /// that is, the date, and the target of a symbolic ref.
    ///
    /// It only asks about the objects that the refs point to, which a partial
    /// clone always has. Asking about what an annotated tag points to, as
    /// `%(*subject)` does, would make git download Linux's oldest tag's tree.
    public static let format = "%(refname)%00%(objectname)%00%(objecttype)%00%(type)%00%(object)%00%(creatordate:unix)%00%(symref)"

    public static func parse(_ output: [UInt8]) throws(ParseError) -> Result {
        var result = Result()
        for line in output.split(separator: UInt8(ascii: "\n")) {
            let fields = line.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 7 else {
                throw ParseError("git for-each-ref printed a line with \(fields.count) fields instead of 7.")
            }
            let name = String(decoding: fields[0], as: UTF8.self)
            guard let id = ObjectID(hexDigits: fields[1]) else {
                throw ParseError("git for-each-ref printed \(name) without an object ID.")
            }
            let date = Int64(String(decoding: fields[5], as: UTF8.self))
            if name.hasPrefix(Ref.remoteBranchPrefix) {
                // origin/HEAD only says which branch the remote calls its main one.
                if fields[6].isEmpty {
                    result.remoteBranches.append(RemoteBranchDetails(name: name, tip: id, date: date))
                }
            } else {
                var commit: ObjectID?
                if fields[2].elementsEqual("commit".utf8) {
                    commit = id
                } else if fields[3].elementsEqual("commit".utf8) {
                    commit = ObjectID(hexDigits: fields[4])
                }
                result.tags.append(TagDetails(name: name, commit: commit, date: date))
            }
        }
        return result
    }
}

/// Reads the remotes' URLs from `git config`.
public enum RemoteListParser {
    /// git exits with status 1 when there are no remotes.
    public static let arguments = ["config", "-z", "--get-regexp", #"^remote\..*\.url$"#]

    /// Each entry is the setting's name, a line break and its value, ending in
    /// a NUL byte. A remote with several URLs fetches from the first.
    ///
    /// - Returns: How to show each remote's address, by the remote's name.
    public static func parse(_ output: [UInt8]) throws(ParseError) -> [String: String] {
        var addresses: [String: String] = [:]
        for entry in output.split(separator: 0) {
            guard let lineBreak = entry.firstIndex(of: UInt8(ascii: "\n")) else {
                throw ParseError("git config printed a setting without a value.")
            }
            let key = String(decoding: entry[..<lineBreak], as: UTF8.self)
            guard key.hasPrefix("remote."), key.hasSuffix(".url") else {
                throw ParseError("git config printed \(key) when asked for the remotes' URLs.")
            }
            let name = String(key.dropFirst("remote.".count).dropLast(".url".count))
            if addresses[name] == nil {
                addresses[name] = RemoteAddress.shown(String(decoding: entry[entry.index(after: lineBreak)...], as: UTF8.self))
            }
        }
        return addresses
    }
}

/// Reads the stashes from `git rev-list`, which ignores the user's settings for
/// `git log`, such as showing signatures.
public enum StashListParser {
    /// Each stash is a line with its fields separated by NUL bytes: the
    /// commit, the date and the subject. The subject is the stash's message,
    /// and `%gs` would be empty, because only `git log` fills that in.
    ///
    /// git fails when there's no `refs/stash`, so look for that first.
    public static let arguments = ["rev-list", "--walk-reflogs", "--no-commit-header", "--format=%H%x00%ct%x00%s", "refs/stash"]

    public static func parse(_ output: [UInt8]) throws(ParseError) -> [StashDetails] {
        var stashes: [StashDetails] = []
        for line in output.split(separator: UInt8(ascii: "\n")) {
            let fields = line.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 3, let commit = ObjectID(hexDigits: fields[0]) else {
                throw ParseError("git rev-list printed a line that doesn't describe a stash.")
            }
            stashes.append(StashDetails(
                position: stashes.count,
                commit: commit,
                date: Int64(String(decoding: fields[1], as: UTF8.self)),
                message: String(decoding: fields[2], as: UTF8.self)
            ))
        }
        return stashes
    }
}
