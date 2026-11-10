import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
import ThemeUI
@testable import DiffUI
@testable import RogaUI

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
        guard case .loaded = commit.files else {
            throw TestError("Files aren't loaded: \(commit.files)")
        }
        return commit.files.all
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
    }

    /// What the search says after looking for some text in `with space.txt`,
    /// which shows `@@ -1 +1,2 @@`, `keep` and `more`.
    func searching(for text: String) async throws -> SelectedFile {
        let commit = try await selected("every-way")
        try await select("with space.txt", commit)
        let selection = commit.selectedFile
        selection.find()
        selection.findText = text
        await selection.searching?.value
        return selection
    }

    @Test func opensTheBoxWithTheKeyboardInIt() async throws {
        let commit = try await selected("every-way")
        let selection = commit.selectedFile
        #expect(!selection.isFindShown)
        selection.toggleFind()
        #expect(selection.isFindShown)
        #expect(selection.wantsFindFocus)
    }

    @Test func goesThroughTheMatchesAndAround() async throws {
        let selection = try await searching(for: "E")
        #expect(selection.matchesNote == "1 of 3")
        let steps = selection.matchSteps
        selection.findNext()
        #expect(selection.matchesNote == "2 of 3")
        selection.findNext()
        selection.findNext()
        #expect(selection.matchesNote == "1 of 3")
        selection.findPrevious()
        #expect(selection.matchesNote == "3 of 3")
        #expect(selection.matchSteps == steps + 4)
    }

    @Test func changingTheTextStaysAroundTheSamePlace() async throws {
        let selection = try await searching(for: "e")
        selection.findNext()
        selection.findNext()
        #expect(selection.matchesNote == "3 of 3")

        selection.findText = "E"
        await selection.searching?.value
        #expect(selection.matchesNote == "3 of 3")
    }

    @Test func saysWhenNothingMatches() async throws {
        let selection = try await searching(for: "zzz")
        #expect(selection.matchesNote == "No matches")
        #expect(!selection.hasMatches)
        let steps = selection.matchSteps
        selection.findNext()
        selection.findPrevious()
        #expect(selection.matchSteps == steps)
    }

    @Test func clearingKeepsTheBoxOpen() async throws {
        let selection = try await searching(for: "e")
        selection.findText = ""
        await selection.searching?.value
        #expect(selection.isFindShown)
        #expect(selection.matches == nil)
        #expect(selection.matchesNote == nil)
    }

    @Test func closingStopsMarkingWhatItFound() async throws {
        let selection = try await searching(for: "e")
        let closes = selection.findCloses
        selection.toggleFind()
        #expect(!selection.isFindShown)
        #expect(selection.findText.isEmpty)
        #expect(selection.matches == nil)
        #expect(selection.findCloses == closes + 1)
    }

    @Test func looksInTheNextFileToo() async throws {
        let commit = try await selected("every-way")
        try await select("with space.txt", commit)
        let selection = commit.selectedFile
        selection.find()
        selection.findText = "e"
        await selection.searching?.value
        selection.findNext()
        let first = try #require(selection.matches?.document)

        try await select("lib/moved.txt", commit)
        await selection.searching?.value
        #expect(selection.isFindShown)
        #expect(selection.matches?.document !== first)
        #expect(selection.matches?.current == 0)
    }

    @Test func marksNothingInAFileWithNoPatch() async throws {
        let commit = try await selected("every-way")
        let note = try #require(commit.selectedFile.file?.path)
        try await select("with space.txt", commit)
        let selection = commit.selectedFile
        selection.find()
        selection.findText = "e"
        await selection.searching?.value
        #expect(selection.hasMatches)

        try await select(note, commit)
        #expect(!selection.canFind)
        #expect(selection.isFindShown)
        #expect(selection.matches == nil)
    }

    func shownDocument(_ commit: SelectedCommit) -> DiffDocument? {
        guard case .patch(let document) = commit.selectedFile.shown?.content else { return nil }
        return document
    }

    /// A diff built before another code font was chosen is built again in that
    /// one, as the same file at the same place (decision 73).
    @Test func buildsTheDiffAgainInAnotherCodeFont() async throws {
        let commit = try await selected("every-way")
        try await select("with space.txt", commit)
        let selection = commit.selectedFile
        let first = try #require(shownDocument(commit))
        #expect(first.font == .standard)

        // There's nothing to do while the font is the one it's in.
        selection.followCodeFont()
        await selection.loading?.value
        #expect(shownDocument(commit) === first)

        let menlo = CodeFont(family: "Menlo", size: 16)
        selection.codeFont = { menlo }
        selection.followCodeFont()
        await selection.loading?.value
        let second = try #require(shownDocument(commit))
        #expect(second !== first)
        #expect(second.font == menlo)
        #expect(second.storage.string == first.storage.string)
        #expect(selection.shown?.isUpdate == true)

        // Following it again builds nothing more.
        selection.followCodeFont()
        await selection.loading?.value
        #expect(shownDocument(commit) === second)

        // A file selected afterwards is built in it from the start.
        try await select("lib/moved.txt", commit)
        #expect(shownDocument(commit)?.font == menlo)
        #expect(selection.shown?.isUpdate == false)
    }

    /// A file with no lines to compare has nothing in the code font.
    @Test func leavesANoteAloneWhenTheCodeFontChanges() async throws {
        let commit = try await selected("every-way")
        let selection = commit.selectedFile
        #expect(shownNote(commit) != nil)
        let loading = selection.loading
        selection.codeFont = { CodeFont(size: 18) }
        selection.followCodeFont()
        #expect(selection.loading == loading)
        #expect(shownNote(commit) != nil)
    }
}
