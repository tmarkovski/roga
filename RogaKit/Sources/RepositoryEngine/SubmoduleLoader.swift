import Foundation
import GitCore
import GitRunner

/// Reads a submodule's own repository, from the copy checked out in a worktree,
/// and updates that copy when someone asks (decision 75).
///
/// The reads change nothing, and they run with `--no-optional-locks`, as
/// `GitCommand` does by default. They run for rows that are already showing, so
/// listing a worktree's files takes no longer than it did. Like status, they
/// never download anything, because the rows are read without anyone asking.
enum SubmoduleLoader {
    /// The most commits the diff panel lists on each side of a submodule's row.
    static let commitLimit = 500
    /// How many submodules are read at once, so that a list with dozens of them
    /// doesn't start dozens of git processes together.
    static let readsAtOnce = 4

    /// A submodule's checkout in a worktree.
    struct Checkout {
        var folder: String
        /// The commit that's checked out, or nil before the submodule's first one.
        var head: ObjectID?
    }

    /// The two commits a row compares. Either is nil when the submodule isn't
    /// there on that side.
    struct Sides {
        var from: ObjectID?
        var to: ObjectID?
        /// Whether `to` is the commit checked out rather than one that's recorded.
        var comparesCheckout: Bool
    }

    /// Finds a submodule's checkout in a worktree, or nil when it isn't checked
    /// out there.
    ///
    /// A submodule that was never checked out is an empty folder, and git run
    /// there answers for the repository above it, which is the parent. So this
    /// looks for the folder's own `.git` first, and then asks git where the
    /// folder is in its repository, which is nowhere when it's the top of one.
    static func checkout(of path: String, in worktree: String, git: Git) async throws -> Checkout? {
        let folder = (worktree as NSString).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(".git")) else { return nil }
        var command = inside(folder, "rev-parse", "--show-prefix", "HEAD^{commit}")
        // git prints the prefix and then exits with 128 when there's no commit yet.
        command.successStatuses = [0, 128]
        let lines = try await git.run(command).text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, lines[0].isEmpty else { return nil }
        return Checkout(folder: folder, head: ObjectID(hex: lines[1]))
    }

    /// The two commits a file's row compares, given the commit checked out.
    static func sides(of file: DiffFile, comparingCheckout: Bool, head: ObjectID?) -> Sides {
        let from = file.oldMode == DiffFile.submoduleMode ? file.oldID : nil
        guard file.newMode == DiffFile.submoduleMode else { return Sides(from: from, to: nil, comparesCheckout: false) }
        return comparingCheckout
            ? Sides(from: from, to: head, comparesCheckout: true)
            : Sides(from: from, to: file.newID, comparesCheckout: false)
    }

    /// Counts the commits between two of a submodule's commits. A row whose
    /// submodule is only on one side has none between.
    static func distance(_ sides: Sides, in checkout: Checkout, git: Git) async throws -> SubmoduleChange.Distance {
        guard let from = sides.from, let to = sides.to, from != to else { return .counted(ahead: 0, behind: 0) }
        var command = inside(checkout.folder, "rev-list", "--left-right", "--count", "\(from.hex)...\(to.hex)", "--")
        // git exits with 128 when the checkout hasn't got one of the commits.
        command.successStatuses = [0, 128]
        let result = try await git.run(command)
        let counts = result.text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard result.status == 0, counts.count == 2 else { return .commitMissing }
        return .counted(ahead: counts[1], behind: counts[0])
    }

    /// Reads what a submodule's row says: how its two commits stand, and for a
    /// row under Unstaged, how many uncommitted files its checkout has when
    /// status said it has some.
    @concurrent
    static func change(of file: DiffFile, comparingCheckout: Bool, in worktree: String, git: Git) async throws -> SubmoduleChange {
        var change = file.submodule ?? SubmoduleChange()
        guard let checkout = try await checkout(of: file.path, in: worktree, git: git) else {
            change.distance = .notCheckedOut
            return change
        }
        let sides = sides(of: file, comparingCheckout: comparingCheckout, head: checkout.head)
        change.distance = try await distance(sides, in: checkout, git: git)
        if sides.comparesCheckout, change.checkout?.hasFilesInside == true {
            change.filesInside = try await filesInside(checkout, git: git).count
        }
        return change
    }

    /// Reads what each of some submodules' rows says, a few at a time, by the
    /// submodule's path. One that can't be read is left out.
    @concurrent
    static func changes(of files: [DiffFile], comparingCheckout: Bool, in worktree: String, git: Git) async throws -> [String: SubmoduleChange] {
        try await withThrowingTaskGroup(of: (String, SubmoduleChange?).self) { group in
            var waiting = files.makeIterator()
            @Sendable func read(_ file: DiffFile) async throws -> (String, SubmoduleChange?) {
                do {
                    return (file.path, try await change(of: file, comparingCheckout: comparingCheckout, in: worktree, git: git))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return (file.path, nil)
                }
            }
            for _ in 0..<readsAtOnce {
                guard let file = waiting.next() else { break }
                group.addTask { try await read(file) }
            }
            var changes: [String: SubmoduleChange] = [:]
            while let (path, change) = try await group.next() {
                changes[path] = change
                if let file = waiting.next() {
                    group.addTask { try await read(file) }
                }
            }
            return changes
        }
    }

    /// Reads what the diff panel shows of a submodule's row.
    ///
    /// - Parameters:
    ///   - comparingCheckout: Whether the row is under Unstaged, which compares
    ///     what's recorded with the commit checked out.
    ///   - countsUnpushed: Whether to count the new commits that none of the
    ///     submodule's remote branches lead to, which matters before they're
    ///     pushed with the parent.
    ///   - worktree: The worktree to read the submodule in, or nil when there's
    ///     none, as in a bare repository.
    ///   - limit: The most commits to list on each side.
    @concurrent
    static func details(
        of file: DiffFile,
        comparingCheckout: Bool,
        countsUnpushed: Bool,
        in worktree: String?,
        limit: Int = commitLimit,
        git: Git
    ) async throws -> SubmoduleDetails {
        var checkout: Checkout?
        if let worktree { checkout = try await self.checkout(of: file.path, in: worktree, git: git) }
        let sides = sides(of: file, comparingCheckout: comparingCheckout, head: checkout?.head)
        var details = SubmoduleDetails(from: sides.from, to: sides.to, comparesCheckout: sides.comparesCheckout, distance: .notCheckedOut)
        guard let checkout else { return details }

        details.distance = try await distance(sides, in: checkout, git: git)
        if let from = sides.from, let to = sides.to, case .counted(let ahead, let behind) = details.distance {
            if ahead > 0 {
                details.added = try await commits(from: from, to: to, limit: limit, in: checkout, git: git)
                if countsUnpushed { details.unpushed = try await unpushedCount(from: from, to: to, in: checkout, git: git) }
            }
            if behind > 0 {
                details.removed = try await commits(from: to, to: from, limit: limit, in: checkout, git: git)
            }
        }
        if sides.comparesCheckout, file.submodule?.checkout?.hasFilesInside == true {
            details.filesInside = try await filesInside(checkout, git: git)
        }
        return details
    }

    /// Lists the commits that lead to `to` and not to `from`, newest first.
    ///
    /// `rev-list` is plumbing, so settings such as `log.showSignature` can't add
    /// lines. A subject and an author's name are each one line, so a line is a
    /// commit, with a zero byte between its parts.
    static func commits(from: ObjectID, to: ObjectID, limit: Int, in checkout: Checkout, git: Git) async throws -> [SubmoduleDetails.Commit] {
        let command = inside(
            checkout.folder,
            "rev-list", "--no-commit-header", "--format=%H%x00%an%x00%at%x00%s", "--encoding=UTF-8", "--max-count=\(limit)",
            "\(from.hex)..\(to.hex)", "--"
        )
        return try await git.run(command).output.split(separator: UInt8(ascii: "\n")).map { line in
            let parts = line.split(separator: 0, maxSplits: 3, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard parts.count == 4, let id = ObjectID(hex: parts[0]), let time = Int64(parts[2]) else {
                throw RepositoryError.unexpectedOutput(command, "A line isn't a commit: \(String(decoding: line, as: UTF8.self).debugDescription)")
            }
            return SubmoduleDetails.Commit(id: id, subject: parts[3], author: parts[1], time: time)
        }
    }

    /// Counts the commits that lead to `to` and not to `from` or to any of the
    /// submodule's remote branches, as of its last fetch.
    static func unpushedCount(from: ObjectID, to: ObjectID, in checkout: Checkout, git: Git) async throws -> Int? {
        let command = inside(checkout.folder, "rev-list", "--count", to.hex, "--not", from.hex, "--remotes", "--")
        return Int(try await git.text(command))
    }

    /// Lists a checkout's uncommitted files, each once, from A to Z.
    static func filesInside(_ checkout: Checkout, git: Git) async throws -> [SubmoduleDetails.File] {
        let changes = try await ChangesLoader.status(in: checkout.folder, git: git)
        var statuses: [String: DiffFile.Status] = [:]
        // A file that's staged and changed again says what's staged, because
        // that's the one that says a file is new.
        for file in changes.conflicted + changes.staged + changes.unstaged + changes.untracked where statuses[file.path] == nil {
            statuses[file.path] = file.status
        }
        return statuses.map { SubmoduleDetails.File(status: $0.value, path: $0.key) }.sorted { $0.path < $1.path }
    }

    /// Lists the submodules that staging everything in a worktree leaves out,
    /// because staging them would take commits away from what's recorded, with
    /// what was read about each (decision 75). It reads them now rather than
    /// going by what a panel last listed, since this is what decides.
    ///
    /// A worktree without a `.gitmodules` file has no submodule that could be
    /// updated, and isn't looked at, so that staging everything costs a
    /// repository without submodules nothing more.
    @concurrent
    static func leftOutOfStagingAll(in worktree: String, git: Git) async throws -> [DiffFile] {
        guard FileManager.default.fileExists(atPath: (worktree as NSString).appendingPathComponent(".gitmodules")) else { return [] }
        let unstaged = try await ChangesLoader.status(in: worktree, git: git).unstaged.filter { $0.submoduleStaging == .unknown }
        guard !unstaged.isEmpty else { return [] }
        let changes = try await changes(of: unstaged, comparingCheckout: true, in: worktree, git: git)
        return unstaged.compactMap { file in
            var file = file
            if let change = changes[file.path] { file.submodule = change }
            return file.submoduleStaging?.isLeftOutOfStagingAll == true ? file : nil
        }
    }

    /// Checks out the commit a worktree records for a submodule, fetching it
    /// first if the checkout hasn't got it, and checking the submodule out if
    /// it never was. Someone asked for this, so it can take locks, and it uses
    /// their credentials as a fetch they asked for does.
    static func update(_ path: String, in worktree: String, git: Git) async throws {
        var command = RemoteCommands.asked(updateArguments(path), in: worktree)
        // The path is a name rather than a pattern.
        command.environment["GIT_LITERAL_PATHSPECS"] = "1"
        _ = try await git.run(command)
    }

    static func updateArguments(_ path: String) -> [String] {
        ["submodule", "update", "--init", "--", path]
    }

    /// A read inside a submodule's checkout.
    private static func inside(_ folder: String, _ arguments: String...) -> GitCommand {
        var command = GitCommand(arguments, in: folder)
        command.environment["GIT_NO_LAZY_FETCH"] = "1"
        return command
    }
}
