import GitCore
import GitRunner

/// Loads what commits changed.
enum DiffLoader {
    /// The most text yaga reads for one file's patch. All 12,914 files that a
    /// release of Linux changes take 45 MB, so a patch over this is a file
    /// that nobody will read, such as a data dump, which could take gigabytes.
    static let patchLimit = 64 << 20

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

    /// Loads what `commit` changed in `file`, comparing as `changedFiles` does.
    ///
    /// - Throws: `RepositoryError.patchTooLarge` when the patch has more than
    ///   `limit` bytes, which stops git.
    @concurrent
    static func patch(
        of file: DiffFile,
        in commit: ObjectID,
        git: Git,
        directory: String,
        limit: Int = patchLimit
    ) async throws -> FilePatch {
        // git finds a rename only when it sees both sides, so without the old
        // path the file would look new.
        var command = GitCommand(
            ["diff-tree", "-r", "-M", "--root", "--no-commit-id", "--diff-merges=first-parent"]
                + PatchParser.arguments + [commit.hex, "--"] + [file.oldPath, file.path].compactMap { $0 },
            in: directory
        )
        // These are names rather than patterns, and a name can hold a `*`.
        command.environment["GIT_LITERAL_PATHSPECS"] = "1"

        var output: [UInt8] = []
        for try await chunk in git.stream(command) {
            output.append(contentsOf: chunk)
            guard output.count <= limit else { throw RepositoryError.patchTooLarge(path: file.path, limit: limit) }
        }
        do {
            return try PatchParser.parse(output)
        } catch {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
    }
}
