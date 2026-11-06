import Foundation
import GitCore

/// What one batch of changes on disk affects in a repository, which a
/// session's watcher works out from the paths that changed (ARCHITECTURE.md,
/// "Changes on disk"). Worktrees are named by their folders as git lists them.
public struct RepositoryChanges: Sendable, Hashable {
    /// Counts the batches the session's watcher has seen, starting at 1. A
    /// look at a worktree that started after this batch arrived sees what it
    /// changed, which `RepositorySession.status(in:isUpkeep:asNewAs:)` relies on.
    public var number: Int
    /// A branch, tag, remote branch or stash moved, came or went, or the
    /// repository's config changed.
    public var refs = false
    /// The repository's config changed, which can change its remotes and who
    /// owns it.
    public var config = false
    /// A linked worktree came or went, or was locked or unlocked.
    public var worktreeList = false
    /// The worktrees whose `HEAD` changed, as when they're on another branch.
    /// Each of them is in `files` too, because what's staged compares with
    /// `HEAD`.
    public var heads: Set<String> = []
    /// The worktrees whose uncommitted files may have changed: their index,
    /// files that git doesn't ignore, or what they're stuck partway through.
    public var files: Set<String> = []

    public init(number: Int, refs: Bool = false, config: Bool = false, worktreeList: Bool = false, heads: Set<String> = [], files: Set<String> = []) {
        self.number = number
        self.refs = refs
        self.config = config
        self.worktreeList = worktreeList
        self.heads = heads
        self.files = files
    }

    /// Whether the batch changed nothing that Roga shows.
    public var isEmpty: Bool {
        !refs && !config && !worktreeList && heads.isEmpty && files.isEmpty
    }
}

/// One of a repository's worktrees, as the watcher finds what's in it.
struct WatchedWorktree: Sendable, Hashable {
    /// The worktree's folder as git lists it, which is how the rest of Roga
    /// names it.
    var path: String
    /// The real path of its folder, which is how FSEvents names what's in it,
    /// or nil for a bare repository's entry, which has no files.
    var folder: String?
    /// The real path of the folder in the git directory with its `HEAD` and
    /// index: the common directory for the main worktree, and
    /// `worktrees/<name>` in it for a linked one.
    var gitFolder: String
}

/// Where a repository keeps what its watcher looks at, with every path real.
struct WatchedLayout: Sendable, Hashable {
    var commonDirectory: String
    var worktrees: [WatchedWorktree]

    /// The layout of a repository with these worktrees. A linked worktree's
    /// folder in the git directory is the one whose `gitdir` file leads to it,
    /// which is how git links them. Worktrees whose folders are gone have
    /// nothing to watch.
    init(commonDirectory: String, worktrees: [Worktree]) {
        let common = Self.realPath(commonDirectory)
        self.commonDirectory = common
        var linked: [String: String] = [:]
        let admin = common + "/worktrees"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: admin)) ?? [] {
            let folder = admin + "/" + name
            guard let link = try? String(contentsOfFile: folder + "/gitdir", encoding: .utf8) else { continue }
            let gitFile = link.trimmingCharacters(in: .whitespacesAndNewlines)
            linked[Self.realPath((gitFile as NSString).deletingLastPathComponent)] = folder
        }
        self.worktrees = worktrees.compactMap { worktree in
            if worktree.isBare { return WatchedWorktree(path: worktree.path, folder: nil, gitFolder: common) }
            guard !worktree.isPrunable else { return nil }
            let folder = Self.realPath(worktree.path)
            if worktree.isMain { return WatchedWorktree(path: worktree.path, folder: folder, gitFolder: common) }
            guard let gitFolder = linked[folder] else { return nil }
            return WatchedWorktree(path: worktree.path, folder: folder, gitFolder: gitFolder)
        }
    }

    init(commonDirectory: String, watched: [WatchedWorktree]) {
        self.commonDirectory = commonDirectory
        worktrees = watched
    }

    /// The folders an FSEvents stream has to watch: the git directory and every
    /// worktree's folder, leaving out any that's inside another.
    var folders: [String] {
        let all = Set([commonDirectory] + worktrees.compactMap(\.folder)).sorted { $0.count < $1.count }
        var kept: [String] = []
        for folder in all where !kept.contains(where: { folder.hasPrefix($0 + "/") }) {
            kept.append(folder)
        }
        return kept
    }

    /// Folders in the git directory that change often and never matter: the
    /// objects that every commit and fetch writes, submodules' own git
    /// directories, Git LFS's files, and the cookies of git's file system
    /// monitor.
    var excluded: [String] {
        ["objects", "modules", "lfs", "fsmonitor--daemon"].map { commonDirectory + "/" + $0 }
    }

    /// The real path of a folder, so that it's spelled the way FSEvents spells
    /// what's in it. Foundation's `resolvingSymlinksInPath()` leaves out
    /// `/private`, so it can't be used for this.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// A path in a worktree that changed, which matters unless git ignores it.
struct ChangedPath: Sendable, Hashable {
    /// The path from the worktree's folder, with `/` between folders.
    var path: String
    var isFolder: Bool
}

/// The paths of one batch from FSEvents, sorted by what they affect. Paths in
/// worktrees are kept apart, because whether they matter depends on whether git
/// ignores them, which takes running git to find out.
struct SortedPaths: Sendable, Hashable {
    var changes = RepositoryChanges(number: 0)
    /// Paths in each worktree, by the worktree's path, for the worktrees that
    /// aren't in `changes.files` already.
    var candidates: [String: Set<ChangedPath>] = [:]
    /// The worktrees whose rules for what git ignores may have changed, by
    /// their paths, or nil when every worktree's may have.
    var ignoreRules: Set<String>? = []

