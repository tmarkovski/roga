import Foundation
import GitCore
import GitRunner

/// Stashing everything that's uncommitted, and putting a stash back, deleting it
/// or making a branch from it, which the Stash button and a stash's menu ask for
/// (decision 81). A stash is found by its commit each time rather than by its
/// place in the list, because an agent can stash or drop one meanwhile, which
/// moves the others.
public enum Stashes {
    /// How putting a stash back went.
    public enum PutBack: Sendable, Hashable {
        /// Everything came back.
        ///
        /// - files: How many files the stash had.
        /// - unstaged: Whether what the stash had staged came back unstaged,
        ///   because something else was staged already.
        case back(files: Int, unstaged: Bool)
        /// git stopped on conflicts in these files, and the stash stays in the list.
        ///
        /// - indexBefore: What was staged before, as a tree, which undoing goes
        ///   back to. It's nil when git couldn't write it.
        /// - ran: What ran, by its arguments after `git`.
        case conflicted(files: [String], indexBefore: ObjectID?, ran: [String])
    }

    /// The stash isn't in the list any more, because something else put it back
    /// or deleted it.
    public struct Missing: Error, Sendable, Hashable, CustomStringConvertible {
        public var stash: ObjectID

        public var description: String {
            "The stash \(stash.hex.prefix(8)) isn't in the list of stashes any more. Something else may have put it back or deleted it."
        }
    }

    /// What stashes everything that's uncommitted, staged and untracked files
    /// included, so that the worktree is left clean. git leaves a repository
    /// inside the worktree where it is, such as an agent's worktree.
    public static func stashArguments(message: String) -> [String] {
        ["stash", "push", "--include-untracked", "--message", message]
    }

    /// What puts a stash back, and deletes it unless it's kept.
    ///
    /// - Parameter withIndex: Whether what the stash had staged is staged again.
    ///   git 2.52 refuses that when anything else is staged, and unstages it on
    ///   the way out, so it's only asked for when nothing is.
    public static func putBackArguments(_ ref: String, keeping: Bool, withIndex: Bool) -> [String] {
        ["stash", keeping ? "apply" : "pop"] + (withIndex ? ["--index"] : []) + [ref]
    }

    /// What makes a branch where a stash was made, switches to it and puts the
    /// stash back there, where it always fits.
    public static func branchArguments(name: String, ref: String) -> [String] {
        ["stash", "branch", name, ref]
    }

    /// What lists a stash again with the message it had, at the top of the list,
    /// which is the only place git can put one.
    public static func storeArguments(_ stash: ObjectID, message: String) -> [String] {
        ["stash", "store", "--quiet", "--message", message, stash.hex]
    }

