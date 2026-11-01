/// One git command: its arguments, the folder it runs in, and how yaga runs
/// it.
///
/// yaga leaves the user's git configuration alone. A command that prints
/// output whose shape depends on configuration overrides just those settings,
/// for example with `--no-color` and `--no-ext-diff` for a patch. The pager
/// never needs turning off, because git only starts one when its output is a
/// terminal, and yaga's never is.
public struct GitCommand: Sendable, Hashable, CustomStringConvertible {
    /// The arguments after `git` and yaga's own options, starting with the
    /// subcommand, as in `["log", "--format=%H"]`.
    public var arguments: [String]

    /// The absolute path of the folder git runs in, or nil for a command that
    /// doesn't need a repository, such as `git version`.
    public var directory: String?

    /// Settings passed with `-c`, which override the user's configuration for
    /// this command only.
    public var configuration: [String: String] = [:]

    /// Environment variables to set for this command, on top of the ones every
    /// command gets.
    public var environment: [String: String] = [:]

    /// Whether git may take optional locks, such as the index lock that
    /// `git status` takes to refresh the index. Background reads leave this
    /// false, so that git runs with `--no-optional-locks` and never gets in the
    /// way of the user or an agent running git at the same time.
    public var takesOptionalLocks = false

    /// The exit statuses that mean the command worked. Some commands use a
    /// status of 1 as an answer rather than a failure, such as
    /// `git merge-base --is-ancestor`.
    public var successStatuses: Set<Int32> = [0]

    public init(_ arguments: [String], in directory: String? = nil) {
        self.arguments = arguments
        self.directory = directory
    }

    public init(_ arguments: String..., in directory: String? = nil) {
        self.init(arguments, in: directory)
    }

    /// The arguments git receives, with yaga's own options first.
    public var fullArguments: [String] {
        var full: [String] = []
        if !takesOptionalLocks {
            full.append("--no-optional-locks")
        }
        for (key, value) in configuration.sorted(by: { $0.key < $1.key }) {
            full += ["-c", "\(key)=\(value)"]
        }
        return full + arguments
    }

    /// The command as someone would type it, for logs and error messages.
    public var description: String {
        (["git"] + fullArguments).map(Self.quoted).joined(separator: " ")
    }

    private static func quoted(_ argument: String) -> String {
        let plain = !argument.isEmpty && argument.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "-_./=:@%+,^~".unicodeScalars.contains($0)
        }
        if plain { return argument }
        return "'" + argument.replacing("'", with: "'\\''") + "'"
    }
}
