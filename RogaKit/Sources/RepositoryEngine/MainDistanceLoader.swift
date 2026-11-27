import GitCore
import GitRunner

/// Works out how far a worktree's branch is from the main branch on the
/// remote, and whether merging that would conflict (decision 118). Nobody
/// waits for it, so it runs at utility priority, and like `BranchStatusLoader`
/// it may not start a download.
enum MainDistanceLoader {
    /// - Parameters:
    ///   - branch: The full name of the branch the worktree is on.
    ///   - previous: What this worked out last time, which comes back as it
    ///     was when neither `HEAD` nor the main branch has moved since, so
    ///     that a look at the worktree doesn't run the merge again.
    /// - Returns: How far it is, or nil when the repository has no main
    ///   branch, or `branch` is the main branch, which has its upstream to
    ///   compare with instead.
    @concurrent
    static func load(of branch: String, git: Git, in directory: String, after previous: MainDistance?) async throws -> MainDistance? {
        var list = GitCommand(["for-each-ref", "--format=" + MainBranchParser.format] + MainBranchParser.patterns, in: directory)
        list.priority = .utility
        let main: MainBranchParser.Main?
        do {
            main = try MainBranchParser.parse(try await git.run(list).output)
        } catch let error as ParseError {
            throw RepositoryError.unexpectedOutput(list, error.description)
        }
        guard let main, main.local != branch, main.base != branch else { return nil }

        // git exits with 128 when the main branch's ref is gone, as when a
        // remote's HEAD names a branch that was deleted.
        var commits = GitCommand("rev-parse", "--quiet", "--verify", "--end-of-options", main.base + "^{commit}", in: directory)
        commits.priority = .utility
        commits.successStatuses = [0, 1, 128]
        var head = GitCommand("rev-parse", "--verify", "HEAD^{commit}", in: directory)
        head.priority = .utility
        async let headText = git.text(head)
        let baseResult = try await git.run(commits)
        // Without the newline that ends git's line.
        let baseText = baseResult.text.split(separator: "\n").first.map(String.init) ?? ""
        guard baseResult.status == 0, let baseCommit = ObjectID(hex: baseText) else { return nil }
        let headOutput = try await headText
        guard let headCommit = ObjectID(hex: headOutput) else { throw RepositoryError.unexpectedOutput(head, headOutput) }
        if let previous, previous.base == main.base, previous.baseCommit == baseCommit, previous.head == headCommit {
            return previous
        }

        var counts = GitCommand("rev-list", "--left-right", "--count", "\(baseCommit.hex)...\(headCommit.hex)", "--", in: directory)
        counts.priority = .utility
        let numbers = try await git.text(counts).split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard numbers.count == 2 else { throw RepositoryError.unexpectedOutput(counts, numbers.map(String.init).joined(separator: " ")) }
        var distance = MainDistance(base: main.base, baseCommit: baseCommit, head: headCommit, ahead: numbers[1], behind: numbers[0])
        if distance.hasDiverged {
            distance.conflicts = try await conflicts(merging: baseCommit, into: headCommit, git: git, in: directory)
        }
        return distance
    }

    /// The files a merge would conflict in, from a merge that git tries
    /// without touching the worktree or the index. It does write the objects
    /// the merge would make to the repository, as any merge would, and
    /// they're unreachable, so `git gc` clears them in time.
    ///
    /// - Returns: The files, which are none when the merge would go cleanly,
    ///   or nil when git couldn't try, as in a partial clone that hasn't got
    ///   the files' contents.
    private static func conflicts(merging base: ObjectID, into head: ObjectID, git: Git, in directory: String) async throws -> [String]? {
        var merge = GitCommand("merge-tree", "--write-tree", "--name-only", "-z", "--no-messages", head.hex, base.hex, in: directory)
        merge.priority = .utility
        merge.environment["GIT_NO_LAZY_FETCH"] = "1"
        // 1 means the merge would conflict, and anything else that it
        // couldn't be tried.
        merge.successStatuses = [0, 1, 128]
        let result = try await git.run(merge)
        guard result.status == 0 || result.status == 1 else { return nil }
        do {
            return try MergeTreeParser.conflicts(in: result.output)
        } catch {
            throw RepositoryError.unexpectedOutput(merge, error.description)
        }
    }
}
