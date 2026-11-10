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
        try await each(of: files, path: \.path) { file in
            try await change(of: file, comparingCheckout: comparingCheckout, in: worktree, git: git)
        }
    }

    /// Reads something about each of some submodules, a few at a time, by the
    /// submodule's path. One that can't be read is left out.
    private static func each<Item: Sendable, Value: Sendable>(
        of items: [Item],
        path: @escaping @Sendable (Item) -> String,
        _ read: @escaping @Sendable (Item) async throws -> Value
    ) async throws -> [String: Value] {
        try await withThrowingTaskGroup(of: (String, Value?).self) { group in
            var waiting = items.makeIterator()
            @Sendable func attempt(_ item: Item) async throws -> (String, Value?) {
                do {
                    return (path(item), try await read(item))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return (path(item), nil)
                }
            }
            for _ in 0..<readsAtOnce {
                guard let item = waiting.next() else { break }
                group.addTask { try await attempt(item) }
            }
            var values: [String: Value] = [:]
            while let (path, value) = try await group.next() {
                values[path] = value
                if let item = waiting.next() {
                    group.addTask { try await attempt(item) }
                }
            }
            return values
        }
    }

    // MARK: The refs panel's section

    /// Lists a worktree's submodules, from A to Z by path, each with the commit
    /// the worktree records for it, the commit that's checked out and where
    /// it's from (decision 75). How far the two commits are apart, and what the
    /// checkout has uncommitted, is for `standings` to read afterward, so that
    /// the list shows without waiting for it.
    ///
    /// A submodule is what `git submodule` means by one: a path that the
    /// worktree's `.gitmodules` names and its index records a commit for. So a
    /// worktree without that file isn't looked at, and one with it runs `git
    /// config` for the names, `git ls-files --stage` for only those paths, and
    /// `git rev-parse` in each checkout, a few at a time. None of that grows
    /// with the repository's size.
    ///
    /// Its address is the URL in git's own settings, where `git submodule init`
    /// puts it whole, and otherwise the one in `.gitmodules`, which can be
    /// relative to the parent's remote.
    @concurrent
    static func list(in worktree: String, git: Git) async throws -> [Submodule] {
        guard FileManager.default.fileExists(atPath: (worktree as NSString).appendingPathComponent(".gitmodules")) else { return [] }
        var named = GitCommand(SubmoduleConfigParser.moduleArguments, in: worktree)
        named.successStatuses = [0, 1]
        var settings = GitCommand(SubmoduleConfigParser.urlArguments, in: worktree)
        settings.successStatuses = [0, 1]
        async let set = git.run(settings).output

        // The index has a submodule's path without a slash at its end.
        var modules = try parse(named, try await git.run(named).output, with: SubmoduleConfigParser.parse).compactMapValues { module in
            module.path.map { path in
                var path = path[...]
                while path.hasSuffix("/") { path = path.dropLast() }
                return SubmoduleConfigParser.Module(path: String(path), url: module.url)
            }
        }
        let urls = try parse(settings, try await set, with: SubmoduleConfigParser.parse)
        for name in modules.keys {
            if let url = urls[name]?.url { modules[name]?.url = url }
        }
        let paths = modules.values.compactMap(\.path)
        guard !paths.isEmpty else { return [] }

        var index = GitCommand(SubmoduleListParser.arguments + ["--"] + paths, in: worktree)
        // Each path is a name rather than a pattern.
        index.environment["GIT_LITERAL_PATHSPECS"] = "1"
        let recorded = try parse(index, try await git.run(index).output, with: SubmoduleListParser.recorded)
        let listed = modules.compactMap { name, module -> Submodule? in
            guard let path = module.path, let commit = recorded[path] else { return nil }
            return Submodule(name: name, path: path, address: module.url.map(RemoteAddress.shown), recorded: commit, checkedOut: nil)
        }
        // One that can't be read is listed as one that isn't checked out.
        let heads = try await each(of: listed, path: \.path) { submodule in
            try await checkout(of: submodule.path, in: worktree, git: git)?.head
        }
        return listed
            .map { submodule in
                let head = heads[submodule.path] ?? nil
                return Submodule(name: submodule.name, path: submodule.path, address: submodule.address, recorded: submodule.recorded, checkedOut: head)
            }
            .sorted { $0.path.compare($1.path, options: [.numeric, .caseInsensitive]) == .orderedAscending }
    }

    /// Reads how each listed submodule's checkout stands against what's
    /// recorded, a few at a time, by the submodule's path: how far apart the
    /// two commits are, and how many uncommitted files the checkout has. One
    /// that isn't checked out has nothing to read and is left out, and so is
    /// one that can't be read.
    ///
    /// It's what `change(of:comparingCheckout:in:git:)` reads for a row under
    /// Unstaged. There, the parent's `git status` has already said whether a
    /// checkout has files of its own. A listed submodule may have no such row,
    /// so this asks each checkout itself, with a `git status` there.
    @concurrent
    static func standings(of submodules: [Submodule], in worktree: String, git: Git) async throws -> [String: SubmoduleChange] {
        try await each(of: submodules.filter { $0.checkedOut != nil }, path: \.path) { submodule in
            try await standing(of: submodule, in: worktree, git: git)
        }
    }

    /// Reads how one listed submodule's checkout stands, from the commit it was
    /// listed with, so that the row's hash and its words are about the same
    /// commit.
    static func standing(of submodule: Submodule, in worktree: String, git: Git) async throws -> SubmoduleChange {
        guard let head = submodule.checkedOut else { return Submodule.unread(recorded: submodule.recorded, checkedOut: nil) }
        let checkout = Checkout(folder: (worktree as NSString).appendingPathComponent(submodule.path), head: head)
        let sides = Sides(from: submodule.recorded, to: head, comparesCheckout: true)
        let distance = try await distance(sides, in: checkout, git: git)
        let files = try await filesInside(checkout, git: git)
        var said: SubmoduleChange.Checkout = head == submodule.recorded ? [] : [.commitChanged]
        if files.contains(where: { $0.status == .untracked }) { said.insert(.untrackedFiles) }
        if files.contains(where: { $0.status != .untracked }) { said.insert(.modifiedFiles) }
        return SubmoduleChange(checkout: said, distance: distance, filesInside: files.isEmpty ? nil : files.count)
    }

    private static func parse<Result>(_ command: GitCommand, _ output: [UInt8], with parser: ([UInt8]) throws(ParseError) -> Result) throws -> Result {
        do {
            return try parser(output)
        } catch {
            throw RepositoryError.unexpectedOutput(command, error.description)
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
