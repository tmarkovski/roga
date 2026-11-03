/// Reads what `git for-each-ref` says about one branch, for `BranchStatus`.
public enum BranchStatusParser {
    public struct Entry: Sendable, Hashable {
        public var upstream: String?
        public var upstreamIsGone: Bool
        public var counts: BranchListParser.Counts
        /// The remote that `branch.<name>.remote` names, or nil when it has none.
        public var trackedRemote: String?
        /// The remote git would push it to, which git says is `origin` when
        /// nothing else does, even if there's no such remote.
        public var pushRemote: String?
    }

    /// The format to pass to `git for-each-ref --format`, whose fields are
    /// separated by NUL bytes: the name, the upstream, how far it is from the
    /// upstream, the remote it tracks, and the remote it pushes to.
    public static let format = "%(refname)%00%(upstream)%00%(upstream:track,nobracket)%00%(upstream:remotename)%00%(push:remotename)"

    /// Finds a branch in what git printed. It's nil when git printed nothing
    /// about it, as for a branch without commits yet.
    public static func parse(_ output: [UInt8], branch: String) throws(ParseError) -> Entry? {
        for line in output.split(separator: UInt8(ascii: "\n")) {
            let fields = line.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 5 else {
                throw ParseError("git for-each-ref printed a line with \(fields.count) fields instead of 5.")
            }
            guard String(decoding: fields[0], as: UTF8.self) == branch else { continue }
            let upstream = String(decoding: fields[1], as: UTF8.self)
            let track = String(decoding: fields[2], as: UTF8.self)
            let isGone = track == "gone"
            let hasUpstream = !upstream.isEmpty && !isGone
            return Entry(
                upstream: hasUpstream ? upstream : nil,
                upstreamIsGone: isGone,
                counts: hasUpstream ? try BranchListParser.counts(track: track, of: branch) : BranchListParser.Counts(ahead: 0, behind: 0),
                trackedRemote: fields[3].isEmpty ? nil : String(decoding: fields[3], as: UTF8.self),
                pushRemote: fields[4].isEmpty ? nil : String(decoding: fields[4], as: UTF8.self)
            )
        }
        return nil
    }
}
