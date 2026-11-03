import Foundation
import GitCore
import GitRunner

/// Where a repository keeps its files, and how it names its objects.
public struct RepositoryLocation: Sendable, Hashable {
    /// The top folder of the worktree that was opened, or nil when there's
    /// none, as in a bare repository.
    public var worktree: String?
    /// The git directory that all of the repository's worktrees share, which
    /// identifies the repository.
    public var commonDirectory: String
    /// The folder that holds the objects and the commit-graph files.
    public var objectsFolder: String
    public var format: ObjectFormat
    /// Whether the repository is a shallow clone, whose oldest commits leave
    /// out their parents.
    public var isShallow: Bool

    public init(worktree: String?, commonDirectory: String, objectsFolder: String, format: ObjectFormat, isShallow: Bool) {
        self.worktree = worktree
        self.commonDirectory = commonDirectory
        self.objectsFolder = objectsFolder
        self.format = format
        self.isShallow = isShallow
    }

    /// The folder git commands run in.
    public var directory: String { worktree ?? commonDirectory }

    /// The name to show for the repository: the worktree's folder, or the
    /// git directory's folder without `.git` when there's no worktree.
    public var name: String {
        if let worktree { return (worktree as NSString).lastPathComponent }
        return Self.name(gitDirectory: commonDirectory)
    }

    /// The name to show for the repository whose git directory is `path`:
    /// the folder that holds `.git`, or the git directory's own folder
    /// without `.git`, as for a bare repository.
    public static func name(gitDirectory path: String) -> String {
        var folder = path as NSString
        if folder.lastPathComponent == ".git" {
            folder = folder.deletingLastPathComponent as NSString
        }
        let name = folder.lastPathComponent
        return name.hasSuffix(".git") && name.count > 4 ? String(name.dropLast(4)) : name
    }

    /// Finds the repository that `path` is in, which can be any folder of a
    /// worktree, or a git directory.
    public static func find(containing path: String, git: Git) async throws -> RepositoryLocation {
        let details = GitCommand(
            [
                "rev-parse", "--path-format=absolute", "--git-common-dir", "--git-path", "objects",
                "--show-object-format", "--is-bare-repository", "--is-shallow-repository",
            ],
            in: path
        )
        // git can only name the worktree's top folder when there is one, and
        // fails with status 128 otherwise, as it does outside a repository.
        // Both run at once, and the first one says which it was.
        var topFolder = GitCommand("rev-parse", "--show-toplevel", in: path)
        topFolder.successStatuses = [0, 128]
        async let topFolderResult = git.run(topFolder)

        let lines: [Substring]
        do {
            lines = try await git.text(details).split(separator: "\n", omittingEmptySubsequences: false)
        } catch let error as GitError {
            throw RepositoryError.cannotOpen(path: path, message: Self.message(from: error))
        }
        guard lines.count == 5, let format = ObjectFormat(rawValue: String(lines[2])) else {
            throw RepositoryError.unexpectedOutput(details, lines.joined(separator: "\n"))
        }
        let isBare = lines[3] == "true"
        let top = try await topFolderResult
        var worktree: String?
        if !isBare, top.status == 0 {
            worktree = top.text.hasSuffix("\n") ? String(top.text.dropLast()) : top.text
        }
        return RepositoryLocation(
            worktree: worktree,
            commonDirectory: String(lines[0]),
            objectsFolder: String(lines[1]),
            format: format,
            isShallow: lines[4] == "true"
        )
    }

    /// git's own explanation of why it failed, without its `fatal:` prefix.
    private static func message(from error: GitError) -> String {
        guard case .failed(_, _, let errorOutput) = error else { return error.description }
        var message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.hasPrefix("fatal: ") { message.removeFirst("fatal: ".count) }
        return message.isEmpty ? error.description : message
    }
}

public enum RepositoryError: Error, Sendable, Hashable, CustomStringConvertible {
    /// git couldn't open a repository at the path. The message is git's.
    case cannotOpen(path: String, message: String)
    /// git printed something yaga didn't expect.
    case unexpectedOutput(GitCommand, String)
    /// A file's patch has more text than yaga reads.
    case patchTooLarge(path: String, limit: Int)
    /// A worktree's list of changed files has more text than yaga reads.
    case tooManyChanges(limit: Int)
    /// A fetch that nobody asked for ran for longer than yaga lets it.
    case fetchTookTooLong

    public var description: String {
        switch self {
        case .cannotOpen(let path, let message):
            "yaga couldn't open \(path) as a repository: \(message)"
        case .unexpectedOutput(let command, let output):
            "\(command) printed \(output.prefix(200).debugDescription), which yaga didn't expect."
        case .patchTooLarge(let path, let limit):
            "The changes to \(path) take more than \(limit >> 20) MB of text, which is too much to show."
        case .tooManyChanges(let limit):
            "The list of files that changed takes more than \(limit >> 20) MB of text, which is too much to show. A folder of generated files may need to be ignored."
        case .fetchTookTooLong:
            "git fetch took too long, so yaga stopped it."
        }
    }
}
