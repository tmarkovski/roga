import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import DiffUI
@testable import YagaUI

/// Selecting the files of a commit, and what the diff panel shows of them.
@Suite(.timeLimit(.minutes(1)))
struct SelectedFileTests {
    /// A commit of the `changes` repository, which changes files in every way.
    func selected(_ tag: String) async throws -> SelectedCommit {
        let repository = try await Fixture.repository("changes")
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        let commit = SelectedCommit(session: session)
        commit.show(try await id(tag, session))
        await settled(commit)
        return commit
    }

    func id(_ tag: String, _ session: RepositorySession) async throws -> ObjectID {
        let command = GitCommand("rev-parse", tag + "^{commit}", in: session.location.commonDirectory)
        return try #require(ObjectID(hex: try await session.git.text(command)))
    }

    func settled(_ commit: SelectedCommit) async {
        await commit.loading?.value
        await commit.selectedFile.loading?.value
    }

    func files(_ commit: SelectedCommit) throws -> [DiffFile] {
        guard case .loaded(let files) = commit.files else {
            throw TestError("Files aren't loaded: \(commit.files)")
        }
        return files
    }

    func select(_ path: String, _ commit: SelectedCommit) async throws {
        commit.select(try #require(try files(commit).first { $0.path == path }))
        await settled(commit)
    }

    struct TestError: Error {
        var description: String
        init(_ description: String) { self.description = description }
    }

    func shownText(_ commit: SelectedCommit) -> String? {
        guard case .patch(let document) = commit.selectedFile.shown?.content else { return nil }
        return document.storage.string
    }

    func shownNote(_ commit: SelectedCommit) -> String? {
        guard case .note(let note) = commit.selectedFile.shown?.content else { return nil }
        return note
    }

    @Test func selectsTheFirstFileOfACommit() async throws {
        let commit = try await selected("every-way")
        #expect(commit.selectedFile.file?.path == "image.bin")
        #expect(commit.selectedFile.shown?.file.path == "image.bin")
    }

    @Test func showsTheChangesToASelectedFile() async throws {
        let commit = try await selected("every-way")
        try await select("with space.txt", commit)
        #expect(commit.selectedFile.file?.path == "with space.txt")
        #expect(commit.selectedFile.shown?.file.path == "with space.txt")
        #expect(shownText(commit) == "@@ -1 +1,2 @@\nkeep\nmore\n")
        #expect(!commit.selectedFile.isWaiting)
    }

    @Test func showsARenamedFileAgainstItsOldPath() async throws {
        let commit = try await selected("every-way")
        try await select("lib/moved.txt", commit)
        #expect(shownText(commit)?.contains("seven") == true)
        #expect(shownText(commit)?.contains("one") == false)
    }

    @Test func saysWhyThereAreNoLinesToShow() async throws {
        let commit = try await selected("every-way")
        #expect(shownNote(commit)?.contains("binary") == true)
        try await select("run.sh", commit)
        #expect(shownNote(commit) == "Only this file's mode changed.")
    }

    @Test(arguments: [
        (DiffFile.Status.added, 0 as UInt32, 0o100644 as UInt32, "added"),
        (.deleted, 0o100644, 0, "deleted"),
        (.renamed(similarity: 100), 0o100644, 0o100644, "moved"),
        (.copied(similarity: 100), 0o100644, 0o100644, "copy"),
    ])
    func saysSomethingAboutFilesWithNoChangedLines(status: DiffFile.Status, oldMode: UInt32, newMode: UInt32, word: String) throws {
        let file = DiffFile(status: status, path: "a", oldMode: oldMode, newMode: newMode, lines: .init(added: 0, removed: 0))
        #expect(try #require(SelectedFile.note(for: file)).contains(word))
    }

    @Test func comparesAFileWithChangedLines() {
        let file = DiffFile(status: .modified, path: "a", oldMode: 0o100644, newMode: 0o100755, lines: .init(added: 1, removed: 0))
        #expect(SelectedFile.note(for: file) == nil)
    }

    @Test func selectsNothingInACommitWithoutFiles() async throws {
        let commit = try await selected("empty")
        #expect(commit.selectedFile.file == nil)
        #expect(commit.selectedFile.shown == nil)
        #expect(!commit.selectedFile.isWaiting)
    }

    @Test func forgetsTheFileWhenNoCommitIsSelected() async throws {
        let commit = try await selected("every-way")
        commit.show(nil)
        #expect(commit.selectedFile.file == nil)
        #expect(commit.selectedFile.shown == nil)
    }

    @Test func goesToTheFirstFileOfTheNextCommit() async throws {
        let commit = try await selected("every-way")
        try await select("with space.txt", commit)
        let repository = try await Fixture.repository("changes")
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        commit.show(try await id("merge", session))
        // What's showing stays until the next commit's file arrives.
        #expect(commit.selectedFile.shown?.file.path == "with space.txt")
        await settled(commit)
        #expect(commit.selectedFile.shown?.file.path == "side.txt")
        #expect(shownText(commit) == "@@ -0,0 +1 @@\nside\n")
    }

    @Test func keepsWhatsShowingUntilTheNextFileArrives() async throws {
        let commit = try await selected("every-way")
        try await select("with space.txt", commit)
        commit.select(try #require(try files(commit).first { $0.path == "src/new.txt" }))
        #expect(commit.selectedFile.file?.path == "src/new.txt")
        #expect(commit.selectedFile.shown?.file.path == "with space.txt")
        await settled(commit)
        #expect(commit.selectedFile.shown?.file.path == "src/new.txt")
    }

    @Test func showsTheLastFileSelected() async throws {
        // Stepping through the list, faster than git can answer.
        let commit = try await selected("every-way")
        var cancelled: [Task<Void, Never>] = []
        for file in try files(commit) {
            commit.select(file)
            if let loading = commit.selectedFile.loading { cancelled.append(loading) }
        }
        let last = try #require(try files(commit).last)
        for loading in cancelled { await loading.value }
        #expect(commit.selectedFile.file == last)
        #expect(commit.selectedFile.shown?.file == last)
        #expect(!commit.selectedFile.isWaiting)
    }

    @Test func doesntKeepWaitingAfterAFileArrives() async throws {
        // The patience for a load that was cancelled mustn't go off later, and
        // leave the panel saying it's loading.
        let commit = try await selected("every-way")
        try await select("with space.txt", commit)
        commit.select(try #require(try files(commit).first { $0.path == "src/new.txt" }))
        try await select("src/gone.txt", commit)
        try await Task.sleep(for: SelectedFile.patience + .milliseconds(100))
        #expect(!commit.selectedFile.isWaiting)
    }

    @Test func movesThroughTheList() async throws {
        let commit = try await selected("every-way")
        let paths = try files(commit).map(\.path)
        commit.selectFile(by: 1)
        #expect(commit.selectedFile.file?.path == paths[1])
        #expect(commit.fileSteps == 1)
        commit.selectFile(by: -1)
        #expect(commit.selectedFile.file?.path == paths[0])

        // It stops at the ends.
        let steps = commit.fileSteps
        commit.selectFile(by: -1)
        #expect(commit.selectedFile.file?.path == paths[0])
        #expect(commit.fileSteps == steps)
        await settled(commit)
    }

    @Test func staysOnTheLastFileOfTheList() async throws {
        let commit = try await selected("every-way")
        let last = try #require(try files(commit).last)
        commit.select(last)
        commit.selectFile(by: 1)
        #expect(commit.selectedFile.file == last)
        await settled(commit)
    }

    @Test func doesntMoveThroughAListStillLoading() async throws {
        let repository = try await Fixture.repository("changes")
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        let commit = SelectedCommit(session: session)
        commit.selectFile(by: 1)
        #expect(commit.selectedFile.file == nil)
    }

    @Test func saysWhenGitCantShowAFile() async throws {
        let repository = try await Fixture.repository("changes")
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        let selection = SelectedFile(session: session)
        let unknown = ObjectID(hex: String(repeating: "1", count: 40))
        selection.show(DiffFile(status: .modified, path: "a", oldMode: 0o100644, newMode: 0o100644, lines: .init(added: 1, removed: 1)), in: unknown)
        await selection.loading?.value
        guard case .failed = selection.shown?.content else {
            Issue.record("It shows \(String(describing: selection.shown?.content))")
            return
        }
        #expect(!selection.isWaiting)
    }

    @Test func findsOnlyInAPatch() async throws {
        let commit = try await selected("every-way")
        #expect(!commit.selectedFile.canFind)
        try await select("with space.txt", commit)
        #expect(commit.selectedFile.canFind)
        commit.selectedFile.find()
        #expect(commit.selectedFile.findRequests == 1)
    }
}
