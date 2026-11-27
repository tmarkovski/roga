import GitCore
import GitRunner

/// What deleting a branch would come to, which says whether to ask first.
public struct BranchDeletion: Sendable, Hashable {
    /// Where the branch is, which says how it's deleted.
    public enum Place: Sendable, Hashable {
        case local
        /// On a remote. This has the remote's name and its name for the branch.
        case remote(String, branch: String)
        /// A remote branch whose remote isn't configured any more, so this
        /// repository's copy is all there is to delete.
        case leftBehind
    }

    /// The branch's full name.
    public var ref: String
    public var place: Place
    /// Whether a worktree has the branch checked out, which git refuses to
    /// delete.
    public var isCheckedOut: Bool
    /// How many commits only this branch leads to, rather than another branch,
    /// a tag or a worktree's `HEAD`.
    public var lostCount: Int
    /// The newest of those commits.
    public var lost: [ObjectID]

    public var shortName: String { Ref.shortName(ref) }

    /// Whether someone should agree to this first. Deleting from a remote affects
    /// everyone who uses it, and anything else is only worth asking about when it
    /// loses commits. A branch that git will refuse to delete needs no question.
    public var asksFirst: Bool {
        if isCheckedOut { return false }
        if case .remote = place { return true }
        return lostCount > 0
    }

    /// Whether deleting it changes a remote, which everyone who uses that remote sees.
    public var reachesRemote: Bool {
        if case .remote = place { return true }
        return false
    }

    /// What deleting it runs, which the dialog shows. `-D` is there because the
    /// commits have been counted: `-d` only looks at `HEAD` and the upstream, so it
    /// refuses a branch whose commits are safe on another branch.
    public var arguments: [String] {
        switch place {
        case .local: ["branch", "-D"] + Self.safe(shortName)
        case .remote(let remote, let branch): ["push", "--delete", remote, Ref.branchPrefix + branch]
        case .leftBehind: Self.deletingCopy(of: shortName)
        }
    }

    /// Finds out what deleting a branch would come to.
    ///
    /// - Parameters:
    ///   - name: The full name of the branch or remote branch.
    ///   - limit: The most commits to list.
    static func prepare(ref name: String, limit: Int, in worktree: String, worktrees: [Worktree], git: Git) async throws -> BranchDeletion {
        let lost = try await LostCommits.find(
            from: [name],
            leaving: try await LostCommits.leaving([name], in: worktree, git: git),
            keeping: ["--all"],
            limit: limit,
            in: worktree,
            git: git
        )
        return BranchDeletion(
            ref: name,
            place: try await place(of: name, in: worktree, git: git),
            isCheckedOut: worktrees.contains { $0.branch == name },
            lostCount: lost.count,
            lost: lost.newest
        )
    }

    /// Says where a branch or remote branch is, which says how it's deleted.
    static func place(of name: String, in directory: String, git: Git) async throws -> Place {
        guard name.hasPrefix(Ref.remoteBranchPrefix) else { return .local }
        return place(of: name, amongRemotes: Set(try await RefDetailsLoader.remoteAddresses(git: git, in: directory).keys))
    }

    /// The same, for someone who has already listed the remotes.
    static func place(of name: String, amongRemotes remotes: Set<String>) -> Place {
        guard name.hasPrefix(Ref.remoteBranchPrefix) else { return .local }
        let short = Ref.shortName(name)
        let remote = RemoteDetails.remoteName(of: short, amongLongestFirst: remotes.sorted { $0.count > $1.count })
        return remotes.contains(remote) ? .remote(remote, branch: String(short.dropFirst(remote.count + 1))) : .leftBehind
    }

    /// Deletes the branch. When a remote no longer has it, because someone else
    /// deleted it first, git refuses and leaves this repository's copy until a
    /// fetch prunes it, so that copy is what's left to delete.
    func run(in worktree: String, git: Git) async throws {
        do {
            _ = try await git.run(RemoteCommands.asked(arguments, in: worktree))
        } catch {
            guard case .remote(let remote, let branch) = place, await Self.isGone(branch, from: remote, in: worktree, git: git) else { throw error }
            _ = try await git.run(RemoteCommands.asked(Self.deletingCopy(of: shortName), in: worktree))
        }
    }

    /// Whether a remote answers that it has no such branch, rather than not
    /// answering, which `git ls-remote --exit-code` tells apart by its status.
    private static func isGone(_ branch: String, from remote: String, in worktree: String, git: Git) async -> Bool {
        var command = RemoteCommands.asked(["ls-remote", "--exit-code", remote, Ref.branchPrefix + branch], in: worktree)
        command.successStatuses = [0, 2]
        return (try? await git.run(command).status) == 2
    }

    /// `-r` deletes this repository's copy of a remote branch, whatever `-d` would
    /// say about its commits.
    private static func deletingCopy(of shortName: String) -> [String] {
        ["branch", "-d", "-r"] + safe(shortName)
    }

