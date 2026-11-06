import Foundation
import GitRunner

/// Remembers which paths in each worktree git ignores, so that a build writing
/// thousands of files into an ignored folder doesn't have Roga look at the
/// worktree again and again.
///
/// It asks `git check-ignore` about the paths it doesn't know yet, and about
/// the folders they're in. git never looks inside an ignored folder, so nothing
/// in one can matter. A folder only counts as ignored when the index has nothing
/// in it: `git check-ignore build/` doesn't match `build/` while `git add
/// --force` has put a file there. The trailing `/` matters, because without it
/// git only treats the path as a folder when it's on disk.
struct IgnoredPaths: Sendable {
    private struct Known: Sendable {
        var ignoredFolders: Set<String> = []
        var shownFolders: Set<String> = []
        var ignoredFiles: Set<String> = []
        var shownFiles: Set<String> = []

        var count: Int { ignoredFolders.count + shownFolders.count + ignoredFiles.count + shownFiles.count }

        /// Whether git doesn't ignore the path, as far as it knows.
        func shows(_ changed: ChangedPath, in folders: [String]) -> Bool {
            folders.allSatisfy(shownFolders.contains)
                && (changed.isFolder ? shownFolders.contains(changed.path + "/") : shownFiles.contains(changed.path))
        }
    }

    /// What it knows about each worktree, by the worktree's path.
    private var known: [String: Known] = [:]

    /// How many paths it remembers in a worktree before it starts again, so
    /// that a build in a tree as large as Linux, which ignores files by
    /// pattern, can't grow it without end.
    static let limit = 50_000

    /// Forgets what it knew about a worktree, because what git ignores there
    /// may have changed.
    mutating func forget(_ worktree: String) {
        known[worktree] = nil
    }

    mutating func forgetAll() {
        known = [:]
    }

    /// Whether any of the paths is one that git doesn't ignore. When git can't
    /// say, that counts as yes, so that the worktree gets looked at.
    ///
    /// - Parameter folder: The worktree's folder, which git runs in.
    mutating func anyMatters(_ paths: Set<ChangedPath>, in worktree: String, folder: String, git: Git) async -> Bool {
        var known = known[worktree] ?? Known()
        if known.count > Self.limit { known = Known() }
        defer { self.known[worktree] = known }

        var unknown: [ChangedPath] = []
        var asked: [String] = []
        var askedAlready: Set<String> = []
        func ask(_ path: String) {
            if askedAlready.insert(path).inserted { asked.append(path) }
        }
        for changed in paths {
            let folders = Self.folders(holding: changed.path)
            if folders.contains(where: known.ignoredFolders.contains) { continue }
            if changed.isFolder ? known.ignoredFolders.contains(changed.path + "/") : known.ignoredFiles.contains(changed.path) { continue }
            // One path it knows git shows is enough, as when someone keeps
            // saving the same file.
            if known.shows(changed, in: folders) { return true }
            unknown.append(changed)
            for folder in folders where !known.shownFolders.contains(folder) { ask(folder) }
            ask(changed.isFolder ? changed.path + "/" : changed.path)
        }
        guard !unknown.isEmpty else { return false }

        guard let ignored = await Self.checkIgnore(asked, in: folder, git: git) else { return true }
        for path in asked {
            if path.hasSuffix("/") {
                if ignored.contains(path) { known.ignoredFolders.insert(path) } else { known.shownFolders.insert(path) }
            } else if ignored.contains(path) {
                known.ignoredFiles.insert(path)
            } else {
                known.shownFiles.insert(path)
            }
        }
        return unknown.contains { changed in
            !Self.folders(holding: changed.path).contains(where: known.ignoredFolders.contains)
                && !ignored.contains(changed.isFolder ? changed.path + "/" : changed.path)
        }
    }

    /// The folders a path is in, from the top, each ending in `/`.
    static func folders(holding path: String) -> [String] {
        var folders: [String] = []
        var end = path.startIndex
        while let slash = path[end...].firstIndex(of: "/") {
            folders.append(String(path[...slash]))
            end = path.index(after: slash)
        }
        return folders
    }

    /// Which of the paths git ignores, or nil when git can't say, as when the
    /// worktree's folder is gone.
    private static func checkIgnore(_ paths: [String], in folder: String, git: Git) async -> Set<String>? {
        var command = GitCommand(["check-ignore", "--stdin", "-z", "--verbose", "--non-matching"], in: folder)
        command.priority = .utility
        // It answers 1 when it ignores none of them.
        command.successStatuses = [0, 1]
        var input: [UInt8] = []
        for path in paths {
            input.append(contentsOf: path.utf8)
            input.append(0)
        }
        guard let result = try? await git.run(command, input: input) else { return nil }
        return parse(result.output)
    }

    /// Reads what `git check-ignore -z --verbose --non-matching` prints: four
    /// fields for each path, of which the first, the file the matching pattern
    /// came from, is empty when nothing matched, and the last is the path.
    static func parse(_ output: [UInt8]) -> Set<String> {
        let fields = output.split(separator: 0, omittingEmptySubsequences: false)
        var ignored: Set<String> = []
        var index = 0
        while index + 3 < fields.count {
            if !fields[index].isEmpty {
                ignored.insert(String(decoding: fields[index + 3], as: UTF8.self))
            }
            index += 4
        }
        return ignored
    }
}
