import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Setting aside uncommitted changes that are in the way of a pull or of going to
/// a commit, and putting them back (decision 58), between clones of a bare copy of
/// the `basic` repository. `other` stands for someone else pushing to the remote.
@Suite(.timeLimit(.minutes(1)))
struct ChangesAsideTests {
    struct Clones {
        var work: String
        var other: String
        var session: RepositorySession
    }

    /// The text both clones start with in `notes.txt`. A change to its first line
    /// and one to its last merge without a conflict.
    static let notes = "1\n2\n3\n4\n5\n"

    func clones() async throws -> Clones {
        let fixture = try await Fixture.repository("basic")
        let folder = try makeTemporaryFolder()
        let remote = folder + "/remote.git"
        try await runGit("clone", "--quiet", "--bare", "--no-local", fixture, remote, in: fixture)
        try await runGit("clone", "--quiet", remote, folder + "/work", in: folder)
        try await runGit("clone", "--quiet", remote, folder + "/other", in: folder)
        let clones = Clones(
            work: folder + "/work",
            other: folder + "/other",
            session: try await RepositorySession.open(containing: folder + "/work", git: try await TestGit.make())
        )
        try await commit("Notes", in: clones.work, file: "notes.txt", text: Self.notes)
        try await runGit("push", "--quiet", in: clones.work)
        try await runGit("pull", "--quiet", in: clones.other)
        return clones
    }

    @discardableResult
    func commit(_ message: String, in folder: String, file: String, text: String) async throws -> String {
        try write(text, to: file, in: folder)
        try await runGit("add", "--all", in: folder)
        try await runGit("-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--quiet", "-m", message, in: folder)
        return try await runGit("rev-parse", "HEAD", in: folder)
    }

    /// Puts a commit that changes the first line of `notes.txt` on the remote's
    /// `main`, and fetches it into `work`.
    @discardableResult
    func theirs(_ clones: Clones, firstLine: String = "theirs") async throws -> String {
        let id = try await commit("Theirs", in: clones.other, file: "notes.txt", text: firstLine + "\n2\n3\n4\n5\n")
        try await runGit("push", "--quiet", in: clones.other)
        try await runGit("fetch", "--quiet", in: clones.work)
        return id
    }

    func write(_ text: String, to file: String, in folder: String) throws {
        try text.write(toFile: folder + "/" + file, atomically: true, encoding: .utf8)
    }

    func read(_ file: String, in clones: Clones) throws -> String {
        try String(contentsOfFile: clones.work + "/" + file, encoding: .utf8)
    }

    /// `git status --porcelain`, one line for each file.
    func status(_ clones: Clones) async throws -> [String] {
        try await runGit("status", "--porcelain", in: clones.work).split(separator: "\n").map(String.init)
    }

    func stashes(_ clones: Clones) async throws -> Int {
        try await runGit("stash", "list", in: clones.work).split(separator: "\n").count
    }

    func head(_ clones: Clones) async throws -> String {
        try await runGit("rev-parse", "HEAD", in: clones.work)
    }

    static let pull = ChangesAside.Move.pull(upstream: "refs/remotes/origin/main", rebases: false)

    @Test func leavesChangesAloneWhenNothingIsInTheWay() async throws {
        let clones = try await clones()
        try await theirs(clones)
        try write("mine\n", to: "elsewhere.txt", in: clones.work)
        try await runGit("add", "elsewhere.txt", in: clones.work)

        let aside = try await clones.session.setAsideChanges(inTheWayOf: Self.pull, message: "Roga: before pulling main", in: clones.work)
        #expect(aside == nil)
        #expect(try await stashes(clones) == 0)
        #expect(try await status(clones) == ["A  elsewhere.txt"])
    }

    @Test func leavesAWorktreeWithNoChangesAlone() async throws {
        let clones = try await clones()
        try await theirs(clones)
        let aside = try await clones.session.setAsideChanges(inTheWayOf: Self.pull, message: "Roga: before pulling main", in: clones.work)
        #expect(aside == nil)
    }

    @Test func setsAsideChangesInTheWayAndPutsThemBackAfterThePull() async throws {
        let clones = try await clones()
        let before = try await head(clones)
        try await theirs(clones)
        try write("1\n2\n3\n4\nmine\n", to: "notes.txt", in: clones.work)
        try write("staged\n", to: "staged.txt", in: clones.work)
        try await runGit("add", "staged.txt", in: clones.work)

        let aside = try #require(try await clones.session.setAsideChanges(inTheWayOf: Self.pull, message: "Roga: before pulling main", in: clones.work))
        #expect(aside.head.hex == before)
        #expect(aside.branch == "refs/heads/main")
        #expect(aside.move == Self.pull)
        #expect(try await status(clones).isEmpty)
        #expect(try await runGit("stash", "list", "--format=%s", in: clones.work) == "On main: Roga: before pulling main")

        try await clones.session.pull(.fastForward, in: clones.work)
        #expect(try await clones.session.putBack(aside, in: clones.work) == .back)
        #expect(try read("notes.txt", in: clones) == "theirs\n2\n3\n4\nmine\n")
        #expect(try await status(clones) == [" M notes.txt", "A  staged.txt"])
        #expect(try await stashes(clones) == 0)
    }

