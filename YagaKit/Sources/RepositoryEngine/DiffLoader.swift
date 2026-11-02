import GitCore
import GitRunner

/// Loads what commits changed.
enum DiffLoader {
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
}
