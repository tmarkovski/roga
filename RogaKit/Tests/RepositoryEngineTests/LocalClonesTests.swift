import Foundation
import GitRunner
import RepositoryEngine
import TestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LocalClonesTests {
    let folder: String
    let git: Git

    init() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "roga-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let resolved = try #require(realpath(temporary.path(percentEncoded: false), nil))
        defer { free(resolved) }
        folder = String(cString: resolved)
        git = try await TestGit.make()
    }

    @discardableResult
    func makeClone(_ path: String) async throws -> String {
        let clone = folder + "/" + path
        try FileManager.default.createDirectory(atPath: clone, withIntermediateDirectories: true)
        try await git.run(GitCommand("init", "--quiet", in: clone))
        return clone
    }

    @Test func findsClones() async throws {
        try await makeClone("api")
        try await makeClone("scratch")
        let clones = await LocalClones.find(in: [folder])
        #expect(clones.map(\.name).sorted() == ["api", "scratch"])
        #expect(clones.allSatisfy { $0.lastUsed != nil })
    }

    @Test func looksOnlyOneLevelDown() async throws {
        try await makeClone("near")
        try await makeClone("far/away")
        let clones = await LocalClones.find(in: [folder])
        #expect(clones.map(\.name) == ["near"])
    }

    @Test func countsTheFolderItself() async throws {
        let clone = try await makeClone("here")
        let clones = await LocalClones.find(in: [clone])
        #expect(clones.map(\.path) == [clone])
    }

    @Test func listsAFolderFoundTwiceOnce() async throws {
        try await makeClone("api")
        let clones = await LocalClones.find(in: [folder, folder + "/api"])
        #expect(clones.map(\.name) == ["api"])
    }

    @Test func leavesOutLinkedWorktrees() async throws {
        let clone = try await makeClone("api")
        try await git.run(GitCommand("-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--quiet", "--allow-empty", "-m", "First", in: clone))
        try await git.run(GitCommand("worktree", "add", "--quiet", folder + "/notes", "-b", "notes", in: clone))
        let clones = await LocalClones.find(in: [folder])
        #expect(clones.map(\.name) == ["api"])
    }

    @Test func listsTheLatestUsedFirst() async throws {
        let older = try await makeClone("older")
        let newer = try await makeClone("newer")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older + "/.git/HEAD")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: newer + "/.git/HEAD")
        let clones = await LocalClones.find(in: [folder])
        #expect(clones.map(\.name) == ["newer", "older"])
    }

    @Test func findsManyClones() async throws {
        for index in 0..<20 {
            try await makeClone("clone\(index)")
        }
        let clones = await LocalClones.find(in: [folder])
        #expect(clones.count == 20)
    }

    @Test func aFolderThatsGoneFindsNothing() async throws {
        let clones = await LocalClones.find(in: [folder + "/gone"])
        #expect(clones.isEmpty)
    }
}
