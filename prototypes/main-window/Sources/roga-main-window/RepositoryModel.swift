import Foundation
import Observation

nonisolated struct Commit: Identifiable, Hashable, Sendable {
    let id: String
    let shortHash: String
    let subject: String
    let author: String
    let date: String
    let refs: [String]
    let parentCount: Int
}

nonisolated struct Worktree: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let head: String
    let branch: String?
    var changedFiles = 0

    var name: String { (path as NSString).lastPathComponent }
    var branchLabel: String { branch ?? "detached at \(head.prefix(7))" }
}

nonisolated struct Stash: Identifiable, Hashable, Sendable {
    let id: String
    let message: String
}

nonisolated struct Refs: Sendable {
    var branches: [String] = []
    var remotes: [String] = []
    var tags: [String] = []
    var stashes: [Stash] = []
}

nonisolated struct StatusEntry: Identifiable, Hashable, Sendable {
    var id: String { path }
    /// The two-letter XY code from `git status --porcelain=v2`, or "??" for untracked files.
    let code: String
    let path: String

    /// One letter for display: the worktree's change if there is one, otherwise the staged one.
    var letter: String {
        if code == "??" { return "U" }
        let letters = Array(code)
        let worktree = letters.count > 1 ? letters[1] : "."
        return String(worktree != "." ? worktree : (letters.first ?? "M"))
    }
}

nonisolated struct CommitDetails: Sendable, Equatable {
    let hash: String
    let author: String
    let email: String
    let date: String
    let parents: [String]
    let subject: String
    let body: String
}

nonisolated struct ChangedFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    /// The path as numstat prints it, which shows renames as `old => new`.
    let path: String
    /// The file's current path, used to ask for its diff.
    let diffPath: String
    let added: Int?
    let deleted: Int?
}

nonisolated struct DiffLine: Identifiable, Sendable {
    enum Kind: Sendable { case header, hunk, added, removed, context }
    let id: Int
    let kind: Kind
    let text: String
}

enum ContentMode: Hashable {
    case history
    case changes
}

struct DiffKey: Hashable {
    let mode: ContentMode
    let commit: String?
    let file: String?
    let change: String?
}

@Observable
final class RepositoryModel: Identifiable {
    let id = UUID()
    let root: URL
    var worktrees: [Worktree] = []
    var activeWorktree: String?
    var refs = Refs()
    var commits: [Commit] = []
    var changes: [StatusEntry] = []
    var mode = ContentMode.history
    var selectedCommit: Commit.ID?
    var details: CommitDetails?
    var files: [ChangedFile] = []
    var selectedFile: ChangedFile.ID?
    var selectedChange: StatusEntry.ID?
    var diff: [DiffLine] = []
    var isLoadingHistory = true

    init(root: URL, worktree: String? = nil) {
        self.root = root
        activeWorktree = worktree ?? RepositoryURL.path(of: root)
    }

    var mainWorktree: Worktree? { worktrees.first }
    var active: Worktree? { worktrees.first { $0.path == activeWorktree } }
    var name: String { mainWorktree?.name ?? root.lastPathComponent }

    var tabTitle: String {
        guard let active, let main = mainWorktree, active.path != main.path else { return name }
        return "\(name) · \(active.name)"
    }

    var hasChanges: Bool { worktrees.contains { $0.changedFiles > 0 } }

    var changeSummary: String? {
        let dirty = worktrees.filter { $0.changedFiles > 0 }
        guard !dirty.isEmpty else { return nil }
        return dirty.map { "\($0.name): \($0.changedFiles) uncommitted" }.joined(separator: "\n")
    }

    var diffKey: DiffKey {
        DiffKey(mode: mode, commit: selectedCommit, file: selectedFile, change: selectedChange)
    }

    private var activeURL: URL? { activeWorktree.map { URL(filePath: $0) } }