    /// The paths of the files a stash would take, leaving out a repository inside
    /// the worktree, which git doesn't stash, and counting a file that's both
    /// staged and unstaged once.
    public static func paths(of changes: WorktreeChanges) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for file in changes.conflicted + changes.staged + changes.unstaged + changes.untracked where !file.path.hasSuffix("/") {
            if seen.insert(file.path).inserted { paths.append(file.path) }
        }
        return paths
    }

    /// What a stash of these files is called: their names, as in
    /// `LoginView.swift, SessionStore.swift and Notes.md`, or the first two
    /// and how many more. That says more in the list than git's own
    /// `WIP on main: 5405371 Fix it`.
    public static func message(for paths: [String]) -> String {
        var names: [String] = []
        for path in paths {
            let name = String(path.split(separator: "/").last ?? Substring(path))
            if !names.contains(name) { names.append(name) }
        }
        switch names.count {
        case 0: return "Uncommitted changes"
        case 1: return names[0]
        case 2, 3: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        default: return names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
        }
    }

    // MARK: Running

    /// Stashes everything that's uncommitted.
    ///
    /// - Returns: The new stash, or nil when git saved nothing, as when the
    ///   changes went meanwhile.
    static func stash(message: String, in worktree: String, git: Git) async throws -> ObjectID? {
        let before = try await newest(in: worktree, git: git)
        _ = try await IndexCommands.runningThroughLocks(RemoteCommands.asked(stashArguments(message: message), in: worktree), input: nil, git: git)
        guard let stash = try await newest(in: worktree, git: git), stash != before else { return nil }
        return stash
    }

    /// Puts a stash back where `HEAD` is now. When that stops on conflicts, git
    /// stages every file that came back cleanly, so the ones that weren't staged,
    /// before or in the stash, go back to being unstaged.
    ///
    /// - Throws: `Missing` when the stash has gone from the list, or `GitError`
    ///   when git refused without leaving any conflict.
    static func putBack(_ stash: ObjectID, keeping: Bool, in worktree: String, git: Git) async throws -> PutBack {
        let (ref, _) = try await find(stash, in: worktree, git: git)
        let stagedBefore = Set(try await names(["diff", "--cached", "--name-only", "-z", "--no-renames"], in: worktree, git: git))
        let indexBefore = try? await writeTree(in: worktree, git: git)
        let base = stash.hex + "^1"
        let index = stash.hex + "^2"
        let stashStaged = Set(try await names(["diff", "--name-only", "-z", "--no-renames", base, index, "--"], in: worktree, git: git))
        let withIndex = stagedBefore.isEmpty
        let arguments = putBackArguments(ref, keeping: keeping, withIndex: withIndex)
        let files = try await touched(stash, in: worktree, git: git)
        do {
            _ = try await IndexCommands.runningThroughLocks(RemoteCommands.asked(arguments, in: worktree), input: nil, git: git)
            return .back(files: files.tracked.count + files.untracked.count, unstaged: !withIndex && !stashStaged.isEmpty)
        } catch let error as GitError {
            let conflicted = try await names(["diff", "--name-only", "-z", "--diff-filter=U"], in: worktree, git: git)
            guard !conflicted.isEmpty else { throw error }
            let staged = try await names(["diff", "--cached", "--name-only", "-z", "--no-renames"], in: worktree, git: git)
            let cleanlyBack = staged.filter { !Set(conflicted).contains($0) }
            // A file `HEAD` hasn't changed since the stash was made gets back exactly
            // what the stash had staged, which matters when only some of its changes
            // were. One that `HEAD` changed keeps all of it staged, because what was
            // staged was against the old commit.
            let moved = Set(try await names(["diff", "--name-only", "-z", "--no-renames", base, "HEAD", "--"], in: worktree, git: git))
            let keepsStaging = withIndex ? stashStaged : []
            try await IndexCommands.unstage(cleanlyBack.filter { !stagedBefore.contains($0) && !keepsStaging.contains($0) }, in: worktree, git: git)
            let restoring = cleanlyBack.filter { keepsStaging.contains($0) && !moved.contains($0) }
            if !restoring.isEmpty {
                try await IndexCommands.run(
                    ["restore", "--staged", "--source=" + index, "--pathspec-from-file=-", "--pathspec-file-nul"],
                    paths: restoring,
                    in: worktree,
                    git: git
                )
            }
            return .conflicted(files: conflicted, indexBefore: indexBefore, ran: arguments)
        }
    }

    /// Takes back a put back that stopped on conflicts: the files the stash had go
    /// back to what was staged before, and the untracked ones it brought go away.
    /// Nothing else changes, which is safe because git won't put a stash back over
    /// a file with changes that aren't staged, or over an untracked file. The
    /// stash is still in the list, since git keeps it when there's a conflict.
    static func undoPutBack(_ stash: ObjectID, indexBefore: ObjectID, in worktree: String, git: Git) async throws {
        let files = try await touched(stash, in: worktree, git: git)
        let all = files.tracked + files.untracked.filter { !files.tracked.contains($0) }
        guard !all.isEmpty else { return }
        var listing = GitCommand(["ls-tree", "-r", "-z", "--name-only", indexBefore.hex, "--"] + all, in: worktree)
        listing.environment["GIT_LITERAL_PATHSPECS"] = "1"
        let output = try await git.run(listing).output
        let before = Set(output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        let restoring = all.filter { before.contains($0) }
        let removing = all.filter { !before.contains($0) }
        if !restoring.isEmpty {
            try await IndexCommands.run(
                ["checkout", indexBefore.hex, "--pathspec-from-file=-", "--pathspec-file-nul"],
                paths: restoring,
                in: worktree,
                git: git
            )
        }
        if !removing.isEmpty {
            try await IndexCommands.run(
                ["rm", "--cached", "--quiet", "--ignore-unmatch", "--pathspec-from-file=-", "--pathspec-file-nul"],
                paths: removing,
                in: worktree,
                git: git
            )
            // These weren't there before, since git won't overwrite an untracked
            // file, and the stash still has them.
            for path in removing {
                try? FileManager.default.removeItem(atPath: worktree + "/" + path)
            }
        }
    }

    /// Deletes a stash from the list.
    ///
    /// - Returns: The message it was listed with, which listing it again needs.
    static func drop(_ stash: ObjectID, in worktree: String, git: Git) async throws -> String {
        let (ref, message) = try await find(stash, in: worktree, git: git)
        _ = try await git.run(RemoteCommands.asked(["stash", "drop", "--quiet", ref], in: worktree))
        return message
    }

    /// Lists a stash again after it was deleted. git keeps its commit until it
    /// prunes what nothing points to, which takes weeks.
    static func store(_ stash: ObjectID, message: String, in worktree: String, git: Git) async throws {
        _ = try await git.run(RemoteCommands.asked(storeArguments(stash, message: message), in: worktree))
    }

    /// Makes a branch where a stash was made, switches to it, and puts the
    /// stash back there.
    static func branch(_ name: String, from stash: ObjectID, in worktree: String, git: Git) async throws {
        let (ref, _) = try await find(stash, in: worktree, git: git)
        _ = try await IndexCommands.runningThroughLocks(RemoteCommands.asked(branchArguments(name: name, ref: ref), in: worktree), input: nil, git: git)
    }

    /// What git calls a stash now, as in `stash@{1}`, and the message it's
    /// listed with.
    ///
    /// - Throws: `Missing` when it isn't in the list.
    static func find(_ stash: ObjectID, in worktree: String, git: Git) async throws -> (ref: String, message: String) {
        var command = GitCommand("stash", "list", "--format=%H%x00%gs", in: worktree)
        command.successStatuses = [0, 1]
        let lines = try await git.text(command).split(separator: "\n")
        for (place, line) in lines.enumerated() {
            let fields = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            if fields.first.map(String.init) == stash.hex {
                return ("stash@{\(place)}", fields.count > 1 ? String(fields[1]) : "")
            }
        }
        throw Missing(stash: stash)
    }

    /// The files a stash has: the tracked ones it changed, staged or not, and
    /// the untracked ones it took, which are in a third parent when it has any.
    private static func touched(_ stash: ObjectID, in worktree: String, git: Git) async throws -> (tracked: [String], untracked: [String]) {
        let base = stash.hex + "^1"
        var tracked = try await names(["diff", "--name-only", "-z", "--no-renames", base, stash.hex, "--"], in: worktree, git: git)
        for path in try await names(["diff", "--name-only", "-z", "--no-renames", base, stash.hex + "^2", "--"], in: worktree, git: git) where !tracked.contains(path) {
            tracked.append(path)
        }
        var third = GitCommand("rev-parse", "--verify", "--quiet", stash.hex + "^3", in: worktree)
        third.successStatuses = [0, 1]
        let untrackedCommit = try await git.text(third)
        guard !untrackedCommit.isEmpty else { return (tracked, []) }
        let untracked = try await names(["ls-tree", "-r", "-z", "--name-only", stash.hex + "^3"], in: worktree, git: git)
        return (tracked, untracked)
    }

    private static func newest(in worktree: String, git: Git) async throws -> ObjectID? {
        var command = GitCommand("rev-parse", "--verify", "--quiet", "refs/stash", in: worktree)
        command.successStatuses = [0, 1]
        return ObjectID(hex: try await git.text(command))
    }

    private static func writeTree(in worktree: String, git: Git) async throws -> ObjectID? {
        ObjectID(hex: try await git.text(GitCommand("write-tree", in: worktree)))
    }

    /// The paths a command lists, each ending with a zero byte.
    private static func names(_ arguments: [String], in worktree: String, git: Git) async throws -> [String] {
        let output = try await git.run(GitCommand(arguments, in: worktree)).output
        return output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
}
