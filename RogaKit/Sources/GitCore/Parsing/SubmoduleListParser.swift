/// Reads which submodules a worktree records, from `git ls-files`.
public enum SubmoduleListParser {
    /// There's no command that lists only submodules without starting a shell, so
    /// this lists every file and keeps the submodules.
    public static let arguments = ["ls-files", "--stage", "-z"]

    /// The mode that means a submodule, and the space after it.
    private static let submoduleMode = Array("160000 ".utf8)

    /// A submodule in the middle of a conflict has a line for each side, and counts
    /// once.
    ///
    /// - Returns: The submodules' paths, in the order git lists them, whether or
    ///   not they're checked out.
    public static func parse(_ output: [UInt8]) throws(ParseError) -> [String] {
        var paths: [String] = []
        for entry in output.split(separator: 0) where entry.starts(with: submoduleMode) {
            guard let tab = entry.firstIndex(of: UInt8(ascii: "\t")) else {
                throw ParseError("git ls-files printed a submodule without a path.")
            }
            let path = String(decoding: entry[entry.index(after: tab)...], as: UTF8.self)
            if paths.last != path { paths.append(path) }
        }
        return paths
    }
}