    func loadRepository() async {
        async let worktreeText = Git.run(["worktree", "list", "--porcelain", "-z"], in: root)
        async let branchText = Git.run(["for-each-ref", "--sort=-committerdate", "--format=%(refname)", "refs/heads"], in: root)
        async let remoteText = Git.run(["for-each-ref", "--format=%(refname)", "refs/remotes"], in: root)
        async let tagText = Git.run(["for-each-ref", "--sort=-creatordate", "--count=300", "--format=%(refname)", "refs/tags"], in: root)
        async let stashText = Git.run(["stash", "list", "--format=%gd%x1f%s"], in: root)

        var trees = Parse.worktrees(await worktreeText)
        refs = Refs(
            branches: Parse.refs(await branchText, prefix: "refs/heads/"),
            remotes: Parse.refs(await remoteText, prefix: "refs/remotes/").filter { !$0.hasSuffix("/HEAD") },
            tags: Parse.refs(await tagText, prefix: "refs/tags/"),
            stashes: Parse.stashes(await stashText)
        )
        worktrees = trees

        let counts = await withTaskGroup(of: (String, Int).self) { group in
            for tree in trees {
                let path = tree.path
                group.addTask {
                    let status = await Git.run(["status", "--porcelain=v2", "-z"], in: URL(filePath: path))
                    return (path, Parse.statusEntries(status).count)
                }
            }
            var counts: [String: Int] = [:]
            for await (path, count) in group { counts[path] = count }
            return counts
        }
        for index in trees.indices { trees[index].changedFiles = counts[trees[index].path] ?? 0 }
        worktrees = trees
    }

    func loadWorktree() async {
        guard let url = activeURL else { return }
        isLoadingHistory = true
        let format = "--format=%H%x1f%h%x1f%s%x1f%an%x1f%ad%x1f%D%x1f%P%x1e"
        let date = "--date=format-local:%-d %b %Y, %H:%M"
        async let logText = Git.run(["log", "-n", "500", format, date, "HEAD"], in: url)
        async let statusText = Git.run(["status", "--porcelain=v2", "-z"], in: url)
        commits = Parse.commits(await logText)
        changes = Parse.statusEntries(await statusText)
        isLoadingHistory = false
        if !commits.contains(where: { $0.id == selectedCommit }) { selectedCommit = commits.first?.id }
        if !changes.contains(where: { $0.id == selectedChange }) { selectedChange = changes.first?.id }
    }

    func loadDetails() async {
        guard let selectedCommit, let url = activeURL else {
            details = nil
            files = []
            return
        }
        let date = "--date=format-local:%-d %B %Y at %H:%M"
        async let metaText = Git.run(["show", "-s", "--format=%H%x1f%an%x1f%ae%x1f%ad%x1f%P%x1f%s%x1f%b", date, selectedCommit], in: url)
        async let numstatText = Git.run(["show", "--no-ext-diff", "--numstat", "--format=", "-M", "--diff-merges=first-parent", selectedCommit], in: url)
        details = Parse.details(await metaText)
        files = Parse.numstat(await numstatText)
        selectedFile = files.first?.id
    }

    func loadDiff() async {
        guard let url = activeURL else { return }
        switch mode {
        case .history:
            guard let selectedCommit, let file = files.first(where: { $0.id == selectedFile }) else {
                diff = []
                return
            }
            let text = await Git.run(["show", "--no-ext-diff", "--format=", "-M", "--diff-merges=first-parent", selectedCommit, "--", file.diffPath], in: url)
            diff = Parse.diffLines(text)
        case .changes:
            guard let entry = changes.first(where: { $0.id == selectedChange }) else {
                diff = []
                return
            }
            let arguments = entry.code == "??"
                ? ["diff", "--no-ext-diff", "--no-index", "--", "/dev/null", entry.path]
                : ["diff", "--no-ext-diff", "HEAD", "--", entry.path]
            diff = Parse.diffLines(await Git.run(arguments, in: url))
        }
    }

    func selectAdjacentCommit(_ offset: Int) {
        guard let index = commits.firstIndex(where: { $0.id == selectedCommit }) else {
            selectedCommit = commits.first?.id
            return
        }
        selectedCommit = commits[max(0, min(commits.count - 1, index + offset))].id
    }

    func selectAdjacentChange(_ offset: Int) {
        guard let index = changes.firstIndex(where: { $0.id == selectedChange }) else {
            selectedChange = changes.first?.id
            return
        }
        selectedChange = changes[max(0, min(changes.count - 1, index + offset))].id
    }
}