    /// A ref can be named like an option, even if git won't create a branch with
    /// such a name. Only those get `--end-of-options`, so that the dialog shows the
    /// command as someone would type it.
    private static func safe(_ shortName: String) -> [String] {
        shortName.hasPrefix("-") ? ["--end-of-options", shortName] : [shortName]
    }
}

/// What deleting some of the branches on one commit would come to, when someone can
/// choose which.
///
/// Those branches all lead to the same commits, so any one that stays keeps all of
/// them. That leaves only one count to work out, however many branches there are:
/// what goes when every one of them does.
public struct CommitBranchesDeletion: Sendable, Hashable {
    /// The branches that git can delete, in the order they were asked about. With
    /// others to choose from, each one alone loses nothing. Alone on the commit, it
    /// has the same count and commits as this does.
    public var branches: [BranchDeletion]
    /// The branches that stay because a worktree has them checked out, which git
    /// refuses to delete.
    public var checkedOut: [BranchDeletion]
    /// The main branch, when it was among the names and the deletion keeps it,
    /// as deleting a folder of branches or the ones picked in the refs panel
    /// does (decision 121).
    public var main: BranchDeletion?
    /// How many commits go when every one of `branches` does.
    public var lostCount: Int
    /// The newest of those commits.
    public var lost: [ObjectID]
    /// Those commits counted by which of `branches` lead to them, by the
    /// branches' full names. A commit goes only when every branch that leads to
    /// it goes. On one commit, every branch leads to all of them, so any one that
    /// stays keeps them all.
    public var lostBy: [Set<String>: Int]

    /// How many commits go when the branches named go and the rest of
    /// `branches` stay.
    ///
    /// - Parameter names: Full names, which can include others that aren't
    ///   among `branches`.
    public func lostCount(deleting names: Set<String>) -> Int {
        lostBy.reduce(0) { total, group in group.key.isSubset(of: names) ? total + group.value : total }
    }

    /// How many commits only this one of `branches` leads to, which go with it
    /// whatever happens to the rest.
    public func lostCount(onlyBy name: String) -> Int {
        lostBy[[name]] ?? 0
    }

    /// How many of the commits that go when every one of `branches` does this
    /// branch leads to along with others among them, which go if they all do.
    public func lostCount(sharedBy name: String) -> Int {
        lostBy.reduce(0) { total, group in group.key.count > 1 && group.key.contains(name) ? total + group.value : total }
    }

    /// - Parameters:
    ///   - names: The full names of the branches and remote branches on the commit.
    ///   - commit: The commit they were on when someone asked. Any that have moved
    ///     since, as an agent's branch may have, are left out: they're no longer what
    ///     was asked about, and counting them as if they were here would hide
    ///     whatever they moved to. Nil for branches on different commits, as the
    ///     merged branches the refs panel deletes are, which are taken wherever
    ///     they are now, leaving out any that are gone.
    ///   - keepingMain: Whether the main branch stays when it's among them, in
    ///     `main` rather than `branches`.
    ///   - limit: The most commits to list.
    static func prepare(
        branches names: [String],
        on commit: ObjectID?,
        keepingMain: Bool = false,
        limit: Int,
        in worktree: String,
        worktrees: [Worktree],
        git: Git
    ) async throws -> CommitBranchesDeletion {
        async let refList = RefsLoader.load(git: git, in: worktree)
        async let remoteAddresses = RefDetailsLoader.remoteAddresses(git: git, in: worktree)
        let list = try await refList
        let refs = list.refs
        let remotes = Set(try await remoteAddresses.keys)
        let here = Set(refs.filter { ref in commit.map { ref.peeled == $0 } ?? true }.map(\.name))

        let all = names.filter(here.contains).map { name in
            BranchDeletion(
                ref: name,
                place: BranchDeletion.place(of: name, amongRemotes: remotes),
                isCheckedOut: worktrees.contains { $0.branch == name },
                lostCount: 0,
                lost: []
            )
        }
        var branches = all.filter { !$0.isCheckedOut }
        var main: BranchDeletion?
        if keepingMain, let name = list.mainBranch?.name, let index = branches.firstIndex(where: { $0.ref == name }) {
            main = branches.remove(at: index)
        }
        let lost = try await LostCommits.find(
            from: branches.map(\.ref),
            leaving: LostCommits.leaving(branches.map(\.ref), among: refs),
            keeping: ["--all"],
            limit: limit,
            in: worktree,
            git: git
        )
        if branches.count == 1 {
            branches[0].lostCount = lost.count
            branches[0].lost = lost.newest
        }
        let going = Set(branches.map(\.ref))
        var lostBy: [Set<String>: Int] = lost.count > 0 ? [going: lost.count] : [:]
        // Branches on different commits can each lead to commits of their own,
        // which only finding out which leads where can count.
        if commit == nil, branches.count > 1, lost.count > 0 {
            let tips = Dictionary(refs.filter { going.contains($0.name) }.map { ($0.name, $0.peeled) }, uniquingKeysWith: { first, _ in first })
            lostBy = try await LostCommits.owners(
                of: tips,
                leaving: LostCommits.leaving(branches.map(\.ref), among: refs),
                keeping: ["--all"],
                in: worktree,
                git: git
            )
        }
        return CommitBranchesDeletion(
            branches: branches,
            checkedOut: all.filter(\.isCheckedOut),
            main: main,
            lostCount: lost.count,
            lost: lost.newest,
            lostBy: lostBy
        )
    }
}

