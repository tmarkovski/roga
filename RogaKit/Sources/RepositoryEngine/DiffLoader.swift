import GitCore
import GitRunner

/// Loads what commits changed.
enum DiffLoader {
    /// The most text Roga reads for one file's patch. All 12,914 files that a
    /// release of Linux changes take 45 MB, so a patch over this is a file
    /// that nobody will read, such as a data dump, which could take gigabytes.
    static let patchLimit = 64 << 20

    /// The arguments that print a file's patch: in hunks, or with every line
    /// of the file (decision 74). git has no word for the whole file, so this
    /// asks for more lines around each change than a patch Roga reads can
    /// have, since every line takes at least a byte. The file then comes as
    /// one hunk that starts at its first line.
    static func patchArguments(wholeFile: Bool) -> [String] {
        PatchParser.arguments + (wholeFile ? ["-U\(patchLimit)"] : [])
    }

    /// Lists the files `commit` changed. A commit with no parents adds all of
    /// its files, and a merge is compared with its first parent, which shows
    /// what the merge brought into the branch.
    @concurrent
    static func changedFiles(in commit: ObjectID, git: Git, directory: String) async throws -> [DiffFile] {
        let command = GitCommand(
            ["diff-tree", "-r", "-M", "--root", "--no-commit-id", "--diff-merges=first-parent"]
                + RawDiffParser.arguments + [commit.hex],
            in: directory
        )
        do {
            return try RawDiffParser.parse(try await git.run(command).output)
        } catch let error as ParseError {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
    }

    /// Counts the lines each of `commits` added and removed, with one
    /// `git diff-tree` for all of them rather than one for each. Their IDs go
    /// in on standard input, so there's no limit on how many. A commit with no
    /// parents adds all of its lines. git says nothing about a merge, so a
    /// merge is missing from the result, as is a commit that changed nothing.
    @concurrent
    static func lineCounts(of commits: [ObjectID], git: Git, directory: String) async throws -> [ObjectID: DiffFile.LineCounts] {
        var command = GitCommand(
            ["diff-tree", "--stdin", "-r", "-M", "--root"] + CommitLineCountsParser.arguments,
            in: directory
        )
        command.priority = .utility
        var input: [UInt8] = []
        input.reserveCapacity(commits.count * 65)
        for commit in commits {
            input.append(contentsOf: commit.hex.utf8)
            input.append(UInt8(ascii: "\n"))
        }
        var parser = CommitLineCountsParser()
        do {
            for try await line in git.stream(command, input: input).records(separatedBy: UInt8(ascii: "\n")) {
                try parser.read(line)
            }
        } catch let error as ParseError {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
        return parser.counts
    }

    /// Loads what `commit` changed in `file`, comparing as `changedFiles` does.
    ///
    /// - Parameter wholeFile: Whether the patch has every line of the file
    ///   rather than only its hunks.
    /// - Throws: `RepositoryError.patchTooLarge` when the patch has more than
    ///   `limit` bytes, which stops git.
    @concurrent
    static func patch(
        of file: DiffFile,
        in commit: ObjectID,
        wholeFile: Bool = false,
        git: Git,
        directory: String,
        limit: Int = patchLimit
    ) async throws -> FilePatch {
        // git finds a rename only when it sees both sides, so without the old
        // path the file would look new.
        var command = GitCommand(
            ["diff-tree", "-r", "-M", "--root", "--no-commit-id", "--diff-merges=first-parent"]
                + patchArguments(wholeFile: wholeFile) + [commit.hex, "--"] + [file.oldPath, file.path].compactMap { $0 },
            in: directory
        )
        // These are names rather than patterns, and a name can hold a `*`.
        command.environment["GIT_LITERAL_PATHSPECS"] = "1"
        return try await readPatch(command, path: file.path, git: git, limit: limit)
    }

    /// Lists the files that differ from one commit to another, as when comparing
    /// two commits, a run of commits or a branch with where it left another.
    ///
    /// - Parameter from: The commit to compare from, or nil for nothing at all,
    ///   which lists every file in `to` as added.
    @concurrent
    static func changedFiles(from: ObjectID?, to: ObjectID, format: ObjectFormat, git: Git, directory: String) async throws -> [DiffFile] {
        let command = GitCommand(
            ["diff-tree", "-r", "-M"] + RawDiffParser.arguments + [(from ?? format.emptyTree).hex, to.hex],
            in: directory
        )
        do {
            return try RawDiffParser.parse(try await git.run(command).output)
        } catch let error as ParseError {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
    }

    /// Loads what changed in `file` from one commit to another, comparing as
    /// `changedFiles(from:to:)` does.
    ///
    /// - Parameter wholeFile: Whether the patch has every line of the file
    ///   rather than only its hunks.
    /// - Throws: `RepositoryError.patchTooLarge` when the patch has more than
    ///   `limit` bytes, which stops git.
    @concurrent
    static func patch(
        of file: DiffFile,
        from: ObjectID?,
        to: ObjectID,
        wholeFile: Bool = false,
        format: ObjectFormat,
        git: Git,
        directory: String,
        limit: Int = patchLimit
    ) async throws -> FilePatch {
        var command = GitCommand(
            ["diff-tree", "-r", "-M"] + patchArguments(wholeFile: wholeFile)
                + [(from ?? format.emptyTree).hex, to.hex, "--"] + [file.oldPath, file.path].compactMap { $0 },
            in: directory
        )
        command.environment["GIT_LITERAL_PATHSPECS"] = "1"
        return try await readPatch(command, path: file.path, git: git, limit: limit)
    }

    /// Runs a command that prints a file's patch, and stops it at `limit` bytes.
    static func readPatch(_ command: GitCommand, path: String, git: Git, limit: Int) async throws -> FilePatch {
        var output: [UInt8] = []
        for try await chunk in git.stream(command) {
            output.append(contentsOf: chunk)
            guard output.count <= limit else { throw RepositoryError.patchTooLarge(path: path, limit: limit) }
        }
        do {
            return try PatchParser.parse(output)
        } catch {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
    }
}
