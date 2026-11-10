import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Reading a submodule's rows, staging around one and updating one, against
/// real git (decision 75). `SubmoduleRepository` says what each test starts
/// with: the fifth of the submodule's commits recorded and checked out.
@Suite(.timeLimit(.minutes(1)))
struct SubmoduleTests {
    let path = SubmoduleRepository.path

    func open(_ world: SubmoduleRepository) async throws -> RepositorySession {
        try await RepositorySession.open(containing: world.parent, git: try await SubmoduleRepository.git())
    }

    func id(_ hex: String) throws -> ObjectID {
        try #require(ObjectID(hex: hex))
    }

    /// The submodule's row under Unstaged as status lists it, and with what
    /// reading the submodule adds.
    func unstagedRow(_ session: RepositorySession, _ world: SubmoduleRepository) async throws -> (listed: DiffFile, read: DiffFile, source: PatchSource) {
        let changes = try await session.changes(in: world.parent)
        let listed = try #require(changes.unstaged.first { $0.path == path })
        let source = PatchSource.worktree(path: world.parent, group: .unstaged, head: changes.head)
        let change: SubmoduleChange = try #require(try await session.submoduleChanges(of: [listed], from: source, in: world.parent)[path])
        var read = listed
        read.submodule = change
        return (listed, read, source)
    }

    /// The submodule's row in one of the parent's commits.
    func row(in commit: String, _ session: RepositorySession) async throws -> DiffFile {
        try #require(try await session.changedFiles(in: try id(commit)).first { $0.path == path })
    }

    func time(minute: Int) throws -> Int64 {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-03T17:\(String(format: "%02d", minute)):00Z"))
        return Int64(date.timeIntervalSince1970)
    }

    func head(of folder: String, _ world: SubmoduleRepository) async throws -> String {
        try await world.run("rev-parse", "HEAD", in: folder)
    }

    // MARK: What status says

    @Test func statusSaysWhatACheckoutHasBeforeAnythingReadsIt() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        #expect(try await session.status(in: world.parent).fileCount == 0)

        try await world.checkOut(1)
        try Data("changed\n".utf8).write(to: URL(filePath: world.parent + "/a.txt"))
        var changes = try await session.changes(in: world.parent)
        var row = try #require(changes.unstaged.first { $0.path == path })
        #expect(row.status == .modified)
        #expect(row.isSubmodule)
        #expect(row.oldID == (try id(world.commits[4])))
        #expect(row.submodule == SubmoduleChange(checkout: [.commitChanged]))
        #expect(row.submoduleStaging == .unknown)
        // git counts two `Subproject commit` lines, which aren't lines of a file.
        #expect(row.lines == DiffFile.LineCounts(added: 0, removed: 0))
        let file = try #require(changes.unstaged.first { $0.path == "a.txt" })
        #expect(file.submodule == nil && !file.isSubmodule && file.submoduleStaging == nil)
        #expect(file.lines == DiffFile.LineCounts(added: 1, removed: 1))

