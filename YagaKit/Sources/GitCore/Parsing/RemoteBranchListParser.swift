/// Reads which remote branch each branch tracks, from `git for-each-ref`.
public enum RemoteBranchListParser {
    /// Leaving out how far each branch is from its upstream keeps this quick
    /// enough to run for every repository in the sidebar, so the remote branches
    /// are listed too, to see which upstreams are still there.
    public static let arguments = ["for-each-ref", "--format=%(refname)%00%(upstream)", "refs/heads", "refs/remotes"]

    /// A branch can also track another local branch, which isn't on a remote.
    ///
    /// - Returns: Each branch that tracks a remote branch this repository still
    ///   has a copy of, by their full names.
    public static func parse(_ output: [UInt8]) throws(ParseError) -> [String: String] {
        var upstreams: [String: String] = [:]
        var refs: Set<String> = []
        for line in output.split(separator: UInt8(ascii: "\n")) {
            let fields = line.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 2 else {
                throw ParseError("git for-each-ref printed a line with \(fields.count) fields instead of 2.")
            }
            let name = String(decoding: fields[0], as: UTF8.self)
            refs.insert(name)
            if name.hasPrefix(Ref.branchPrefix), !fields[1].isEmpty {
                upstreams[name] = String(decoding: fields[1], as: UTF8.self)
            }
        }
        return upstreams.filter { $0.value.hasPrefix(Ref.remoteBranchPrefix) && refs.contains($0.value) }
    }
}
