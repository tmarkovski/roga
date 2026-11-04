import GitCore
import GitRunner

/// Loads what's uncommitted in a worktree, without changing anything.
///
/// Every command here runs with `--no-optional-locks`, as `GitCommand` does by
/// default, so git doesn't write what it learns to the index. The commands for
/// tracked files are `diff-index` and `diff-files` rather than `git diff`,
/// because they ignore settings such as `diff.algorithm` and `diff.context`, as
/// the `diff-tree` that shows commits does.
enum ChangesLoader {
    /// The most text Roga reads from `git status`. A file takes about 100
    /// bytes, so this is hundreds of thousands of files, as when a folder of
    /// build products isn't ignored.
    static let statusLimit = 64 << 20

    /// Lists the worktree's uncommitted files, without their line counts.
    ///
    /// It lists every untracked file rather than only the folders that hold
    /// them, unless the user turned off untracked files. Someone who keeps
    /// their home folder in a repository relies on that, because Roga would
    /// otherwise go through every file they have.
    ///
    /// It never downloads anything, because it runs for every worktree in the
    /// sidebar without anyone asking. In a partial clone without its files
    /// checked out, git would otherwise fetch every tree in `HEAD`, one folder
    /// at a time, and Roga would do that just by opening. git fails instead,
    /// and there's no list of changes. git versions that don't know the
    /// variable ignore it.
    ///
    /// - Parameter isUpkeep: Whether nobody is waiting for the answer, which
    ///   runs git at utility priority.
    @concurrent
    static func status(in directory: String, git: Git, limit: Int = statusLimit, isUpkeep: Bool = false) async throws -> WorktreeChanges {
        var setting = GitCommand("config", "--get", "status.showUntrackedFiles", in: directory)
        setting.successStatuses = [0, 1]
        let value = try await git.text(setting).lowercased()
        let untracked = ["no", "false", "off", "0"].contains(value) ? "no" : "all"

        var command = GitCommand(StatusParser.arguments + ["--untracked-files=" + untracked], in: directory)
        command.priority = isUpkeep ? .utility : .normal
        command.environment["GIT_NO_LAZY_FETCH"] = "1"
        var output: [UInt8] = []
        for try await chunk in git.stream(command) {
            output.append(contentsOf: chunk)
            guard output.count <= limit else { throw RepositoryError.tooManyChanges(limit: limit) }
        }
        do {
            return try StatusParser.parse(output)
        } catch {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
    }

    /// Lists the worktree's uncommitted files with their line counts, except
    /// for untracked files and conflicts, which aren't counted.
    @concurrent
    static func changes(in directory: String, format: ObjectFormat, git: Git) async throws -> WorktreeChanges {
        var changes = try await status(in: directory, git: git)
        let base = (changes.head ?? format.emptyTree).hex
        let hasStaged = !changes.staged.isEmpty
        let hasUnstaged = !changes.unstaged.isEmpty
        async let staged = lineCounts(
            ["diff-index", "--cached", "-r", "-M"] + NumstatParser.arguments + [base],
            isNeeded: hasStaged, in: directory, git: git
        )
        async let unstaged = lineCounts(
            ["diff-files", "-r"] + NumstatParser.arguments,
            isNeeded: hasUnstaged, in: directory, git: git
        )
        changes.staged = add(try await staged, to: changes.staged)
        changes.unstaged = add(try await unstaged, to: changes.unstaged)
        return changes
    }

    private static func lineCounts(
        _ arguments: [String],
        isNeeded: Bool,
        in directory: String,
        git: Git
    ) async throws -> [String: DiffFile.LineCounts?] {
        guard isNeeded else { return [:] }
        let command = GitCommand(arguments, in: directory)
        do {
            return try NumstatParser.parse(try await git.run(command).output)
        } catch let error as ParseError {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
    }

    private static func add(_ counts: [String: DiffFile.LineCounts?], to files: [DiffFile]) -> [DiffFile] {
        files.map { file in
            var file = file
            if let lines = counts[file.path] { file.lines = lines }
            return file
        }
    }

    /// Loads one uncommitted file's patch.
    ///
    /// A conflicted file compares the worktree with `HEAD`, which shows its
    /// conflict markers as lines added. `diff-files` would print a combined
    /// diff, whose hunks have a column for each side of the merge.
    ///
    /// - Parameter head: The commit that staged changes compare with, or nil
    ///   when there's none yet.
    /// - Throws: `RepositoryError.patchTooLarge` when the patch has more than
    ///   `limit` bytes, which stops git.
    @concurrent
    static func patch(
        of file: DiffFile,
        in group: WorktreeChanges.Group,
        head: ObjectID?,
        directory: String,
        format: ObjectFormat,
        git: Git,
        limit: Int = DiffLoader.patchLimit
    ) async throws -> FilePatch {
        let base = (head ?? format.emptyTree).hex
        let paths = [file.oldPath, file.path].compactMap { $0 }
        var command = switch group {
        case .staged:
            GitCommand(["diff-index", "--cached", "-r", "-M"] + PatchParser.arguments + [base, "--"] + paths, in: directory)
        case .unstaged:
            GitCommand(["diff-files", "-r", "-M"] + PatchParser.arguments + ["--"] + paths, in: directory)
        case .conflicted:
            GitCommand(["diff-index", "-r"] + PatchParser.arguments + [base, "--"] + paths, in: directory)
        case .untracked:
            // `--no-textconv` because `git diff` would otherwise run a command
            // that the repository's settings name, which the plumbing doesn't.
            GitCommand(["diff", "--no-index", "--no-textconv"] + PatchParser.arguments + ["--", "/dev/null"] + paths, in: directory)
        }
        command.environment["GIT_LITERAL_PATHSPECS"] = "1"
        // Comparing two files with `--no-index` exits with 1 when they differ.
        if group == .untracked { command.successStatuses = [0, 1] }
        return try await DiffLoader.readPatch(command, path: file.path, git: git, limit: limit)
    }
}