    var isEmpty: Bool { changes.isEmpty && candidates.isEmpty && ignoreRules?.isEmpty == true }

    init(_ events: [FolderEvent], in layout: WatchedLayout) {
        let common = layout.commonDirectory
        // Deepest first, so that a worktree inside another worktree's folder, as
        // Claude Code makes them, gets what's in it.
        let holders = layout.worktrees.filter { $0.folder != nil }.sorted { $0.folder!.count > $1.folder!.count }
        for event in events where !event.onlyAttributes {
            var path = event.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if path == common || path.hasPrefix(common + "/") {
                sortGitPath(Self.relative(path, to: common), event: event, in: layout)
            } else if let worktree = holders.first(where: { path == $0.folder! || path.hasPrefix($0.folder! + "/") }) {
                sortWorktreePath(Self.relative(path, to: worktree.folder!), event: event, in: worktree)
            } else if event.mustScan {
                // A folder above what's watched moved or a volume came or went.
                changeEverything(in: layout)
            }
        }
        for worktree in changes.files { candidates[worktree] = nil }
    }

    /// Sorts a path in the git directory, given from the directory.
    private mutating func sortGitPath(_ path: String, event: FolderEvent, in layout: WatchedLayout) {
        if event.mustScan {
            changeEverything(in: layout)
            return
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first else { return }
        // git writes a file under a name ending in `.lock` and renames it, and
        // the rename reports the file's own name too.
        if parts.last?.hasSuffix(".lock") == true { return }
        switch first {
        case "refs", "packed-refs", "reftable", "shallow":
            changes.refs = true
        case "config":
            changes.refs = true
            changes.config = true
            // `core.excludesFile` can change what git ignores.
            ignoreRules = nil
        case "info":
            if parts.count == 2, parts[1] == "exclude" || parts[1] == "sparse-checkout" {
                ignoreRules = nil
                for worktree in layout.worktrees where worktree.folder != nil {
                    changes.files.insert(worktree.path)
                }
            }
        case "worktrees":
            guard parts.count >= 3 else {
                changes.worktreeList = true
                return
            }
            let gitFolder = layout.commonDirectory + "/worktrees/" + parts[1]
            guard let worktree = layout.worktrees.first(where: { $0.gitFolder == gitFolder }) else {
                // One that's being made, which the list of worktrees will have.
                changes.worktreeList = true
                return
            }
            switch parts[2] {
            case "gitdir", "locked", "prunable":
                changes.worktreeList = true
            default:
                sortOwnGitPath(parts[2...], of: worktree)
            }
        default:
            guard let main = layout.worktrees.first(where: { $0.gitFolder == layout.commonDirectory }) else { return }
            sortOwnGitPath(parts[...], of: main)
        }
    }

    /// Sorts a path in the folder of the git directory that a worktree has to
    /// itself, given from that folder.
    private mutating func sortOwnGitPath(_ parts: ArraySlice<Substring>, of worktree: WatchedWorktree) {
        guard let first = parts.first else { return }
        switch first {
        case "HEAD":
            changes.heads.insert(worktree.path)
            // A bare repository's history starts from its `HEAD`, and it has no files.
            if worktree.folder == nil { changes.refs = true } else { changes.files.insert(worktree.path) }
        case "index":
            guard worktree.folder != nil else { return }
            changes.files.insert(worktree.path)
            // A file that `git add --force` added inside an ignored folder
            // matters from now on.
            ignoreRules?.insert(worktree.path)
        case "MERGE_HEAD", "MERGE_MSG", "REBASE_HEAD", "REVERT_HEAD", "CHERRY_PICK_HEAD", "rebase-merge", "rebase-apply", "sequencer":
            // What it's stuck partway through, which its row says.
            guard worktree.folder != nil else { return }
            changes.files.insert(worktree.path)
        default:
            break
        }
    }

    /// Sorts a path in a worktree's folder, given from the folder.
    private mutating func sortWorktreePath(_ path: String, event: FolderEvent, in worktree: WatchedWorktree) {
        if event.mustScan || path.isEmpty {
            changes.files.insert(worktree.path)
            ignoreRules?.insert(worktree.path)
            if event.mustScan { changes.worktreeList = true }
            return
        }
        let parts = path.split(separator: "/")
        // A linked worktree's `.git` file, or what's in a repository or a
        // submodule inside the worktree, neither of which changes what git
        // lists for it.
        if parts.contains(".git") { return }
        if parts.last == ".gitignore" { ignoreRules?.insert(worktree.path) }
        candidates[worktree.path, default: []].insert(ChangedPath(path: path, isFolder: event.isFolder))
    }

    /// A path from a folder that holds it, or empty for the folder itself.
    private static func relative(_ path: String, to folder: String) -> String {
        String(path.dropFirst(folder.count).drop { $0 == "/" })
    }

    /// Something may have changed anywhere in the repository.
    private mutating func changeEverything(in layout: WatchedLayout) {
        changes.refs = true
        changes.config = true
        changes.worktreeList = true
        ignoreRules = nil
        for worktree in layout.worktrees {
            changes.heads.insert(worktree.path)
            if worktree.folder != nil { changes.files.insert(worktree.path) }
        }
    }
}

