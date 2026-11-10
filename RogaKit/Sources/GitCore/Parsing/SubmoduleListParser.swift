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

    /// Reads the commit the index records for each submodule, by its path.
    ///
    /// A submodule in the middle of a conflict has a line for each side and none
    /// for what's settled. Its commit is then ours, which is the one `HEAD`
    /// records, and without that side, whichever comes first.
    ///
    /// - Parameter output: What `arguments` print, for every file or for some
    ///   paths. Anything that isn't a submodule is left out, as when one of the
    ///   paths is an ordinary folder.
    public static func recorded(_ output: [UInt8]) throws(ParseError) -> [String: ObjectID] {
        var commits: [String: (commit: ObjectID, stage: UInt8)] = [:]
        for entry in output.split(separator: 0) where entry.starts(with: submoduleMode) {
            let fields = entry.dropFirst(submoduleMode.count)
            guard let tab = fields.firstIndex(of: UInt8(ascii: "\t")) else {
                throw ParseError("git ls-files printed a submodule without a path.")
            }
            let parts = fields[..<tab].split(separator: UInt8(ascii: " "))
            guard parts.count == 2, let commit = ObjectID(hexDigits: parts[0]), parts[1].count == 1, let stage = parts[1].first else {
                throw ParseError("git ls-files printed a submodule without a commit.")
            }
            let path = String(decoding: entry[entry.index(after: tab)...], as: UTF8.self)
            /// Settled comes before ours, and ours before the other sides.
            func rank(_ stage: UInt8) -> Int {
                switch stage {
                case UInt8(ascii: "0"): 0
                case UInt8(ascii: "2"): 1
                default: 2
                }
            }
            if let known = commits[path], rank(known.stage) <= rank(stage) { continue }
            commits[path] = (commit, stage)
        }
        return commits.mapValues(\.commit)
    }
}

/// Reads what `.gitmodules` and git's own settings say about submodules, from
/// `git config`.
public enum SubmoduleConfigParser {
    /// What `.gitmodules` says of each submodule: its path, and the URL it's
    /// cloned from. git exits with status 1 when the file names none.
    public static let moduleArguments = ["config", "-z", "--file", ".gitmodules", "--get-regexp", #"^submodule\..*\.(path|url)$"#]

    /// The URLs in git's own settings, which is where `git submodule init`
    /// copies each one from `.gitmodules`, made whole if it was relative to the
    /// parent's remote, and where someone changes one for their own clone. git
    /// exits with status 1 when there are none.
    public static let urlArguments = ["config", "-z", "--get-regexp", #"^submodule\..*\.url$"#]

    /// What's set for one submodule.
    public struct Module: Sendable, Hashable {
        public var path: String?
        public var url: String?

        public init(path: String? = nil, url: String? = nil) {
            self.path = path
            self.url = url
        }
    }

    /// Each entry is the setting's name, a line break and its value, ending in
    /// a NUL byte. A submodule's name can have dots in it, so it's what's
    /// between `submodule.` and the last dot. A setting given twice keeps its
    /// last value, as git does.
    ///
    /// - Returns: What's set for each submodule, by its name.
    public static func parse(_ output: [UInt8]) throws(ParseError) -> [String: Module] {
        var modules: [String: Module] = [:]
        for entry in output.split(separator: 0) {
            // A setting with no value at all has no line break, and says nothing.
            guard let lineBreak = entry.firstIndex(of: UInt8(ascii: "\n")) else { continue }
            let key = String(decoding: entry[..<lineBreak], as: UTF8.self)
            let value = String(decoding: entry[entry.index(after: lineBreak)...], as: UTF8.self)
            guard key.hasPrefix("submodule."), let dot = key.lastIndex(of: "."), dot >= key.index(key.startIndex, offsetBy: "submodule.".count) else {
                throw ParseError("git config printed \(key) when asked for the submodules.")
            }
            let name = String(key[key.index(key.startIndex, offsetBy: "submodule.".count)..<dot])
            switch key[key.index(after: dot)...] {
            case "path": modules[name, default: Module()].path = value
            case "url": modules[name, default: Module()].url = value
            default: throw ParseError("git config printed \(key) when asked for the submodules.")
            }
        }
        return modules
    }
}
