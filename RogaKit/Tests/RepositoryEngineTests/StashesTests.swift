import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Stashing what's uncommitted, and putting back, deleting and branching from a
/// stash (decision 81), in a new repository whose first commit has `notes.txt`,
/// `other.txt` and `third.txt`.
@Suite(.timeLimit(.minutes(1)))
struct StashesTests {
    struct Repository {
        var folder: String
        var session: RepositorySession
    }

    /// What `notes.txt` starts with. A change to its first line here and another
    /// in a commit conflict.
    static let notes = "1\n2\n3\n4\n5\n"

    func repository() async throws -> Repository {
        let folder = try makeTemporaryFolder() + "/work"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: folder)
        try write(Self.notes, to: "notes.txt", in: folder)
        try write("other\n", to: "other.txt", in: folder)
        try write("third\n", to: "third.txt", in: folder)
        try await commit("First", in: folder)
        return Repository(folder: folder, session: try await openSession(folder))
    }

    @discardableResult
    func commit(_ message: String, in folder: String) async throws -> String {
        try await runGit("add", "--all", in: folder)
        try await runGit("-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--quiet", "-m", message, in: folder)
        return try await runGit("rev-parse", "HEAD", in: folder)
    }

    func write(_ text: String, to file: String, in folder: String) throws {
        try text.write(toFile: folder + "/" + file, atomically: true, encoding: .utf8)
    }

    func read(_ file: String, in repository: Repository) throws -> String {
        try String(contentsOfFile: repository.folder + "/" + file, encoding: .utf8)
    }

    func exists(_ file: String, in repository: Repository) -> Bool {
        FileManager.default.fileExists(atPath: repository.folder + "/" + file)
    }

    /// `git status --porcelain`, one line for each file, in no particular order.
    func status(_ repository: Repository) async throws -> Set<String> {
        Set(try await runGit("status", "--porcelain", in: repository.folder).split(separator: "\n").map(String.init))
    }

    /// The stashes' messages, newest first.
    func stashes(_ repository: Repository) async throws -> [String] {
        try await runGit("stash", "list", "--format=%s", in: repository.folder).split(separator: "\n").map(String.init)
    }

    /// Changes `notes.txt` without staging it, stages a change to `other.txt`, and
    /// adds an untracked `new.txt`.
    func changeEverything(in repository: Repository) async throws {
        try write("mine\n2\n3\n4\n5\n", to: "notes.txt", in: repository.folder)
        try write("other, staged\n", to: "other.txt", in: repository.folder)
        try await runGit("add", "other.txt", in: repository.folder)
        try write("new\n", to: "new.txt", in: repository.folder)
    }

    @Test func stashesEverythingIncludingStagedAndUntrackedFiles() async throws {
        let repository = try await repository()
        try await changeEverything(in: repository)

        let stash = try await repository.session.stashChanges(message: "Mine", in: repository.folder)
        #expect(stash != nil)
        #expect(try await status(repository).isEmpty)
        #expect(try await stashes(repository) == ["On main: Mine"])
        #expect(!exists("new.txt", in: repository))
    }

    @Test func savesNothingWhenNothingIsUncommitted() async throws {
        let repository = try await repository()
        #expect(try await repository.session.stashChanges(message: "Mine", in: repository.folder) == nil)
        #expect(try await stashes(repository).isEmpty)
    }

    @Test func leavesARepositoryInsideTheWorktreeWhereItIs() async throws {
        let repository = try await repository()
        let nested = repository.folder + "/agent"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", in: nested)
        try write("inside\n", to: "inside.txt", in: nested)
        try await commit("Inside", in: nested)
        try write("mine\n2\n3\n4\n5\n", to: "notes.txt", in: repository.folder)

        _ = try #require(try await repository.session.stashChanges(message: "Mine", in: repository.folder))
        #expect(try await status(repository) == ["?? agent/"])
        #expect(try read("agent/inside.txt", in: repository) == "inside\n")
    }

    @Test func putsAStashBackAsItWasAndDeletesIt() async throws {
        let repository = try await repository()
        try await changeEverything(in: repository)
        let stash = try #require(try await repository.session.stashChanges(message: "Mine", in: repository.folder))

        let outcome = try await repository.session.putBack(stash: stash, keeping: false, in: repository.folder)
        #expect(outcome == .back(files: 3, unstaged: false))
        #expect(try await status(repository) == [" M notes.txt", "M  other.txt", "?? new.txt"])
        #expect(try await stashes(repository).isEmpty)
    }

    @Test func keepsAStashInTheListWhenAskedTo() async throws {
        let repository = try await repository()
        try await changeEverything(in: repository)
        let stash = try #require(try await repository.session.stashChanges(message: "Mine", in: repository.folder))

        _ = try await repository.session.putBack(stash: stash, keeping: true, in: repository.folder)
        #expect(try await status(repository) == [" M notes.txt", "M  other.txt", "?? new.txt"])
        #expect(try await stashes(repository) == ["On main: Mine"])
    }

    /// git 2.52 refuses `--index` when something else is staged, and unstages it on
    /// the way out, so the stash's staged files come back unstaged instead.
    @Test func putsBackUnstagedAndKeepsWhatsStagedWhenSomethingIsStaged() async throws {
        let repository = try await repository()
        try await changeEverything(in: repository)
        let stash = try #require(try await repository.session.stashChanges(message: "Mine", in: repository.folder))
        try write("third, staged\n", to: "third.txt", in: repository.folder)
        try await runGit("add", "third.txt", in: repository.folder)

        let outcome = try await repository.session.putBack(stash: stash, keeping: false, in: repository.folder)
        #expect(outcome == .back(files: 3, unstaged: true))
        #expect(try await status(repository) == [" M notes.txt", " M other.txt", "M  third.txt", "?? new.txt"])
        #expect(try await stashes(repository).isEmpty)
    }

    @Test func findsAStashThatIsNoLongerTheNewest() async throws {
        let repository = try await repository()
        try write("first\n2\n3\n4\n5\n", to: "notes.txt", in: repository.folder)
        let first = try #require(try await repository.session.stashChanges(message: "First", in: repository.folder))
        try write("other, second\n", to: "other.txt", in: repository.folder)
        _ = try #require(try await repository.session.stashChanges(message: "Second", in: repository.folder))

        #expect(try await repository.session.ref(ofStash: first, in: repository.folder) == "stash@{1}")
        _ = try await repository.session.putBack(stash: first, keeping: false, in: repository.folder)
        #expect(try read("notes.txt", in: repository) == "first\n2\n3\n4\n5\n")
        #expect(try await stashes(repository) == ["On main: Second"])
    }

    /// A stash whose change to `notes.txt` conflicts with a commit made since. git
    /// keeps the stash, and Undo takes back only the files the stash had.
    @Test func stopsOnAConflictAndUndoTakesBackOnlyTheStashsFiles() async throws {
        let repository = try await repository()
        try write("mine\n2\n3\n4\n5\n", to: "notes.txt", in: repository.folder)
        try write("new\n", to: "new.txt", in: repository.folder)
        let stash = try #require(try await repository.session.stashChanges(message: "Mine", in: repository.folder))
        try write("theirs\n2\n3\n4\n5\n", to: "notes.txt", in: repository.folder)
        try await commit("Theirs", in: repository.folder)
        try write("other, unstaged\n", to: "other.txt", in: repository.folder)

        let outcome = try await repository.session.putBack(stash: stash, keeping: false, in: repository.folder)
        guard case .conflicted(let files, let indexBefore?, let ran) = outcome else {
            Issue.record("Expected a conflict, not \(outcome)")
            return
        }
        #expect(files == ["notes.txt"])
        #expect(ran == ["stash", "pop", "--index", "stash@{0}"])
        #expect(try await stashes(repository) == ["On main: Mine"])
        #expect(exists("new.txt", in: repository))

        try await repository.session.undoPutBack(stash: stash, indexBefore: indexBefore, in: repository.folder)
        #expect(try read("notes.txt", in: repository) == "theirs\n2\n3\n4\n5\n")
        #expect(!exists("new.txt", in: repository))
        #expect(try await status(repository) == [" M other.txt"])
        #expect(try await stashes(repository) == ["On main: Mine"])
    }

    /// The files that came back cleanly stay unstaged, as they were in the stash,
    /// rather than staged as git leaves them after a conflict.
    @Test func leavesCleanFilesUnstagedAfterAConflict() async throws {
        let repository = try await repository()
        try write("mine\n2\n3\n4\n5\n", to: "notes.txt", in: repository.folder)
        try write("other, mine\n", to: "other.txt", in: repository.folder)
        let stash = try #require(try await repository.session.stashChanges(message: "Mine", in: repository.folder))
        try write("theirs\n2\n3\n4\n5\n", to: "notes.txt", in: repository.folder)
        try await commit("Theirs", in: repository.folder)

        _ = try await repository.session.putBack(stash: stash, keeping: false, in: repository.folder)
        #expect(try await status(repository) == ["UU notes.txt", " M other.txt"])
    }

    @Test func deletesAStashAndListsItAgainAtTheTop() async throws {
        let repository = try await repository()
        try write("first\n2\n3\n4\n5\n", to: "notes.txt", in: repository.folder)
        let first = try #require(try await repository.session.stashChanges(message: "First", in: repository.folder))
        try write("other, second\n", to: "other.txt", in: repository.folder)
        _ = try #require(try await repository.session.stashChanges(message: "Second", in: repository.folder))

        let message = try await repository.session.drop(stash: first, in: repository.folder)
        #expect(message == "On main: First")
        #expect(try await stashes(repository) == ["On main: Second"])

        try await repository.session.restore(stash: first, message: message, in: repository.folder)
        #expect(try await stashes(repository) == ["On main: First", "On main: Second"])
        #expect(try await repository.session.ref(ofStash: first, in: repository.folder) == "stash@{0}")
    }

    @Test func saysWhenAStashHasGone() async throws {
        let repository = try await repository()
        try write("mine\n2\n3\n4\n5\n", to: "notes.txt", in: repository.folder)
        let stash = try #require(try await repository.session.stashChanges(message: "Mine", in: repository.folder))
        try await runGit("stash", "drop", "--quiet", in: repository.folder)

        await #expect(throws: Stashes.Missing(stash: stash)) {
            try await repository.session.putBack(stash: stash, keeping: false, in: repository.folder)
        }
    }

    /// The branch starts where the stash was made, so it comes back without the
    /// conflict it would have on `main` now.
    @Test func makesABranchWhereTheStashWasMade() async throws {
        let repository = try await repository()
        let first = try await runGit("rev-parse", "HEAD", in: repository.folder)
        try write("mine\n2\n3\n4\n5\n", to: "notes.txt", in: repository.folder)
        let stash = try #require(try await repository.session.stashChanges(message: "Mine", in: repository.folder))
        try write("theirs\n2\n3\n4\n5\n", to: "notes.txt", in: repository.folder)
        try await commit("Theirs", in: repository.folder)

        try await repository.session.branch(named: "mine", fromStash: stash, in: repository.folder)
        #expect(try await runGit("symbolic-ref", "--short", "HEAD", in: repository.folder) == "mine")
        #expect(try await runGit("rev-parse", "HEAD", in: repository.folder) == first)
        #expect(try read("notes.txt", in: repository) == "mine\n2\n3\n4\n5\n")
        #expect(try await stashes(repository).isEmpty)
    }

    @Test func namesAStashAfterItsFiles() {
        #expect(Stashes.message(for: ["Sources/LoginView.swift"]) == "LoginView.swift")
        #expect(Stashes.message(for: ["a/LoginView.swift", "Notes.md"]) == "LoginView.swift and Notes.md")
        #expect(Stashes.message(for: ["a/A.swift", "b/B.swift", "C.md"]) == "A.swift, B.swift and C.md")
        #expect(Stashes.message(for: ["A.swift", "B.swift", "C.md", "D.md", "E.md"]) == "A.swift, B.swift and 3 more")
        // Two files with one name are named once.
        #expect(Stashes.message(for: ["a/README.md", "b/README.md"]) == "README.md")
        #expect(Stashes.message(for: []) == "Uncommitted changes")
    }
}
