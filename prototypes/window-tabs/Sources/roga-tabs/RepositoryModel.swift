import Foundation
import Observation

nonisolated struct Commit: Identifiable, Hashable, Sendable {
    let id: String
    let shortHash: String
    let subject: String
    let author: String
    let date: String
    let refs: [String]
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

nonisolated struct Refs: Sendable {
    var branches: [String] = []
    var remotes: [String] = []
    var tags: [String] = []
}

@Observable
final class RepositoryModel {
    let root: URL
    var worktrees: [Worktree] = []
    var activeWorktree: String?
    var refs = Refs()
    var commits: [Commit] = []
    var selectedCommit: Commit.ID?
    var detail = ""
    var isLoading = true

    init(root: URL) {
        self.root = root
        activeWorktree = RepositoryURL.path(of: root)
    }

    var active: Worktree? { worktrees.first { $0.path == activeWorktree } }

    var title: String { worktrees.first?.name ?? root.lastPathComponent }

    var subtitle: String {
        guard let active else { return "" }
        return active.path == worktrees.first?.path ? active.branchLabel : "\(active.name) · \(active.branchLabel)"
    }

    /// A description for the tab's dot, or nil when every worktree is clean.
    var changeSummary: String? {
        let dirty = worktrees.filter { $0.changedFiles > 0 }
        guard !dirty.isEmpty else { return nil }
        return dirty.map { "\($0.name): \($0.changedFiles) changed" }.joined(separator: "\n")
    }

    func loadRepository() async {
        async let worktreeText = Git.run(["worktree", "list", "--porcelain", "-z"], in: root)
        async let branchText = Git.run(["for-each-ref", "--sort=-committerdate", "--format=%(refname)", "refs/heads"], in: root)
        async let remoteText = Git.run(["for-each-ref", "--format=%(refname)", "refs/remotes"], in: root)
        async let tagText = Git.run(["for-each-ref", "--sort=-creatordate", "--count=300", "--format=%(refname)", "refs/tags"], in: root)

        var trees = Parse.worktrees(await worktreeText)
        refs = Refs(
            branches: Parse.refs(await branchText, prefix: "refs/heads/"),
            remotes: Parse.refs(await remoteText, prefix: "refs/remotes/").filter { !$0.hasSuffix("/HEAD") },
            tags: Parse.refs(await tagText, prefix: "refs/tags/")
        )
        worktrees = trees

        let counts = await withTaskGroup(of: (String, Int).self) { group in
            for tree in trees {
                let path = tree.path
                group.addTask {
                    let status = await Git.run(["status", "--porcelain=v2", "-z"], in: URL(filePath: path))
                    return (path, Parse.changedFileCount(status))
                }
            }
            var counts: [String: Int] = [:]
            for await (path, count) in group { counts[path] = count }
            return counts
        }
        for index in trees.indices { trees[index].changedFiles = counts[trees[index].path] ?? 0 }
        worktrees = trees
    }

    func loadCommits() async {
        guard let activeWorktree else { return }
        isLoading = true
        let format = "--format=%H%x1f%h%x1f%s%x1f%an%x1f%ad%x1f%D%x1e"
        let date = "--date=format-local:%-d %b %Y, %H:%M"
        let text = await Git.run(["log", "-n", "500", format, date, "HEAD"], in: URL(filePath: activeWorktree))
        commits = Parse.commits(text)
        isLoading = false
    }

    func loadDetail() async {
        guard let selectedCommit, let activeWorktree else {
            detail = ""
            return
        }
        detail = await Git.run(["show", "--stat=100", "--format=fuller", selectedCommit], in: URL(filePath: activeWorktree))
    }
}

nonisolated enum Git {
    static let executable: String = {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    }()

    /// A quick stand-in for the real runner. The app will use posix_spawn (decision 5).
    @concurrent
    static func run(_ arguments: [String], in directory: URL) async -> String {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = ["-C", RepositoryURL.path(of: directory), "--no-optional-locks", "-c", "color.ui=never"] + arguments
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

    static func commits(_ text: String) -> [Commit] {
        text.split(separator: "\u{1e}").compactMap { record in
            let fields = record.drop { $0 == "\n" }.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 6 else { return nil }
            return Commit(
                id: String(fields[0]),
                shortHash: String(fields[1]),
                subject: String(fields[2]),
                author: String(fields[3]),
                date: String(fields[4]),
                refs: fields[5].isEmpty ? [] : fields[5].split(separator: ", ").map(String.init)
            )
        }
    }

    /// Counts entries in `git status --porcelain=v2 -z` output. A rename entry
    /// is followed by a separate field holding the original path.
    static func changedFileCount(_ text: String) -> Int {
        var count = 0
        var skipNext = false
        for field in text.split(separator: "\0") {
            if skipNext {
                skipNext = false
                continue
            }
            switch field.first {
            case "1", "u", "?": count += 1
            case "2": count += 1; skipNext = true
            default: break
            }
        }
        return count
    }
}
