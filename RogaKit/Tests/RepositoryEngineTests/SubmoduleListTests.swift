import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Listing a worktree's submodules for the refs panel's section, and reading
/// how each one's checkout stands, against real git (decision 75).
extension SubmoduleTests {
    /// The worktree's submodules as they list, and with how each stands added.
    func listed(_ session: RepositorySession, in worktree: String) async throws -> (unread: [Submodule], read: [Submodule]) {
        let unread = try await session.submodules(in: worktree)
        let standings = try await session.submoduleStandings(of: unread, in: worktree)
        let read = unread.map { submodule in
            var submodule = submodule
            if let standing = standings[submodule.path] { submodule.change = standing }
            return submodule
        }
        return (unread, read)
    }

    /// A linked worktree of the parent, which starts with its submodules'
    /// folders empty.
    func linkedWorktree(_ world: SubmoduleRepository) async throws -> String {
        let linked = (world.parent as NSString).deletingLastPathComponent + "/linked"
        try await world.run("worktree", "add", "--quiet", "-b", "linked", linked, in: world.parent)
        return linked
    }

    @Test func aCleanSubmoduleListsAsRecorded() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        let (unread, read) = try await listed(session, in: world.parent)

        let fifth = try id(world.commits[4])
        // Nothing has read its own repository yet, so nothing says how it stands.
        #expect(unread == [
            Submodule(name: path, path: path, address: world.origin, recorded: fifth, checkedOut: fifth, change: SubmoduleChange(checkout: [])),
        ])
        #expect(unread[0].isRead == false)
        #expect(read[0].change == SubmoduleChange(checkout: [], distance: .counted(ahead: 0, behind: 0)))
        #expect(read[0].isRead)
        // Its row is one with nothing to stage, so the panels offer nothing.
        #expect(read[0].file.isSubmodule)
        #expect(read[0].file.oldID == fifth)
        #expect(read[0].file.submoduleStaging == .nothingToStage)
    }

    @Test func aCheckoutBehindWhatsRecordedListsHowFar() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        try await world.checkOut(1)
        let (unread, read) = try await listed(session, in: world.parent)

        #expect(unread[0].recorded == (try id(world.commits[4])))
        #expect(unread[0].checkedOut == (try id(world.commits[1])))
        // The two commits differ, which is known before anything counts them.
        #expect(unread[0].change == SubmoduleChange(checkout: [.commitChanged]))
        #expect(unread[0].file.submoduleStaging == .unknown)
        #expect(read[0].change == SubmoduleChange(checkout: [.commitChanged], distance: .counted(ahead: 0, behind: 3)))
        #expect(read[0].file.submoduleStaging == .takesCommitsAway)
    }

    @Test func aCheckoutWithNewCommitsListsHowMany() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        _ = try await world.commitInside("Sixth")
        let newest = try await world.commitInside("Seventh")
        let (_, read) = try await listed(session, in: world.parent)

        #expect(read[0].checkedOut == (try id(newest)))
        #expect(read[0].change == SubmoduleChange(checkout: [.commitChanged], distance: .counted(ahead: 2, behind: 0)))
        #expect(read[0].file.submoduleStaging == .recordsNewCommits)
    }

    @Test func aCheckoutWithFilesOfItsOwnListsHowMany() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        try world.writeInside("changed\n", to: "lib.txt")
        try world.writeInside("notes\n", to: "Notes.md")
        let (unread, read) = try await listed(session, in: world.parent)

        // It's on the recorded commit, and the files show once it's been read.
        #expect(unread[0].change == SubmoduleChange(checkout: []))
        #expect(read[0].change == SubmoduleChange(
            checkout: [.modifiedFiles, .untrackedFiles], distance: .counted(ahead: 0, behind: 0), filesInside: 2
        ))
        #expect(read[0].file.submoduleStaging == .nothingToStage)

        // With commits of its own too, it has both to say.
        _ = try await world.commitInside("Sixth")
        try world.writeInside("more\n", to: "More.md")
        let (_, both) = try await listed(session, in: world.parent)
        #expect(both[0].change == SubmoduleChange(checkout: [.commitChanged, .untrackedFiles], distance: .counted(ahead: 1, behind: 0), filesInside: 2))
    }

    @Test func aRecordedCommitThatIsntFetchedListsAsMissing() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        // A commit that only the submodule's own repository has, recorded in
        // the parent the way a pull would leave it.
        try Data("upstream\n".utf8).write(to: URL(filePath: world.origin + "/lib.txt"))
        try await world.run("commit", "--quiet", "--all", "--message=Upstream", in: world.origin)
        let upstream = try await world.run("rev-parse", "HEAD", in: world.origin)
        try await world.run("update-index", "--cacheinfo", "160000,\(upstream),\(path)", in: world.parent)
        let (_, read) = try await listed(session, in: world.parent)

        #expect(read[0].recorded == (try id(upstream)))
        #expect(read[0].change == SubmoduleChange(checkout: [.commitChanged], distance: .commitMissing))
        #expect(read[0].file.submoduleStaging == .takesCommitsAway)
    }

    @Test func aSubmoduleThatIsntCheckedOutListsWithoutACommit() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        let linked = try await linkedWorktree(world)
        let (unread, read) = try await listed(session, in: linked)

        let notCheckedOut = Submodule(
            name: path, path: path, address: world.origin, recorded: try id(world.commits[4]), checkedOut: nil,
            change: SubmoduleChange(checkout: [], distance: .notCheckedOut)
        )
        // There's nothing more to read, so it's as it lists.
        #expect(unread == [notCheckedOut])
        #expect(read == [notCheckedOut])
        #expect(unread[0].isRead)
        #expect(try await session.submoduleStandings(of: unread, in: linked).isEmpty)
        // Neither staging nor anything else has something to do.
        #expect(unread[0].file.submoduleStaging == .nothingToStage)
    }

    @Test func eachWorktreeListsItsOwnSubmodules() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        let linked = try await linkedWorktree(world)
        try await world.checkOut(1)

        #expect(try await listed(session, in: world.parent).read[0].change.distance == .counted(ahead: 0, behind: 3))
        #expect(try await listed(session, in: linked).read[0].checkedOut == nil)

        // Checked out in the linked worktree, and recorded there at another
        // commit, which the parent's worktree doesn't hear of.
        try await world.run("submodule", "--quiet", "update", "--init", in: linked)
        try await world.run("checkout", "--quiet", "--detach", world.commits[2], in: linked + "/" + path)
        try await world.run("add", path, in: linked)
        let there = try await listed(session, in: linked).read[0]
        #expect(there.recorded == (try id(world.commits[2])))
        #expect(there.checkedOut == (try id(world.commits[2])))
        #expect(there.change == SubmoduleChange(checkout: [], distance: .counted(ahead: 0, behind: 0)))

        let here = try await listed(session, in: world.parent).read[0]
        #expect(here.recorded == (try id(world.commits[4])))
        #expect(here.checkedOut == (try id(world.commits[1])))
        #expect(here.change.distance == .counted(ahead: 0, behind: 3))
    }

    @Test func anAddressLeavesOutAUserNameAndPassword() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        // git's own settings say where a clone really gets it from.
        try await world.run("config", "submodule.\(path).url", "https://sam:secret-token@example.com/tools/parser.git", in: world.parent)
        #expect(try await session.submodules(in: world.parent)[0].address == "example.com/tools/parser.git")

        // Without one there, it's what `.gitmodules` says, which can be
        // relative to the parent's remote.
        try await world.run("config", "--unset", "submodule.\(path).url", in: world.parent)
        try await world.run("config", "--file", ".gitmodules", "submodule.\(path).url", "../parser.git", in: world.parent)
        #expect(try await session.submodules(in: world.parent)[0].address == "../parser.git")
    }

    @Test func onlyPathsThatGitmodulesNamesAndTheIndexRecordsAreSubmodules() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        // A second one, named for something other than its path, and a path
        // with a slash at its end.
        try await world.run("submodule", "--quiet", "add", "--name", "tools.lexer", world.origin, "lib/lexer", in: world.parent)
        try await world.run("config", "--file", ".gitmodules", "submodule.\(path).path", path + "/", in: world.parent)
        // One that `.gitmodules` names and the index doesn't record, and a
        // folder that's named there and is an ordinary folder.
        try await world.run("config", "--file", ".gitmodules", "submodule.gone.path", "vendor/gone", in: world.parent)
        try await world.run("config", "--file", ".gitmodules", "submodule.gone.url", world.origin, in: world.parent)
        try FileManager.default.createDirectory(atPath: world.parent + "/docs", withIntermediateDirectories: true)
        try Data("notes\n".utf8).write(to: URL(filePath: world.parent + "/docs/notes.txt"))
        try await world.run("add", "docs/notes.txt", in: world.parent)
        try await world.run("config", "--file", ".gitmodules", "submodule.docs.path", "docs", in: world.parent)

        let listed = try await session.submodules(in: world.parent)
        #expect(listed.map(\.path) == ["lib/lexer", path])
        #expect(listed.map(\.name) == ["tools.lexer", path])
        #expect(listed.allSatisfy { $0.checkedOut != nil })
    }

    @Test func aSubmoduleThatStatusIgnoresStillListsHowItStands() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        try await world.checkOut(1)
        try world.writeInside("notes\n", to: "Notes.md")
        // With this set, the parent's status has no row for the submodule.
        try await world.run("config", "submodule.\(path).ignore", "all", in: world.parent)
        #expect(try await session.status(in: world.parent).fileCount == 0)

        // The section asks the checkout itself, so its row still says.
        let (_, read) = try await listed(session, in: world.parent)
        #expect(read[0].change == SubmoduleChange(
            checkout: [.commitChanged, .untrackedFiles], distance: .counted(ahead: 0, behind: 3), filesInside: 1
        ))
    }

    @Test func aWorktreeWithoutGitmodulesRunsNothing() async throws {
        let world = try await SubmoduleRepository.make()
        let log = CommandLog()
        // The submodule's own repository has no submodules.
        let session = try await RepositorySession.open(containing: world.origin, git: try await TestGit.make(log: log))
        let ran = log.entries.count
        #expect(try await session.submodules(in: world.origin).isEmpty)
        #expect(log.entries.count == ran)
    }

    @Test func listingSubmodulesLeavesTheirIndexesAlone() async throws {
        let world = try await SubmoduleRepository.make()
        let session = try await open(world)
        // The same contents with a newer date, which `git status` would write
        // into the index if it took the lock.
        try world.writeInside((1...5).map { "line \($0)\n" }.joined(), to: "lib.txt")
        try world.writeInside("notes\n", to: "Notes.md")
        var indexes: [(file: String, before: Data)] = []
        for folder in [world.parent, world.checkout] {
            let index = try await world.run("rev-parse", "--path-format=absolute", "--git-path", "index", in: folder)
            indexes.append((index, try Data(contentsOf: URL(filePath: index))))
        }

        #expect(try await listed(session, in: world.parent).read[0].change.filesInside == 1)
        for index in indexes {
            #expect(try Data(contentsOf: URL(filePath: index.file)) == index.before)
        }
    }
}