        try world.writeInside("changed\n", to: "lib.txt")
        try world.writeInside("notes\n", to: "Notes.md")
        changes = try await session.changes(in: world.parent)
        row = try #require(changes.unstaged.first { $0.path == path })
        #expect(row.submodule?.checkout == [.commitChanged, .modifiedFiles, .untrackedFiles])
    }

    @Test func aStagedSubmoduleHasNothingAboutItsCheckout() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        _ = try await world.commitInside("Local one")
        try await world.run("add", path, in: world.parent)
        try world.writeInside("more\n", to: "Notes.md")

        let changes = try await session.changes(in: world.parent)
        let staged = try #require(changes.staged.first { $0.path == path })
        #expect(staged.submodule == SubmoduleChange())
        #expect(staged.oldID == (try id(world.commits[4])))
        #expect(staged.newID == (try id(try await head(of: world.checkout, world))))
        #expect(staged.submoduleStaging == nil)
        // The file inside is still there to see, under Unstaged.
        let row = try #require(changes.unstaged.first { $0.path == path })
        #expect(row.submodule?.checkout == [.untrackedFiles])
        #expect(row.submoduleStaging == .nothingToStage)

        let source = PatchSource.worktree(path: world.parent, group: .staged, head: changes.head)
        let read = try await session.submoduleChanges(of: [staged], from: source, in: world.parent)
        #expect(read[path] == SubmoduleChange(distance: .counted(ahead: 1, behind: 0)))
        let details = try await session.submoduleDetails(of: staged, from: source, in: world.parent)
        #expect(!details.comparesCheckout)
        #expect(details.added.map(\.subject) == ["Local one"])
        #expect(details.unpushed == 1)
        #expect(details.filesInside.isEmpty)
    }

    // MARK: A checkout against what's recorded

    @Test func aCheckoutBehindWhatsRecordedListsTheCommitsItsMissing() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        try await world.checkOut(1)

        let (_, row, source) = try await unstagedRow(session, world)
        #expect(row.submodule == SubmoduleChange(checkout: [.commitChanged], distance: .counted(ahead: 0, behind: 3)))
        #expect(row.submoduleStaging == .takesCommitsAway)

        let details = try await session.submoduleDetails(of: row, from: source, in: world.parent)
        #expect(details.comparesCheckout)
        #expect(details.from == (try id(world.commits[4])))
        #expect(details.to == (try id(world.commits[1])))
        #expect(details.distance == .counted(ahead: 0, behind: 3))
        #expect(details.added.isEmpty)
        #expect(details.removed == [
            SubmoduleDetails.Commit(id: try id(world.commits[4]), subject: "Parser commit 5", author: "Sam Lee", time: try time(minute: 5)),
            SubmoduleDetails.Commit(id: try id(world.commits[3]), subject: "Parser commit 4", author: "Sam Lee", time: try time(minute: 4)),
            SubmoduleDetails.Commit(id: try id(world.commits[2]), subject: "Parser commit 3", author: "Sam Lee", time: try time(minute: 3)),
        ])
        #expect(details.unpushed == nil)
        #expect(details.filesInside.isEmpty)
        #expect(details.change(checkout: row.submodule?.checkout) == row.submodule)
    }

    @Test func aCheckoutWithNewCommitsListsThemAndSaysTheyArentPushed() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        let one = try await world.commitInside("Local one")
        let two = try await world.commitInside("Local two")

        let (_, row, source) = try await unstagedRow(session, world)
        #expect(row.submodule == SubmoduleChange(checkout: [.commitChanged], distance: .counted(ahead: 2, behind: 0)))
        #expect(row.submoduleStaging == .recordsNewCommits)

        var details = try await session.submoduleDetails(of: row, from: source, in: world.parent)
        #expect(details.from == (try id(world.commits[4])))
        #expect(details.to == (try id(two)))
        #expect(details.added.map(\.id) == [try id(two), try id(one)])
        #expect(details.added.map(\.subject) == ["Local two", "Local one"])
        #expect(details.removed.isEmpty)
        #expect(details.unpushed == 2)

        // Once a remote branch leads to them, there's nothing to say.
        try await world.run("push", "--quiet", "origin", "\(one):refs/heads/topic", in: world.checkout)
        details = try await session.submoduleDetails(of: row, from: source, in: world.parent)
        #expect(details.unpushed == 1)
        try await world.run("push", "--quiet", "origin", "\(two):refs/heads/topic", in: world.checkout)
        details = try await session.submoduleDetails(of: row, from: source, in: world.parent)
        #expect(details.unpushed == 0)
    }

    @Test func aCheckoutWithCommitsOfItsOwnThatsMissingSomeToo() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        try await world.checkOut(2)
        _ = try await world.commitInside("Local")

        let (_, row, source) = try await unstagedRow(session, world)
        #expect(row.submodule?.distance == .counted(ahead: 1, behind: 2))
        #expect(row.submoduleStaging == .takesSomeAndAddsSome)
        let details = try await session.submoduleDetails(of: row, from: source, in: world.parent)
        #expect(details.added.map(\.subject) == ["Local"])
        #expect(details.removed.map(\.subject) == ["Parser commit 5", "Parser commit 4"])
    }

    @Test func aCheckoutWithFilesOfItsOwnChangedListsThem() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        try world.writeInside("changed\n", to: "lib.txt")
        try world.writeInside("notes\n", to: "Notes.md")

        let (listed, row, source) = try await unstagedRow(session, world)
        // Before anything is read, the row already has no Stage.
        #expect(listed.submodule == SubmoduleChange(checkout: [.modifiedFiles, .untrackedFiles]))
        #expect(listed.submoduleStaging == .nothingToStage)
        #expect(row.submodule == SubmoduleChange(checkout: [.modifiedFiles, .untrackedFiles], distance: .counted(ahead: 0, behind: 0), filesInside: 2))
        #expect(row.submoduleStaging == .nothingToStage)

        let details = try await session.submoduleDetails(of: row, from: source, in: world.parent)
        #expect(details.from == details.to)
        #expect(details.added.isEmpty && details.removed.isEmpty)
        #expect(details.filesInside == [
            SubmoduleDetails.File(status: .untracked, path: "Notes.md"),
            SubmoduleDetails.File(status: .modified, path: "lib.txt"),
        ])
    }

    @Test func aRecordedCommitThatTheCheckoutHasntFetchedCantBeCounted() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        // Someone else's commit to the submodule, which a pull brought the
        // record of, but not the commit.
        try Data("line 6\n".utf8).write(to: URL(filePath: world.origin + "/more.txt"))
        try await world.run("add", "more.txt", in: world.origin)
        try await world.run("commit", "--quiet", "--message=Parser commit 6", in: world.origin)
        let sixth = try await head(of: world.origin, world)
        try await world.run("update-index", "--cacheinfo", "160000,\(sixth),\(path)", in: world.parent)
        try await world.run("commit", "--quiet", "--message=Record the sixth", in: world.parent)

        let (_, row, source) = try await unstagedRow(session, world)
        #expect(row.submodule == SubmoduleChange(checkout: [.commitChanged], distance: .commitMissing))
        #expect(row.submoduleStaging == .takesCommitsAway)
        let details = try await session.submoduleDetails(of: row, from: source, in: world.parent)
        #expect(details.from == (try id(sixth)))
        #expect(details.to == (try id(world.commits[4])))
        #expect(details.distance == .commitMissing)
        #expect(details.added.isEmpty && details.removed.isEmpty)

        // Staging everything leaves it, and updating fetches the commit.
        #expect(try await session.stageEverything(in: world.parent).map(\.path) == [path])
        #expect(try await session.status(in: world.parent).staged.isEmpty)
        try await session.updateSubmodule(path, in: world.parent)
        #expect(try await head(of: world.checkout, world) == sixth)
        #expect(try await session.status(in: world.parent).fileCount == 0)
    }

    // MARK: A commit that moves the submodule

    @Test func aCommitThatMovesASubmoduleForwardListsTheCommitsItBrings() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        let row = try await row(in: world.forward, session)
        #expect(row.status == .modified)
        #expect(row.submodule == SubmoduleChange())
        #expect(row.lines == DiffFile.LineCounts(added: 0, removed: 0))
        #expect(row.submoduleStaging == nil)

        let source = PatchSource.commit(try id(world.forward))
        let read = try await session.submoduleChanges(of: [row], from: source, in: world.parent)
        #expect(read == [path: SubmoduleChange(distance: .counted(ahead: 3, behind: 0))])

        let details = try await session.submoduleDetails(of: row, from: source, in: world.parent)
        #expect(!details.comparesCheckout)
        #expect(details.from == (try id(world.commits[1])))
        #expect(details.to == (try id(world.commits[4])))
        #expect(details.distance == .counted(ahead: 3, behind: 0))
        #expect(details.added.map(\.subject) == ["Parser commit 5", "Parser commit 4", "Parser commit 3"])
        #expect(details.added.map(\.author) == ["Sam Lee", "Sam Lee", "Sam Lee"])
        #expect(details.removed.isEmpty)
        // They're in history already, so nobody asks whether they're pushed.
        #expect(details.unpushed == nil)
    }

    @Test func aCommitThatMovesASubmoduleBackListsTheCommitsItDrops() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        let row = try await row(in: world.back, session)
        let source = PatchSource.commit(try id(world.back))
        #expect(try await session.submoduleChanges(of: [row], from: source, in: world.parent) == [path: SubmoduleChange(distance: .counted(ahead: 0, behind: 1))])

        let details = try await session.submoduleDetails(of: row, from: source, in: world.parent)
        #expect(details.from == (try id(world.commits[4])))
        #expect(details.to == (try id(world.commits[3])))
        #expect(details.added.isEmpty)
        #expect(details.removed.map(\.subject) == ["Parser commit 5"])
    }

    @Test func aCommitThatAddsASubmoduleHasOneCommitToShow() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        let added = try await world.run("rev-parse", world.forward + "~1", in: world.parent)
        let row = try await row(in: added, session)
        #expect(row.status == .added)
        #expect(row.isSubmodule)
        #expect(row.lines == DiffFile.LineCounts(added: 0, removed: 0))

        let details = try await session.submoduleDetails(of: row, from: .commit(try id(added)), in: world.parent)
        #expect(details.from == nil)
        #expect(details.to == (try id(world.commits[1])))
        #expect(details.distance == .counted(ahead: 0, behind: 0))
        #expect(details.added.isEmpty && details.removed.isEmpty)
    }

    @Test func severalCommitsMoveASubmoduleAsOne() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        // From before the submodule moved forward to after it moved back.
        let from = try id(try await world.run("rev-parse", world.forward + "~1", in: world.parent))
        let to = try id(world.back)
        let row = try #require(try await session.changedFiles(from: from, to: to).first { $0.path == path })
        let source = PatchSource.commits(from: from, to: to)
        #expect(try await session.submoduleChanges(of: [row], from: source, in: world.parent)[path]?.distance == .counted(ahead: 2, behind: 0))
        let details = try await session.submoduleDetails(of: row, from: source, in: world.parent)
        #expect(details.added.map(\.subject) == ["Parser commit 4", "Parser commit 3"])
    }

    @Test func aLongRunOfCommitsStopsAtTheLimit() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        let row = try await row(in: world.forward, session)
        let details = try await SubmoduleLoader.details(
            of: row, comparingCheckout: false, countsUnpushed: false, in: world.parent, limit: 2, git: session.git
        )
        // The count still says how many there are.
        #expect(details.distance == .counted(ahead: 3, behind: 0))
        #expect(details.added.map(\.subject) == ["Parser commit 5", "Parser commit 4"])
    }

    // MARK: A submodule that isn't checked out

    @Test func aSubmoduleThatIsntCheckedOutShowsOnlyItsTwoCommits() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        // A linked worktree starts with its submodules' folders empty.
        let linked = (world.parent as NSString).deletingLastPathComponent + "/linked"
        try await world.run("worktree", "add", "--quiet", "-b", "linked", linked, in: world.parent)
        #expect(try FileManager.default.contentsOfDirectory(atPath: linked + "/" + path).isEmpty)

        let row = try await row(in: world.forward, session)
        let source = PatchSource.commit(try id(world.forward))
        // git run in the empty folder would answer for the parent, whose own
        // commits have nothing to do with these two.
        #expect(try await session.submoduleChanges(of: [row], from: source, in: linked) == [path: SubmoduleChange(distance: .notCheckedOut)])
        for worktree in [linked, nil] {
            let details = try await session.submoduleDetails(of: row, from: source, in: worktree)
            #expect(details.from == (try id(world.commits[1])))
            #expect(details.to == (try id(world.commits[4])))
            #expect(details.distance == .notCheckedOut)
            #expect(details.added.isEmpty && details.removed.isEmpty)
        }

        // Updating checks it out there.
        try await session.updateSubmodule(path, in: linked)
        #expect(try await head(of: linked + "/" + path, world) == world.commits[4])
        #expect(try await session.submoduleChanges(of: [row], from: source, in: linked) == [path: SubmoduleChange(distance: .counted(ahead: 3, behind: 0))])
    }

    @Test func aSubmoduleWhoseFolderIsGoneStagesAsRemoved() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        try FileManager.default.removeItem(atPath: world.checkout)

        let (listed, row, source) = try await unstagedRow(session, world)
        #expect(listed.status == .deleted)
        #expect(listed.isSubmodule)
        // It stages as any deleted file does.
        #expect(listed.submoduleStaging == nil)
        #expect(row.submodule?.distance == .notCheckedOut)
        let details = try await session.submoduleDetails(of: row, from: source, in: world.parent)
        #expect(details.from == (try id(world.commits[4])))
        #expect(details.to == nil)
        #expect(!details.comparesCheckout)
    }

    // MARK: Staging everything

    @Test func stagingEverythingLeavesOutASubmoduleThatsBehind() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        try await world.checkOut(1)
        try Data("changed\n".utf8).write(to: URL(filePath: world.parent + "/a.txt"))
        try Data("new\n".utf8).write(to: URL(filePath: world.parent + "/new.txt"))

        let leftOut = try await session.stageEverything(in: world.parent)
        #expect(leftOut.map(\.path) == [path])
        #expect(leftOut.first?.submodule?.distance == .counted(ahead: 0, behind: 3))
        let after = try await session.status(in: world.parent)
        #expect(after.staged.map(\.path).sorted() == ["a.txt", "new.txt"])
        #expect(after.unstaged.map(\.path) == [path])
        #expect(after.untracked.isEmpty)

        // Staging its own row still records the older commit, for someone who
        // means to go back.
        try await session.stage(after.unstaged, in: world.parent)
        let staged = try #require(try await session.status(in: world.parent).staged.first { $0.path == path })
        #expect(staged.newID == (try id(world.commits[1])))
    }

    @Test func stagingEverythingLeavesOutASubmoduleThatsMissingCommitsAndHasItsOwn() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        try await world.checkOut(2)
        _ = try await world.commitInside("Local")
        try Data("changed\n".utf8).write(to: URL(filePath: world.parent + "/a.txt"))

        #expect(try await session.stageEverything(in: world.parent).map(\.path) == [path])
        let after = try await session.status(in: world.parent)
        #expect(after.staged.map(\.path) == ["a.txt"])
        #expect(after.unstaged.map(\.path) == [path])
    }

    @Test func stagingEverythingTakesASubmoduleWithNewCommits() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        let local = try await world.commitInside("Local")
        try Data("changed\n".utf8).write(to: URL(filePath: world.parent + "/a.txt"))

        #expect(try await session.stageEverything(in: world.parent).isEmpty)
        let after = try await session.status(in: world.parent)
        #expect(after.staged.map(\.path).sorted() == ["a.txt", path])
        #expect(after.staged.first { $0.path == path }?.newID == (try id(local)))
        #expect(after.unstaged.isEmpty)
    }

    @Test func stagingEverythingLeavesOutAPathThatLooksLikeAPattern() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        // A second submodule, at a path that a pathspec would read as a pattern,
        // and a new file that the pattern matches.
        let odd = "lib[s]"
        try await world.run("submodule", "--quiet", "add", world.origin, odd, in: world.parent)
        try await world.run("commit", "--quiet", "--message=Add another", in: world.parent)
        try await world.run("checkout", "--quiet", "--detach", world.commits[0], in: world.parent + "/" + odd)
        try Data("new\n".utf8).write(to: URL(filePath: world.parent + "/libs"))

        #expect(try await session.stageEverything(in: world.parent).map(\.path) == [odd])
        let after = try await session.status(in: world.parent)
        // The pattern would have left out the file too.
        #expect(after.staged.map(\.path) == ["libs"])
        #expect(after.unstaged.map(\.path) == [odd])
    }

    // MARK: Updating

    @Test func updatingChecksOutTheCommitThatsRecorded() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        try await world.checkOut(1)
        #expect(RepositorySession.updateSubmoduleArguments(path) == ["submodule", "update", "--init", "--", path])
        try await session.updateSubmodule(path, in: world.parent)
        #expect(try await head(of: world.checkout, world) == world.commits[4])
        #expect(try await session.status(in: world.parent).fileCount == 0)
    }

    @Test func updatingRefusesToOverwriteWhatsChangedInside() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        try await world.checkOut(1)
        try world.writeInside("mine\n", to: "lib.txt")
        await #expect(throws: GitError.self) {
            try await session.updateSubmodule(path, in: world.parent)
        }
        #expect(try await head(of: world.checkout, world) == world.commits[1])
        #expect(try String(contentsOfFile: world.checkout + "/lib.txt", encoding: .utf8) == "mine\n")
    }

    // MARK: Leaving things alone

    @Test func readingASubmoduleLeavesItsIndexAlone() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        try await world.checkOut(1)
        // The same contents with a newer date, which `git status` would write
        // into the index if it took the lock.
        try world.writeInside("line 1\nline 2\n", to: "lib.txt")
        try world.writeInside("notes\n", to: "Notes.md")
        let index = try await world.run("rev-parse", "--path-format=absolute", "--git-path", "index", in: world.checkout)
        let before = try Data(contentsOf: URL(filePath: index))

        let (_, row, source) = try await unstagedRow(session, world)
        #expect(row.submodule?.filesInside == 1)
        _ = try await session.submoduleDetails(of: row, from: source, in: world.parent)
        #expect(try Data(contentsOf: URL(filePath: index)) == before)
    }
}
