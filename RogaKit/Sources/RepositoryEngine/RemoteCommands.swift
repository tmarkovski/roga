import Foundation
import GitCore
import GitRunner

/// The commands that fetch, pull and push (decisions 19 and 20), which all use
/// the user's own credential helpers and SSH setup.
enum RemoteCommands {
    /// The fetch Roga runs by itself. It leaves `FETCH_HEAD` alone, because the
    /// user or an agent may be about to use it, and it starts no gc in the
    /// background and no fetches in submodules. It can't ask anyone for
    /// anything, so a credential that needs asking for fails instead.
    static func quietFetch(from remote: String, in directory: String) -> GitCommand {
        var command = GitCommand(
            "fetch", "--no-write-fetch-head", "--no-auto-maintenance", "--no-recurse-submodules", remote,
            in: directory
        )
        command.priority = .utility
        command.environment["GIT_ASKPASS"] = "/usr/bin/true"
        command.environment["SSH_ASKPASS_REQUIRE"] = "never"
        command.environment["GCM_INTERACTIVE"] = "never"
        return command
    }

    /// A command someone asked for, which changes the repository, so it can
    /// take optional locks. Nobody can answer an editor, so a merge keeps its
    /// message and an interactive rebase runs as it is.
    static func asked(_ arguments: [String], in worktree: String) -> GitCommand {
        var command = GitCommand(arguments, in: worktree)
        command.takesOptionalLocks = true
        command.environment["GIT_MERGE_AUTOEDIT"] = "no"
        command.environment["GIT_EDITOR"] = "true"
        command.environment["GIT_SEQUENCE_EDITOR"] = "true"
        return command
    }

    /// Says whether a worktree is partway through a merge or a rebase, whoever
    /// started it. A pull that hit a conflict leaves it that way.
    static func stoppedWork(in worktree: String, git: Git) async throws -> StoppedWork? {
        let command = GitCommand(
            "rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD", "--git-path", "rebase-merge", "--git-path", "rebase-apply",
            in: worktree
        )
        let paths = try await git.text(command).split(separator: "\n").map(String.init)
        guard paths.count == 3 else { return nil }
        return stoppedWork(mergeHead: paths[0], rebaseFolders: Array(paths[1...]))
    }

    /// Says the same by reading the worktree's own git directory, without git,
    /// for a quick look at every worktree. It's nil when it can't find that
    /// directory.
    static func stoppedWorkFromFiles(in worktree: String) -> StoppedWork? {
        guard let directory = gitDirectory(ofWorktree: worktree) else { return nil }
        return stoppedWork(
            mergeHead: directory + "/MERGE_HEAD",
            rebaseFolders: [directory + "/rebase-merge", directory + "/rebase-apply"]
        )
    }

    private static func stoppedWork(mergeHead: String, rebaseFolders: [String]) -> StoppedWork? {
        if FileManager.default.fileExists(atPath: mergeHead) { return .merge }
        for folder in rebaseFolders where FileManager.default.fileExists(atPath: folder) {
            // `git am` uses this folder too, and `git rebase --abort` won't undo it.
            if FileManager.default.fileExists(atPath: folder + "/applying") { return nil }
            let head = (try? String(contentsOfFile: folder + "/head-name", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .rebase(branch: head?.hasPrefix("refs/heads/") == true ? head : nil)
        }
        return nil
    }

    /// The git directory that's a worktree's own: its `.git` folder, or the
    /// folder its `.git` file points to, which is how a linked worktree has it.
    static func gitDirectory(ofWorktree worktree: String) -> String? {
        let dotGit = (worktree as NSString).appendingPathComponent(".git")
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue { return dotGit }
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first,
              line.hasPrefix("gitdir:")
        else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return (path as NSString).isAbsolutePath ? path : (worktree as NSString).appendingPathComponent(path)
    }
}
