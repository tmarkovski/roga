import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Removing linked worktrees, and what that would lose, in small repositories
/// that each test makes. Some of these pin down what git itself lets through,
/// because that's why yaga looks for itself (decision 22).
@Suite(.timeLimit(.minutes(1)))
struct WorktreeRemovalTests {
    struct Repository {
        var folder: String
        var main: String
        var linked: String
        var session: RepositorySession
    }

    /// A repository with one commit that ignores `*.log` and `build/`, and a
    /// clean linked worktree on the branch `work`.
    func repository(_ name: String = "work") async throws -> Repository {
        let folder = try makeTemporaryFolder()
        let main = folder + "/main"
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: main)
        try await runGit("config", "user.name", "Ana", in: main)
        try await runGit("config", "user.email", "ana@example.com", in: main)
        try write("hello\n", to: main + "/file.txt")
        try write("*.log\nbuild/\n", to: main + "/.gitignore")
        try await commit("First", in: main)
        let linked = folder + "/" + name
        try await runGit("worktree", "add", "--quiet", "-b", name, linked, in: main)
        return Repository(folder: folder, main: main, linked: linked, session: try await openSession(main))
    }

    func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func commit(_ message: String, in folder: String) async throws {
        try await runGit("add", "--all", in: folder)
        try await runGit("commit", "--quiet", "--message=" + message, in: folder)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// What git said when it refused, which is what yaga shows.
    func refusal(_ work: () async throws -> Void) async throws -> String {
        do {
            try await work()
        } catch let error as GitError {
            return error.message
        }
        Issue.record("git didn't refuse.")
        return ""
    }

    // MARK: Removing

    @Test func removesACleanWorktreeAndKeepsItsBranch() async throws {
        let repository = try await repository()
        let commit = try await runGit("rev-parse", "work", in: repository.main)

        try await repository.session.removeWorktree(repository.linked)

        #expect(!exists(repository.linked))
        #expect(try await repository.session.worktrees().map(\.path) == [repository.main])
        #expect(try await runGit("rev-parse", "work", in: repository.main) == commit)
    }

    @Test func refusesTheMainWorktree() async throws {
        let repository = try await repository()
        let message = try await refusal { try await repository.session.removeWorktree(repository.main, force: true) }
        #expect(message.contains("main working tree"))
        #expect(exists(repository.main + "/file.txt"))
    }

    @Test func refusesChangesUnlessForced() async throws {
        let repository = try await repository()
        try write("changed\n", to: repository.linked + "/file.txt")

        let message = try await refusal { try await repository.session.removeWorktree(repository.linked) }
        #expect(message.contains("--force"))
        #expect(exists(repository.linked + "/file.txt"))

        try await repository.session.removeWorktree(repository.linked, force: true)
        #expect(!exists(repository.linked))
    }

    @Test func aLockStopsItEvenWhenForced() async throws {
        let repository = try await repository()
        try await runGit("worktree", "lock", "--reason", "an agent is working", repository.linked, in: repository.main)

        let message = try await refusal { try await repository.session.removeWorktree(repository.linked, force: true) }
        #expect(message.contains("an agent is working"))
        #expect(exists(repository.linked))
    }

    @Test func removesAWorktreeWhoseFolderIsGone() async throws {
        let repository = try await repository()
        try FileManager.default.removeItem(atPath: repository.linked)

        let losses = try await repository.session.lossesFromRemoving(worktree: repository.linked)
        #expect(losses == WorktreeLosses(folderIsMissing: true, branch: "refs/heads/work", mergedInto: "main"))
        #expect(losses.isEmpty)
        #expect(!losses.needsForce)

        try await repository.session.removeWorktree(repository.linked)
        #expect(try await repository.session.worktrees().map(\.path) == [repository.main])
    }

    @Test func removesAWorktreeOfABareRepository() async throws {
        let repository = try await repository()
        let bare = repository.folder + "/bare.git"
        try await runGit("clone", "--quiet", "--bare", repository.main, bare, in: repository.folder)
        try await runGit("worktree", "add", "--quiet", repository.folder + "/from-bare", "main", in: bare)
        let session = try await openSession(bare)

        try await session.removeWorktree(repository.folder + "/from-bare")

        #expect(!exists(repository.folder + "/from-bare"))
        #expect(try await session.worktrees().count == 1)
    }

    // MARK: What would be lost

    @Test func aCleanWorktreeLosesNothing() async throws {
        let repository = try await repository()
        let losses = try await repository.session.lossesFromRemoving(worktree: repository.linked)
        #expect(losses == WorktreeLosses(branch: "refs/heads/work", mergedInto: "main"))
        #expect(losses.isEmpty)
        #expect(!losses.needsForce)
    }

    @Test func listsChangesOnceEachAndUntrackedFiles() async throws {
        let repository = try await repository()
        try write("staged\n", to: repository.linked + "/file.txt")
        try await runGit("add", "file.txt", in: repository.linked)
        // Both staged and unstaged, which `git status` lists under each.
        try write("then changed\n", to: repository.linked + "/file.txt")
        try write("new\n", to: repository.linked + "/folder/one.txt")
        try write("new\n", to: repository.linked + "/folder/two.txt")

        let losses = try await repository.session.lossesFromRemoving(worktree: repository.linked)

        #expect(losses.changedFiles == ["file.txt"])
        #expect(losses.untrackedFiles == ["folder/one.txt", "folder/two.txt"])
        #expect(losses.needsForce)
        #expect(!losses.isEmpty)
    }

    /// git deletes ignored files without a word, so only yaga can warn about them.
    @Test func listsIgnoredFilesThatGitDeletesWithoutAsking() async throws {
        let repository = try await repository()
        try write("secret\n", to: repository.linked + "/debug.log")
        try write("object\n", to: repository.linked + "/build/deep/down/output.o")

        let losses = try await repository.session.lossesFromRemoving(worktree: repository.linked)

        #expect(losses.ignored == ["build/", "debug.log"])
        #expect(!losses.needsForce)
        #expect(!losses.isEmpty)

        try await repository.session.removeWorktree(repository.linked)
        #expect(!exists(repository.linked))
    }

    /// With this setting, git's check doesn't see untracked files and deletes them.
    @Test func listsUntrackedFilesWhenTheSettingHidesThem() async throws {
        let repository = try await repository()
        try await runGit("config", "status.showUntrackedFiles", "no", in: repository.main)
        try write("new\n", to: repository.linked + "/notes.txt")

        let losses = try await repository.session.lossesFromRemoving(worktree: repository.linked)
        #expect(losses.untrackedFiles == ["notes.txt"])
        #expect(losses.needsForce)

        // The setting still counts everywhere else.
        #expect(try await repository.session.status(in: repository.linked).untracked.isEmpty)

        try await repository.session.removeWorktree(repository.linked)
        #expect(!exists(repository.linked))
    }

    /// git deletes these without a word too, and the worktree's reflog goes with
    /// them, so nothing leads to the commits any more.
    @Test func countsCommitsThatOnlyADetachedHeadHas() async throws {
        let repository = try await repository()
        try await runGit("switch", "--quiet", "--detach", in: repository.linked)
        let atABranch = try await repository.session.lossesFromRemoving(worktree: repository.linked)
        #expect(atABranch == WorktreeLosses())

        try write("more\n", to: repository.linked + "/more.txt")
        try await commit("Second", in: repository.linked)
        try write("again\n", to: repository.linked + "/again.txt")
        try await commit("Third", in: repository.linked)

        let losses = try await repository.session.lossesFromRemoving(worktree: repository.linked)
        #expect(losses.detachedCommits == 2)
        #expect(losses.branch == nil)
        #expect(!losses.needsForce)
        #expect(!losses.isEmpty)
    }

    @Test func aDetachedHeadOnATaggedCommitLosesNoCommits() async throws {
        let repository = try await repository()
        try await runGit("switch", "--quiet", "--detach", in: repository.linked)
        try write("more\n", to: repository.linked + "/more.txt")
        try await commit("Second", in: repository.linked)
        try await runGit("tag", "kept", in: repository.linked)

        let losses = try await repository.session.lossesFromRemoving(worktree: repository.linked)
        #expect(losses.detachedCommits == 0)
    }

    /// git lets this through too when the rebase has stopped with nothing to
    /// commit.
    @Test func noticesARebaseThatsPartwayThrough() async throws {
        let repository = try await repository()
        try write("one\n", to: repository.linked + "/one.txt")
        try await commit("One", in: repository.linked)
        var rebase = GitCommand("rebase", "--quiet", "--interactive", "HEAD~1", in: repository.linked)
        rebase.environment["GIT_SEQUENCE_EDITOR"] = "/usr/bin/sed -i '' -e s/^pick/edit/"
        _ = try await TestGit.make().run(rebase)

        let losses = try await repository.session.lossesFromRemoving(worktree: repository.linked)
        #expect(losses.stoppedPull == .rebase)
        #expect(losses.changedFiles.isEmpty)
        #expect(!losses.needsForce)
        #expect(!losses.isEmpty)
    }

    @Test func noticesAMergeThatsPartwayThrough() async throws {
        let repository = try await repository()
        try write("theirs\n", to: repository.main + "/file.txt")
        try await commit("Theirs", in: repository.main)
        try write("ours\n", to: repository.linked + "/file.txt")
        try await commit("Ours", in: repository.linked)
        var merge = GitCommand("merge", "main", in: repository.linked)
        merge.successStatuses = [1]
        _ = try await TestGit.make().run(merge)

        let losses = try await repository.session.lossesFromRemoving(worktree: repository.linked)
        #expect(losses.stoppedPull == .merge)
        #expect(losses.changedFiles == ["file.txt"])
        #expect(losses.needsForce)
    }

    /// git refuses a worktree with a submodule whether it's clean or not, so
    /// the only way to remove one is by force.
    @Test func aSubmoduleNeedsForce() async throws {
        let repository = try await repository()
        let library = repository.folder + "/library"
        try FileManager.default.createDirectory(atPath: library, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: library)
        try await runGit("-c", "user.name=Ana", "-c", "user.email=ana@example.com", "commit", "--quiet", "--allow-empty", "--message=Library", in: library)
        try await runGit("-c", "protocol.file.allow=always", "submodule", "--quiet", "add", library, "vendor/library", in: repository.linked)
        try await commit("Add a submodule", in: repository.linked)

        let losses = try await repository.session.lossesFromRemoving(worktree: repository.linked)
        #expect(losses.hasSubmodules)
        #expect(losses.needsForce)
        #expect(losses.changedFiles.isEmpty)

        let message = try await refusal { try await repository.session.removeWorktree(repository.linked) }
        #expect(message.contains("submodules"))

        try await repository.session.removeWorktree(repository.linked, force: true)
        #expect(!exists(repository.linked))
    }

    @Test func aSubmoduleThatIsntCheckedOutDoesntNeedForce() async throws {
        let repository = try await repository()
        let library = repository.folder + "/library"
        try FileManager.default.createDirectory(atPath: library, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: library)
        try await runGit("-c", "user.name=Ana", "-c", "user.email=ana@example.com", "commit", "--quiet", "--allow-empty", "--message=Library", in: library)
        try await runGit("-c", "protocol.file.allow=always", "submodule", "--quiet", "add", library, "vendor/library", in: repository.main)
        try await commit("Add a submodule", in: repository.main)
        let other = repository.folder + "/other"
        try await runGit("worktree", "add", "--quiet", "-b", "other", other, in: repository.main)

        let losses = try await repository.session.lossesFromRemoving(worktree: other)
        #expect(!losses.hasSubmodules)
        #expect(losses.isEmpty)

        try await repository.session.removeWorktree(other)
        #expect(!exists(other))
    }

    @Test func aPathCanHoldSpacesAndLookLikeAnOption() async throws {
        let repository = try await repository()
        let folder = repository.folder + "/-a folder with spaces"
        try await runGit("worktree", "add", "--quiet", "-b", "spaces", folder, in: repository.main)
        try write("new\n", to: folder + "/a file.txt")

        let losses = try await repository.session.lossesFromRemoving(worktree: folder)
        #expect(losses.untrackedFiles == ["a file.txt"])

        try await repository.session.removeWorktree(folder, force: true)
        #expect(!exists(folder))
    }

    // MARK: Whether the branch could go too

    func branchExists(_ name: String, in repository: Repository) async throws -> Bool {
        try await !runGit("branch", "--list", name, in: repository.main).isEmpty
    }

    @Test func aBranchIsntMergedUntilTheMainBranchHasItsCommits() async throws {
        let repository = try await repository()
        try write("one\n", to: repository.linked + "/one.txt")
        try await commit("One", in: repository.linked)
        #expect(try await repository.session.lossesFromRemoving(worktree: repository.linked).mergedInto == nil)

        try await runGit("merge", "--quiet", "work", in: repository.main)
        #expect(try await repository.session.lossesFromRemoving(worktree: repository.linked).mergedInto == "main")
    }

    /// As when it was merged on a host and nobody has pulled yet.
    @Test func theRemoteMainBranchHavingItsCommitsCounts() async throws {
        let source = try await repository()
        let remote = source.folder + "/remote.git"
        let clone = source.folder + "/clone"
        try await runGit("clone", "--quiet", "--bare", source.main, remote, in: source.folder)
        try await runGit("clone", "--quiet", remote, clone, in: source.folder)
        try await runGit("config", "user.name", "Ana", in: clone)
        try await runGit("config", "user.email", "ana@example.com", in: clone)
        let linked = source.folder + "/topic"
        try await runGit("worktree", "add", "--quiet", "-b", "topic", linked, in: clone)
        try write("one\n", to: linked + "/one.txt")
        try await commit("One", in: linked)
        let session = try await openSession(clone)
        #expect(try await session.lossesFromRemoving(worktree: linked).mergedInto == nil)

        try await runGit("push", "--quiet", "origin", "topic:main", in: clone)

        #expect(try await session.lossesFromRemoving(worktree: linked).mergedInto == "origin/main")
        try await session.removeWorktree(linked)
        try await session.deleteMergedBranch("refs/heads/topic")
        #expect(try await runGit("branch", "--list", "topic", in: clone).isEmpty)
    }

    @Test func theMainBranchIsntMergedIntoItself() async throws {
        let repository = try await repository()
        try await runGit("switch", "--quiet", "--create=other", in: repository.main)
        let folder = repository.folder + "/on-main"
        try await runGit("worktree", "add", "--quiet", folder, "main", in: repository.main)

        let losses = try await repository.session.lossesFromRemoving(worktree: folder)
        #expect(losses.branch == "refs/heads/main")
        #expect(losses.mergedInto == nil)
    }

    @Test func withoutAMainBranchNothingIsMerged() async throws {
        let repository = try await repository()
        try await runGit("branch", "--move", "main", "trunk", in: repository.main)
        #expect(try await repository.session.lossesFromRemoving(worktree: repository.linked).mergedInto == nil)
    }

    @Test func aBranchWithoutCommitsIsntMerged() async throws {
        let repository = try await repository()
        let folder = repository.folder + "/empty"
        try await runGit("worktree", "add", "--quiet", "--orphan", "-b", "empty", folder, in: repository.main)

        let losses = try await repository.session.lossesFromRemoving(worktree: folder)
        #expect(losses.branch == "refs/heads/empty")
        #expect(losses.mergedInto == nil)
    }

    /// `git branch -d` would refuse this one, because it goes by `HEAD`.
    @Test func deletesAMergedBranchWhateverTheMainWorktreeHasCheckedOut() async throws {
        let repository = try await repository("agent/fix")
        try write("one\n", to: repository.linked + "/one.txt")
        try await commit("One", in: repository.linked)
        try await runGit("merge", "--quiet", "agent/fix", in: repository.main)
        try await runGit("switch", "--quiet", "--create=elsewhere", "main~1", in: repository.main)

        try await repository.session.removeWorktree(repository.linked)
        try await repository.session.deleteMergedBranch("refs/heads/agent/fix")

        #expect(try await !branchExists("agent/fix", in: repository))
        #expect(try await branchExists("main", in: repository))
    }

    @Test func keepsABranchWithCommitsTheMainBranchDoesntHave() async throws {
        let repository = try await repository()
        try write("one\n", to: repository.linked + "/one.txt")
        try await commit("One", in: repository.linked)
        try await repository.session.removeWorktree(repository.linked)

        await #expect(throws: RepositoryError.branchNotMerged("work")) {
            try await repository.session.deleteMergedBranch("refs/heads/work")
        }
        #expect(try await branchExists("work", in: repository))
    }

    @Test func gitKeepsABranchThatAWorktreeHasCheckedOut() async throws {
        let repository = try await repository()
        let message = try await refusal { try await repository.session.deleteMergedBranch("refs/heads/work") }
        #expect(message.contains("work"))
        #expect(try await branchExists("work", in: repository))
    }
}