nonisolated enum Git {
    static let executable: String = {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    }()

    /// A quick stand-in for the real runner, which will use posix_spawn (decision 5).
    @concurrent
    static func run(_ arguments: [String], in directory: URL) async -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = ["-C", RepositoryURL.path(of: directory), "--no-optional-locks",
                             "-c", "color.ui=never", "-c", "core.quotePath=false"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

nonisolated enum Parse {
    static func worktrees(_ text: String) -> [Worktree] {
        var result: [Worktree] = []
        var path: String?
        var head = ""
        var branch: String?
        for field in text.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let path { result.append(Worktree(path: path, head: head, branch: branch)) }
                path = nil
                head = ""
                branch = nil
            } else if field.hasPrefix("worktree ") {
                path = String(field.dropFirst("worktree ".count))
            } else if field.hasPrefix("HEAD ") {
                head = String(field.dropFirst("HEAD ".count))
            } else if field.hasPrefix("branch ") {
                let ref = field.dropFirst("branch ".count)
                branch = String(ref.hasPrefix("refs/heads/") ? ref.dropFirst("refs/heads/".count) : ref)
            }
        }
        return result
    }

    static func refs(_ text: String, prefix: String) -> [String] {
        text.split(separator: "\n").map { line in
            String(line.hasPrefix(prefix) ? line.dropFirst(prefix.count) : line)
        }
    }

    static func stashes(_ text: String) -> [Stash] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            return Stash(id: String(fields[0]), message: String(fields[1]))
        }
    }

    static func commits(_ text: String) -> [Commit] {
        text.split(separator: "\u{1e}").compactMap { record in
            let fields = record.drop { $0 == "\n" }.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 7 else { return nil }
            return Commit(
                id: String(fields[0]),
                shortHash: String(fields[1]),
                subject: String(fields[2]),
                author: String(fields[3]),
                date: String(fields[4]),
                refs: fields[5].isEmpty ? [] : fields[5].split(separator: ", ").map(String.init),
                parentCount: fields[6].split(separator: " ").count
            )
        }
    }

    static func details(_ text: String) -> CommitDetails? {
        let fields = text.split(separator: "\u{1f}", maxSplits: 6, omittingEmptySubsequences: false)
        guard fields.count == 7 else { return nil }
        return CommitDetails(
            hash: String(fields[0]),
            author: String(fields[1]),
            email: String(fields[2]),
            date: String(fields[3]),
            parents: fields[4].split(separator: " ").map(String.init),
            subject: String(fields[5]),
            body: fields[6].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func numstat(_ text: String) -> [ChangedFile] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            let path = String(fields[2])
            return ChangedFile(path: path, diffPath: newPath(path), added: Int(fields[0]), deleted: Int(fields[1]))
        }
    }

    /// Turns numstat's rename notation, `dir/{old => new}/file` or `old => new`, into the new path.
    static func newPath(_ path: String) -> String {
        guard path.contains(" => ") else { return path }
        if let open = path.firstIndex(of: "{"), let close = path.lastIndex(of: "}"), open < close {
            let inner = path[path.index(after: open)..<close]
            let replacement = inner.components(separatedBy: " => ").last ?? ""
            let joined = String(path[..<open]) + replacement + String(path[path.index(after: close)...])
            return joined.replacingOccurrences(of: "//", with: "/")
        }
        return path.components(separatedBy: " => ").last ?? path
    }

    /// Reads `git status --porcelain=v2 -z`. A rename entry is followed by a
    /// separate field that holds the original path.
    static func statusEntries(_ text: String) -> [StatusEntry] {
        var entries: [StatusEntry] = []
        var fields = text.split(separator: "\0").makeIterator()
        while let field = fields.next() {
            switch field.first {
            case "1":
                let parts = field.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                if parts.count == 9 { entries.append(StatusEntry(code: String(parts[1]), path: String(parts[8]))) }
            case "2":
                let parts = field.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                if parts.count == 10 { entries.append(StatusEntry(code: String(parts[1]), path: String(parts[9]))) }
                _ = fields.next()
            case "u":
                let parts = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if parts.count == 11 { entries.append(StatusEntry(code: String(parts[1]), path: String(parts[10]))) }
            case "?":
                entries.append(StatusEntry(code: "??", path: String(field.dropFirst(2))))
            default:
                break
            }
        }
        return entries
    }

    static func diffLines(_ text: String, limit: Int = 6000) -> [DiffLine] {
        var lines: [DiffLine] = []
        var inHunk = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(limit) {
            let kind: DiffLine.Kind
            if raw.hasPrefix("diff --git") {
                // The panel's header already names the file, so skip git's own file header.
                inHunk = false
                continue
            } else if !inHunk && (raw.hasPrefix("index ") || raw.hasPrefix("--- ") || raw.hasPrefix("+++ ")) {
                continue
            } else if raw.hasPrefix("@@") {
                inHunk = true
                kind = .hunk
            } else if !inHunk {
                kind = .header
            } else if raw.hasPrefix("+") {
                kind = .added
            } else if raw.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .context
            }
            lines.append(DiffLine(id: lines.count, kind: kind, text: raw.replacingOccurrences(of: "\t", with: "    ")))
        }
        if lines.last?.text.isEmpty == true { lines.removeLast() }
        return lines
    }
}
