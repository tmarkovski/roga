import Foundation
import GitCore
import GitRunner

/// Where a file goes when Roga discards it. Tests move files into a folder of their
/// own, so that they don't fill the Trash of whoever runs them.
public struct FileTrash: Sendable {
    /// Moves a file out of the way, and says where it went.
    var move: @Sendable (URL) throws -> URL

    public init(move: @escaping @Sendable (URL) throws -> URL) {
        self.move = move
    }

    /// The Trash that Finder shows.
    public static let system = FileTrash { url in
        var moved: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &moved)
        return (moved as URL?) ?? url
    }
}

/// What someone threw away, and what's needed to bring it back (decision 39).
///
/// git has no undo for this, because unstaged lines were never in git. So Roga keeps
/// what's about to go, just before it goes. Patches stay in memory, so they last until
/// Roga quits. Trashed files last until the Trash is emptied, and a stash commit until
/// git prunes it, though only Roga knows which it is.
public struct DiscardedChanges: Sendable, Hashable {
    public struct TrashedFile: Sendable, Hashable {
        /// Where it was, inside the worktree.
        var path: String
        /// Where it is now.
        var trashed: String
    }

    /// What `git apply` reads to put back what left tracked files.
    var patch: [UInt8]?
    /// The commit that `git stash create` made, for `git stash apply --index`.
    var stash: String?
    var trashed: [TrashedFile] = []

    /// Whether there's anything to bring back. A patch too long to keep leaves nothing.
    public var canBeBroughtBack: Bool {
        patch != nil || stash != nil || !trashed.isEmpty
    }

    /// How much memory it takes to keep this.
    public var keptBytes: Int {
        patch?.count ?? 0
    }
}

/// The commands that throw away uncommitted changes. Like the others that write to a
/// worktree, they run only because someone asked.
enum DiscardCommands {
    /// The longest patch to keep for bringing files back, which stays in memory.
    static let keptPatchLimit = 64 << 20
    /// How many paths go on one command line. Unlike `git restore`, `git diff-files`
    /// can't read them from a file.
    static let pathsPerCommand = 500

    /// Takes one hunk out of a file on disk. It's the text that's on screen that goes:
    /// when lines around it have moved, git finds them, and when the hunk's own lines
    /// have changed, git refuses and nothing changes.
    static func discard(_ hunk: HunkPatch, in worktree: String, git: Git) async throws -> DiscardedChanges {
        try await apply(hunk.bytes, reversed: true, in: worktree, git: git)
        return DiscardedChanges(patch: hunk.bytes)
    }

    /// Takes files back to what git has for them, and moves the ones git has nothing
    /// for to the Trash.
    ///
    /// - Parameter files: Files of `group`.
    static func discard(
        _ files: [DiffFile],
        from group: WorktreeChanges.Group,
        in worktree: String,
        git: Git,
        trash: FileTrash,
        keptPatchLimit: Int = keptPatchLimit
    ) async throws -> DiscardedChanges {
        let restored = files.filter { group.discarding($0) == .restore }.map(\.path)
        let trashed = files.filter { group.discarding($0) == .trash }
        var discarded = DiscardedChanges()
        if !restored.isEmpty {
            discarded.patch = try await keptPatch(of: restored, limit: keptPatchLimit, in: worktree, git: git)
            try await IndexCommands.run(
                ["restore", "--worktree", "--pathspec-from-file=-", "--pathspec-file-nul"],
                paths: restored,
                in: worktree,
                git: git
            )
        }
        discarded.trashed = try moveToTrash(trashed.map(\.path), in: worktree, trash: trash)
        // A file added with `git add -N` is gone from disk, but still in the index.
        try await IndexCommands.unstage(trashed.filter { $0.status == .added }.map(\.path), in: worktree, git: git)
        return discarded
    }