    @Test func aRebaseSetsAsideAnyChange() async throws {
        let clones = try await clones()
        try await theirs(clones)
        try write("mine\n", to: "elsewhere.txt", in: clones.work)
        try await runGit("add", "elsewhere.txt", in: clones.work)

        let move = ChangesAside.Move.pull(upstream: "refs/remotes/origin/main", rebases: true)
        let aside = try #require(try await clones.session.setAsideChanges(inTheWayOf: move, message: "Roga: before pulling main", in: clones.work))
        try await clones.session.pull(.rebase, in: clones.work)
        #expect(try await clones.session.putBack(aside, in: clones.work) == .back)
        #expect(try await status(clones) == ["A  elsewhere.txt"])
    }

    @Test func changesThatConflictStayInTheStashWithStagingAsItWas() async throws {
        let clones = try await clones()
        try await theirs(clones)
        try write("mine\n2\n3\n4\n5\n", to: "notes.txt", in: clones.work)
        try write("staged\n", to: "staged.txt", in: clones.work)
        try await runGit("add", "staged.txt", in: clones.work)
        try write("unstaged\n", to: "README.md", in: clones.work)
        try await runGit("add", "README.md", in: clones.work)
        try write("changed again\n", to: "README.md", in: clones.work)
        let readmeStaged = try await runGit("diff", "--cached", "--", "README.md", in: clones.work)

        let aside = try #require(try await clones.session.setAsideChanges(inTheWayOf: Self.pull, message: "Roga: before pulling main", in: clones.work))
        try await clones.session.pull(.fastForward, in: clones.work)
        #expect(try await clones.session.putBack(aside, in: clones.work) == .conflicted(files: ["notes.txt"]))

        #expect(try await stashes(clones) == 1)
        let lines = try await status(clones)
        #expect(lines.contains("UU notes.txt"))
        #expect(lines.contains("A  staged.txt"))
        // git stages a file that came back cleanly, but only what was staged stays so.
        #expect(lines.contains("MM README.md"))
        #expect(try await runGit("diff", "--cached", "--", "README.md", in: clones.work) == readmeStaged)
    }

    @Test func undoingGoesBackAndPutsTheChangesBackAsTheyWere() async throws {
        let clones = try await clones()
        let before = try await head(clones)
        try await theirs(clones)
        try write("mine\n2\n3\n4\n5\n", to: "notes.txt", in: clones.work)
        try write("staged\n", to: "staged.txt", in: clones.work)
        try await runGit("add", "staged.txt", in: clones.work)

        let aside = try #require(try await clones.session.setAsideChanges(inTheWayOf: Self.pull, message: "Roga: before pulling main", in: clones.work))
        try await clones.session.pull(.fastForward, in: clones.work)
        _ = try await clones.session.putBack(aside, in: clones.work)

        #expect(aside.undoArguments(stopped: nil) == [["reset", "--hard", before]])
        #expect(try await clones.session.undo(puttingBack: aside, stopped: nil, in: clones.work) == .back)
        #expect(try await head(clones) == before)
        #expect(try read("notes.txt", in: clones) == "mine\n2\n3\n4\n5\n")
        #expect(try await status(clones) == [" M notes.txt", "A  staged.txt"])
        #expect(try await stashes(clones) == 0)
    }

    @Test func undoingAPullThatStoppedAbortsItFirst() async throws {
        let clones = try await clones()
        try await theirs(clones)
        let mine = try await commit("Mine", in: clones.work, file: "notes.txt", text: "mine\n2\n3\n4\n5\n")
        try write("1\n2\n3\n4\nuncommitted\n", to: "notes.txt", in: clones.work)

        let move = ChangesAside.Move.pull(upstream: "refs/remotes/origin/main", rebases: false)
        let aside = try #require(try await clones.session.setAsideChanges(inTheWayOf: move, message: "Roga: before pulling main", in: clones.work))
        await #expect(throws: GitError.self) {
            try await clones.session.pull(.merge, in: clones.work)
        }
        #expect(try await clones.session.stoppedWork(in: clones.work) == .merge)

