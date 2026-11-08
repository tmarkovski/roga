import Foundation

/// A git command an agent suggested, and whether Roga will offer to run it
/// (decision 63). This check is what stands between a model's words and git, and
/// what the model was sent can come from the repository, so it doesn't count on
/// the model having followed its instructions.
public struct ProposedGitCommand: Sendable, Hashable {
    /// The arguments after `git`, starting with the subcommand.
    public var arguments: [String]
    /// Why Roga won't run it, as the end of a sentence that starts "Roga won't run
    /// this, because", or nil when it can.
    public var refusal: String?

    public init(arguments: [String]) {
        self.arguments = arguments
        refusal = Self.refusal(of: arguments)
    }

    /// The subcommands that repair things, with the letters of their short options
    /// that open an editor, ask questions or name another program. Only built-in
    /// commands are here, and git won't let an alias replace one of those.
    static let subcommands: [String: Set<Character>] = [
        "add": ["e", "i", "p"],
        "am": ["i"],
        "branch": [],
        "checkout": ["p"],
        "cherry-pick": ["e"],
        "clean": ["i"],
        "fetch": [],
        "fsck": [],
        "gc": [],
        "merge": ["e", "s"],
        "mv": [],
        "prune": [],
        "pull": ["e", "s"],
        "rebase": ["i", "s", "x"],
        "remote": [],
        "reset": ["p"],
        "restore": ["p"],
        "revert": ["e"],
        "rm": [],
        "stash": ["p"],
        "submodule": [],
        "switch": [],
        "symbolic-ref": [],
        "tag": ["e"],
        "update-index": [],
        "update-ref": [],
        "worktree": [],
    ]

    /// The subcommands that are only safe with some verbs. `submodule foreach` is
    /// the reason, since it runs whatever it's given.
    static let verbs: [String: Set<String>] = [
        "remote": ["prune"],
        "submodule": ["absorbgitdirs", "deinit", "init", "sync", "update"],
        "worktree": ["prune", "remove", "repair", "unlock"],
    ]

    /// Long options that start another program, open an editor, ask questions or
    /// point git somewhere else, under any subcommand.
    static let refusedOptions: Set<String> = [
        "--config", "--config-env", "--edit", "--edit-description", "--exec", "--exec-path", "--ext-diff", "--git-dir", "--interactive",
        "--multiple", "--namespace", "--patch", "--receive-pack", "--separate-git-dir", "--strategy", "--template",
        "--textconv", "--upload-pack", "--work-tree",
    ]

    /// Why Roga won't run a command, or nil when it can.
    static func refusal(of arguments: [String]) -> String? {
        guard let subcommand = arguments.first, !subcommand.isEmpty else {
            return "it's empty"
        }
        if subcommand.hasPrefix("-") {
            return "an option before the subcommand can point git at another repository or program"
        }
        guard let shortOptions = subcommands[subcommand] else {
            return "git \(subcommand) isn't one of the commands Roga can check"
        }
        if arguments.contains(where: { $0.contains("\0") || $0.contains("\n") }) {
            return "an argument has a line break in it"
        }

        let rest = arguments.dropFirst()
        // Everything after `--` is a path, whatever it looks like.
        let options = rest.prefix { $0 != "--" }
        let positionals = options.filter { !$0.hasPrefix("-") }
        if let allowed = verbs[subcommand] {
            guard let verb = positionals.first, allowed.contains(verb) else {
                return "Roga can only run git \(subcommand) with \(allowed.sorted().joined(separator: ", "))"
            }
        }
        for option in options where option.hasPrefix("-") {
            if option.hasPrefix("--") {
                let name = String(option.prefix { $0 != "=" })
                // git takes a long option cut short when that's unambiguous.
                if name.count > 2, refusedOptions.contains(where: { $0.hasPrefix(name) }) {
                    return "\(name) can start another program, open an editor or point git somewhere else"
                }
            } else if let letter = option.dropFirst().first(where: shortOptions.contains) {
                return "-\(letter) means git \(subcommand) would start another program or wait for someone"
            }
        }
        if subcommand == "fetch" || subcommand == "pull" {
            if let address = positionals.first(where: { $0.contains("://") || $0.contains("::") }) ?? positionals.first.flatMap({ $0.contains(":") ? $0 : nil }) {
                return "\(address) isn't the name of a remote"
            }
        }
        return nil
    }

    /// Whether this is known to lose nothing that git can't bring back. A command
    /// that isn't known to is assumed to, so anything not named here counts.
    public var keepsEverything: Bool {
        guard refusal == nil, let subcommand = arguments.first else { return false }
        let options = Set(arguments.dropFirst().prefix { $0 != "--" })
        switch subcommand {
        case "add", "fetch", "fsck", "update-index":
            return true
        case "rm":
            return options.contains("--cached")
        case "reset":
            return options.isDisjoint(with: ["--hard", "--merge", "--keep"])
        case "restore":
            return !options.isDisjoint(with: ["--staged", "-S"]) && options.isDisjoint(with: ["--worktree", "-W"])
        case "stash":
            return arguments.count == 1 || arguments[1] == "push"
        case "submodule":
            return arguments.dropFirst().contains("sync")
        case "worktree":
            return !options.isDisjoint(with: ["prune", "repair"])
        default:
            return false
        }
    }
}