    /// Takes the whole worktree back to `HEAD`, and moves what git has no copy of to
    /// the Trash. Before the first commit there's nothing for a stash to compare with,
    /// so that can't be brought back.
    static func discardEverything(trashing files: [DiffFile], in worktree: String, git: Git, trash: FileTrash) async throws -> DiscardedChanges {
        var discarded = DiscardedChanges()
        discarded.trashed = try moveToTrash(files.map(\.path), in: worktree, trash: trash)
        try await IndexCommands.unstage(files.filter { $0.status == .added }.map(\.path), in: worktree, git: git)
        let commit = (try? await git.text(RemoteCommands.asked(["stash", "create"], in: worktree))) ?? ""
        discarded.stash = commit.isEmpty ? nil : commit
        _ = try await IndexCommands.runningThroughLocks(RemoteCommands.asked(["reset", "--hard", "--quiet"], in: worktree), input: nil, git: git)
        return discarded
    }

    /// Brings back what a discard took.
    ///
    /// - Throws: `GitError` when git refuses, because the file has changed where
    ///   the lines would go, which changes nothing.
    static func bringBack(_ discarded: DiscardedChanges, in worktree: String, git: Git) async throws {
        if let stash = discarded.stash {
            _ = try await IndexCommands.runningThroughLocks(
                RemoteCommands.asked(["stash", "apply", "--index", "--quiet", stash], in: worktree),
                input: nil,
                git: git
            )
        }
        if let patch = discarded.patch {
            try await apply(patch, reversed: false, in: worktree, git: git)
        }
        let manager = FileManager.default
        for file in discarded.trashed {
            let place = URL(filePath: worktree).appending(path: file.path)
            try manager.createDirectory(at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: URL(filePath: file.trashed), to: place)
        }
    }

    /// `--whitespace=nowarn` because `apply.whitespace` is about patches coming in,
    /// and this is someone's own file going back to how it was.
    private static func apply(_ patch: [UInt8], reversed: Bool, in worktree: String, git: Git) async throws {
        let arguments = ["apply", "--whitespace=nowarn"] + (reversed ? ["--reverse"] : [])
        _ = try await git.run(RemoteCommands.asked(arguments, in: worktree), input: patch)
    }

    /// Reads what discarding these files would lose, or nil when that's too long to
    /// keep, which stops git.
    private static func keptPatch(of paths: [String], limit: Int, in worktree: String, git: Git) async throws -> [UInt8]? {
        var patch: [UInt8] = []
        var start = 0
        while start < paths.count {
            let end = min(start + pathsPerCommand, paths.count)
            var command = GitCommand(["diff-files", "-r", "--binary"] + PatchParser.arguments + ["--"] + paths[start..<end], in: worktree)
            command.environment["GIT_LITERAL_PATHSPECS"] = "1"
            for try await chunk in git.stream(command) {
                patch.append(contentsOf: chunk)
                if patch.count > limit { return nil }
            }
            start = end
        }
        return patch.isEmpty ? nil : patch
    }

    private static func moveToTrash(_ paths: [String], in worktree: String, trash: FileTrash) throws -> [DiscardedChanges.TrashedFile] {
        let root = URL(filePath: worktree)
        var trashed: [DiscardedChanges.TrashedFile] = []
        for path in paths {
            let place = root.appending(path: path)
            let moved = try trash.move(place)
            trashed.append(.init(path: path, trashed: moved.path))
            removeEmptyFolders(above: place, in: worktree)
        }
        return trashed
    }

    /// Removes the folders a file leaves empty, up to the worktree, since git doesn't
    /// list an empty folder and nobody could tell it's there. `rmdir` can't remove a
    /// folder that has anything in it, such as an ignored file.
    private static func removeEmptyFolders(above file: URL, in worktree: String) {
        let root = URL(filePath: worktree).standardizedFileURL.path
        var folder = file.deletingLastPathComponent().standardizedFileURL
        while folder.path.hasPrefix(root + "/"), rmdir(folder.path) == 0 {
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
    }
}