        #expect(aside.undoArguments(stopped: .merge) == [["merge", "--abort"], ["reset", "--hard", mine]])
        #expect(try await clones.session.undo(puttingBack: aside, stopped: .merge, in: clones.work) == .back)
        #expect(try await clones.session.stoppedWork(in: clones.work) == nil)
        #expect(try await head(clones) == mine)
        #expect(try read("notes.txt", in: clones) == "1\n2\n3\n4\nuncommitted\n")
    }

    @Test func changesStayInTheStashWhenSomethingWroteOverThemMeanwhile() async throws {
        let clones = try await clones()
        try await theirs(clones)
        try write("1\n2\n3\n4\nmine\n", to: "notes.txt", in: clones.work)

        let aside = try #require(try await clones.session.setAsideChanges(inTheWayOf: Self.pull, message: "Roga: before pulling main", in: clones.work))
        try await clones.session.pull(.fastForward, in: clones.work)
        try write("an agent's\n", to: "notes.txt", in: clones.work)

        guard case .stillAside(let ran, let said) = try await clones.session.putBack(aside, in: clones.work) else {
            Issue.record("Expected the changes to stay in the stash")
            return
        }
        #expect(ran == ["stash", "pop", "--index"])
        #expect(said.contains("notes.txt"))
        #expect(try await stashes(clones) == 1)
        #expect(try read("notes.txt", in: clones) == "an agent's\n")
    }

    @Test func putsBackTheRightStashWhenAnotherCameAfterIt() async throws {
        let clones = try await clones()
        try await theirs(clones)
        try write("1\n2\n3\n4\nmine\n", to: "notes.txt", in: clones.work)

        let aside = try #require(try await clones.session.setAsideChanges(inTheWayOf: Self.pull, message: "Roga: before pulling main", in: clones.work))
        try await clones.session.pull(.fastForward, in: clones.work)
        try write("someone else's\n", to: "other.txt", in: clones.work)
        try await runGit("add", "other.txt", in: clones.work)
        try await runGit("stash", "push", "--quiet", in: clones.work)

        #expect(try await clones.session.putBack(aside, in: clones.work) == .back)
        #expect(try read("notes.txt", in: clones) == "theirs\n2\n3\n4\nmine\n")
        #expect(try await runGit("stash", "list", "--format=%s", in: clones.work).hasPrefix("WIP on main"))
        #expect(try await stashes(clones) == 1)
    }

    @Test func aStashThatsGoneCantBePutBack() async throws {
        let clones = try await clones()
        try await theirs(clones)
        try write("1\n2\n3\n4\nmine\n", to: "notes.txt", in: clones.work)

        let aside = try #require(try await clones.session.setAsideChanges(inTheWayOf: Self.pull, message: "Roga: before pulling main", in: clones.work))
        try await runGit("stash", "drop", "--quiet", in: clones.work)
        await #expect(throws: ChangesAside.Missing.self) {
            try await clones.session.putBack(aside, in: clones.work)
        }
    }

    @Test func goingToACommitSetsAsideTheChangesItWouldOverwrite() async throws {
        let clones = try await clones()
        let target = try await head(clones)
        try await commit("Mine", in: clones.work, file: "notes.txt", text: "1\n2\n3\n4\nmine\n")
        try write("uncommitted\n2\n3\n4\nmine\n", to: "notes.txt", in: clones.work)
        let id = try #require(ObjectID(hex: target))

        let aside = try #require(try await clones.session.setAsideChanges(inTheWayOf: .reset(to: id), message: "Roga: before resetting main", in: clones.work))
        try await runGit("reset", "--quiet", "--keep", target, in: clones.work)
        #expect(try await clones.session.putBack(aside, in: clones.work) == .back)
        #expect(try read("notes.txt", in: clones) == "uncommitted\n2\n3\n4\n5\n")
    }

    @Test func undoingADetachedSwitchGoesBackToTheBranch() async throws {
        let clones = try await clones()
        let before = try await head(clones)
        let elsewhere = try await theirs(clones)
        try write("mine\n2\n3\n4\n5\n", to: "notes.txt", in: clones.work)
        let id = try #require(ObjectID(hex: elsewhere))

        let aside = try #require(try await clones.session.setAsideChanges(inTheWayOf: .detach(at: id), message: "Roga: before switching", in: clones.work))
        try await runGit("switch", "--quiet", "--detach", elsewhere, in: clones.work)
        #expect(try await clones.session.putBack(aside, in: clones.work) == .conflicted(files: ["notes.txt"]))

        #expect(aside.undoArguments(stopped: nil) == [["switch", "--discard-changes", "main"]])
        #expect(try await clones.session.undo(puttingBack: aside, stopped: nil, in: clones.work) == .back)
        #expect(try await runGit("symbolic-ref", "--short", "HEAD", in: clones.work) == "main")
        #expect(try await head(clones) == before)
        #expect(try read("notes.txt", in: clones) == "mine\n2\n3\n4\n5\n")
    }
}
