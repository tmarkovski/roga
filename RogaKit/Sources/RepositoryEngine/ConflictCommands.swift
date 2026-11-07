import Foundation
import GitCore
import GitRunner

/// One of the two sides of a conflict, as git names them.
public enum ConflictSide: Sendable, Hashable {
    /// `HEAD`'s side, which in a rebase is what the commits are going onto.
    case ours
    /// The side coming in: the branch being merged, the commit being replayed,
    /// a revert's undoing or the stash.
    case theirs

    /// What `git checkout` calls it.
    var flag: String {
        switch self {
        case .ours: "--ours"
        case .theirs: "--theirs"
        }
    }
}

/// A conflicted file changed on disk after Roga read it, such as when an editor or
/// an agent wrote to it, so Roga didn't write over it.
public struct ConflictedFileChanged: Error, Sendable, Hashable, CustomStringConvertible {
    public var path: String

    public var description: String {
        "\(path) changed after Roga read it, so Roga didn't write to it. It shows the file as it is now."
    }
}

/// Reading the conflicts in a worktree's file and writing what resolves them
/// (decision 60). The conflicts are in the file itself, so it's read and written
/// directly, and git only comes in to keep one side's whole version or to mark a
/// file resolved.
enum ConflictCommands {
    /// The largest file Roga reads for its conflicts. Bigger ones show as a patch.
    static let fileLimit = 16 << 20

    /// Reads a file in a worktree and finds its conflicts. It's nil when the path
    /// isn't a regular file, such as a link or a folder, or is too big.
    static func read(_ path: String, in worktree: String) throws -> ConflictedFile? {
        let fullPath = (worktree as NSString).appendingPathComponent(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: fullPath)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? Int ?? 0) <= fileLimit,
              let data = FileManager.default.contents(atPath: fullPath)
        else { return nil }
        return ConflictedFile.parse(Array(data))
    }

    /// Writes a file's new contents in place, so that it keeps its permissions,
    /// as long as it still has exactly what Roga read.
    ///
    /// - Throws: `ConflictedFileChanged` when it doesn't, which writes nothing.
    static func write(_ bytes: [UInt8], replacing expected: [UInt8], at path: String, in worktree: String) throws {
        let url = URL(fileURLWithPath: (worktree as NSString).appendingPathComponent(path))
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let current = try handle.readToEnd() ?? Data()
        guard current.elementsEqual(expected) else { throw ConflictedFileChanged(path: path) }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: bytes)
        try handle.truncate(atOffset: UInt64(bytes.count))
    }

    /// Takes one side's whole version of each file, and marks them resolved.
    static func keep(_ side: ConflictSide, of paths: [String], in worktree: String, git: Git) async throws {
        guard !paths.isEmpty else { return }
        try await IndexCommands.run(["checkout", side.flag, "--pathspec-from-file=-", "--pathspec-file-nul"], paths: paths, in: worktree, git: git)
        try await IndexCommands.stage(paths, in: worktree, git: git)
    }

    /// Writes each file's conflicts back as git first wrote them, which throws away
    /// whatever resolved them.
    static func putBack(_ paths: [String], in worktree: String, git: Git) async throws {
        guard !paths.isEmpty else { return }
        try await IndexCommands.run(["checkout", "--merge", "--pathspec-from-file=-", "--pathspec-file-nul"], paths: paths, in: worktree, git: git)
    }

    /// What git would write after the markers on the side coming in, for naming the
    /// sides of a conflicted file that has no markers, such as a binary file or one
    /// that one side deleted. It's the commit being merged, replayed or picked, by
    /// its full hash, or `parent of` it for a revert, or `Stashed changes` when
    /// nothing is underway, which is what a stash pop leaves.
    static func incomingLabel(in worktree: String, git: Git) async throws -> String {
        let names = ["MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"]
        let command = GitCommand(["rev-parse", "--path-format=absolute"] + names.flatMap { ["--git-path", $0] }, in: worktree)
        let paths = try await git.text(command).split(separator: "\n").map(String.init)
        for (name, path) in zip(names, paths) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let line = text.split(whereSeparator: \.isNewline).first,
                  let id = ObjectID(hex: line.trimmingCharacters(in: .whitespaces))
            else { continue }
            return name == "REVERT_HEAD" ? "parent of " + id.hex : id.hex
        }
        return "Stashed changes"
    }

    /// The commit a rebase that stopped is putting commits onto, which names the
    /// side git calls ours. It's nil when no rebase is underway.
    static func rebaseOnto(in worktree: String, git: Git) async throws -> ObjectID? {
        let path = try await git.text(GitCommand("rev-parse", "--path-format=absolute", "--git-path", "rebase-merge/onto", in: worktree))
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return ObjectID(hex: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