/// The commits that only some tips lead to, which go when those tips do.
struct LostCommits {
    var count: Int
    /// The newest of them.
    var newest: [ObjectID]

    /// - Parameters:
    ///   - tips: What's going, as revisions.
    ///   - leaving: The full names of the refs that are going, which don't keep
    ///     the commits.
    ///   - keeping: What does keep them, as arguments to `git rev-list`. An option
    ///     that lists refs, such as `--all`, comes first, because `--exclude` only
    ///     applies to the next one.
    ///   - limit: The most commits to list.
    static func find(
        from tips: [String],
        leaving: [String],
        keeping: [String],
        limit: Int,
        in directory: String,
        git: Git
    ) async throws -> LostCommits {
        guard !tips.isEmpty else { return LostCommits(count: 0, newest: []) }
        let commits = tips + ["--not"] + leaving.map { "--exclude=" + $0 } + keeping + ["--"]
        let count = try await git.text(GitCommand(["rev-list", "--count"] + commits, in: directory))
        let newest = try await git.text(GitCommand(["rev-list", "--max-count=\(limit)"] + commits, in: directory))
        return LostCommits(count: Int(count) ?? 0, newest: newest.split(separator: "\n").compactMap { ObjectID(hex: String($0)) })
    }

    /// Which of some branches lead to each of the commits that go when they all
    /// do, as how many of those commits each set of them leads to.
    ///
    /// It lists those commits with their parents, children first, and passes
    /// each commit's branches down to its parents. Every commit between a tip and
    /// one of those commits is one of them too, since whatever kept it would keep
    /// what it leads to, so the walk never has to leave them. A tip outside them
    /// leads only to commits that something else keeps.
    ///
    /// - Parameters:
    ///   - tips: The commit each branch is on, by the branch's full name.
    ///   - leaving: As `find(from:leaving:keeping:limit:in:git:)` has it.
    ///   - keeping: As `find(from:leaving:keeping:limit:in:git:)` has it.
    static func owners(
        of tips: [String: ObjectID],
        leaving: [String],
        keeping: [String],
        in directory: String,
        git: Git
    ) async throws -> [Set<String>: Int] {
        guard !tips.isEmpty else { return [:] }
        let names = tips.keys.sorted()
        let commits = names + ["--not"] + leaving.map { "--exclude=" + $0 } + keeping + ["--"]
        let listed = try await git.text(GitCommand(["rev-list", "--topo-order", "--parents"] + commits, in: directory))
        return owners(listed: listed, tips: tips)
    }

    /// The same, from what `git rev-list --topo-order --parents` listed, one
    /// commit to a line followed by its parents.
    static func owners(listed: String, tips: [String: ObjectID]) -> [Set<String>: Int] {
        let lines = listed.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        var index: [String: Int] = [:]
        for (position, line) in lines.enumerated() {
            if let commit = line.first { index[commit] = position }
        }
        var owners = Array(repeating: Set<String>(), count: lines.count)
        for (name, tip) in tips {
            if let position = index[tip.hex] { owners[position].insert(name) }
        }
        // Topological order lists a commit before its parents, so a commit has
        // every branch that leads to it by the time its line comes.
        for (position, line) in lines.enumerated() {
            for parent in line.dropFirst() {
                if let parentPosition = index[parent] { owners[parentPosition].formUnion(owners[position]) }
            }
        }
        var counts: [Set<String>: Int] = [:]
        for set in owners where !set.isEmpty {
            counts[set, default: 0] += 1
        }
        return counts
    }

    /// Adds the symbolic refs that point to refs that are going. One such as
    /// `origin/HEAD` goes when its branch goes, so it doesn't keep the commits.
    static func leaving(_ names: [String], in directory: String, git: Git) async throws -> [String] {
        leaving(names, among: try await RefsLoader.load(git: git, in: directory).refs)
    }

    /// The same, for someone who has already listed the refs.
    static func leaving(_ names: [String], among refs: [Ref]) -> [String] {
        names + refs.filter { $0.symbolicTarget.map(names.contains) ?? false }.map(\.name)
    }
}
