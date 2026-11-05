import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import DiffUI
@testable import RogaUI

/// Discarding from the panels: what asks, what moves, and what Undo brings back.
@Suite(.timeLimit(.minutes(1)))
struct DiscardTests {
    static let numbers = (1...60).map { "\($0)\n" }.joined()

    struct Worktree {
        var model: RepositoryModel
        var path: String
        var changes: SelectedChanges { model.selectedChanges }
        var selectedFile: SelectedFile { model.selectedFile }
        var branch: BranchModel { model.branch }

        func read(_ file: String) throws -> String {
            try String(contentsOfFile: path + "/" + file, encoding: .utf8)
        }

        func write(_ text: String, to file: String) throws {
            let url = URL(filePath: path + "/" + file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func exists(_ file: String) -> Bool {
            FileManager.default.fileExists(atPath: path + "/" + file)
        }

        func short() async throws -> [String] {
            try await TestGit.make().text(GitCommand("status", "--short", "--untracked-files=all", in: path))
                .split(separator: "\n").map(String.init)
        }

        func git(_ arguments: String...) async throws {
            _ = try await TestGit.make().run(GitCommand(arguments, in: path))
        }

        /// Lets everything that's been started finish.
        func settled() async {
            await changes.preparingDiscard?.value
            await changes.applyingIndexChanges?.value
            await model.check?.value
            await changes.applyingIndexChanges?.value
            await changes.loading?.value
            await selectedFile.loading?.value
        }

        /// Loads the worktree with its row for uncommitted changes selected.
        func open() async {
            await model.appear()
            model.selectRow(0)
            await settled()
        }

        var unstaged: [DiffFile] { changes.loaded?.unstaged ?? [] }
        var untracked: [DiffFile] { changes.loaded?.untracked ?? [] }
        var staged: [DiffFile] { changes.loaded?.staged ?? [] }

        func hunkHeaders() throws -> [Int] {
            let patch = try #require(selectedFile.shownPatch)
            return patch.lines.indices.filter { patch.lines[$0].kind == .hunkHeader }
        }
    }

    /// A worktree with files that hold the numbers, and a Trash of its own.
    func worktree(files: [String: String] = ["a.txt": numbers, "b.txt": "b\n", "src/c.txt": "c\n", "src/d.txt": "d\n"]) async throws -> Worktree {
        let folder = try makeTemporaryFolder()
        let path = folder + "/work"
        let trashFolder = folder + "/trash"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: trashFolder, withIntermediateDirectories: true)
        let git = try await TestGit.make()
        _ = try await git.run(GitCommand("init", "--quiet", "--initial-branch=main", in: path))
        _ = try await git.run(GitCommand("config", "user.name", "T", in: path))
        _ = try await git.run(GitCommand("config", "user.email", "t@example.com", in: path))
        let trash = FileTrash { url in
            let moved = URL(filePath: trashFolder).appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: moved)
            return moved
        }
        let session = try await RepositorySession.open(containing: path, git: git, trash: trash)
        let model = RepositoryModel(session: session, worktree: path, fetchesByItself: { false }, drafts: .none)
        model.branch.timeToPlayHouse = { _ in .zero }
        let work = Worktree(model: model, path: path)
        for (file, text) in files { try work.write(text, to: file) }
        try await work.git("add", "--all")
        try await work.git("commit", "--quiet", "--message=First")
        return work
    }

    func numbers(replacing lines: [Int: String]) -> String {
        (1...60).map { (lines[$0] ?? String($0)) + "\n" }.joined()
    }

    // MARK: One file

    @Test func aFileGoesWithoutAskingAndUndoBringsItBack() async throws {
        let work = try await worktree()
        try work.write("changed\n", to: "b.txt")
        await work.open()
        let file = try #require(work.unstaged.first)

        work.changes.discard(file, in: .unstaged)
        #expect(work.changes.pendingDiscard == nil)
        // It's gone from the list before git has done anything.
        #expect(work.unstaged.isEmpty)
        await work.settled()
        #expect(try work.read("b.txt") == "b\n")
        #expect(work.branch.finished == "Discarded b.txt")
        #expect(work.branch.undoFinished != nil)
        #expect(!work.model.hasWorkingTreeRow)

        try #require(work.branch.undoFinished).perform()
        await work.settled()
        #expect(try work.read("b.txt") == "changed\n")
        #expect(work.branch.finished == "Brought back b.txt")
        #expect(work.branch.undoFinished == nil)
        // The row came back, and it's selected again.
        #expect(work.model.hasWorkingTreeRow)
        #expect(work.changes.isSelected)
        #expect(work.unstaged.map(\.path) == ["b.txt"])
    }

    @Test func theSelectionMovesToWhatTookTheFilesPlace() async throws {
        let work = try await worktree()
        try work.write("changed\n", to: "b.txt")
        try work.write("changed\n", to: "src/c.txt")
        try work.write("changed\n", to: "src/d.txt")
        await work.open()
        #expect(work.selectedFile.file?.path == "b.txt")

        work.changes.discardSelectedFile()
        #expect(work.selectedFile.file?.path == "src/c.txt")
        await work.settled()
        #expect(work.unstaged.map(\.path) == ["src/c.txt", "src/d.txt"])
    }

    @Test func aFileThatsStagedToo_keepsTheRowAndGoesBackToWhatsStaged() async throws {
        let work = try await worktree()
        try work.write("staged\n", to: "b.txt")
        try await work.git("add", "b.txt")
        try work.write("staged\nunstaged\n", to: "b.txt")
        await work.open()
        let file = try #require(work.unstaged.first)
        work.changes.discard(file, in: .unstaged)
        await work.settled()
        #expect(try work.read("b.txt") == "staged\n")
        #expect(work.model.hasWorkingTreeRow)
        #expect(work.staged.map(\.path) == ["b.txt"])
        #expect(work.unstaged.isEmpty)
    }

    @Test func anUntrackedFileSaysItWentToTheTrash() async throws {
        let work = try await worktree()
        try work.write("notes\n", to: "notes.md")
        await work.open()
        work.changes.discard(try #require(work.untracked.first), in: .untracked)
        await work.settled()
        #expect(!work.exists("notes.md"))
        #expect(work.branch.finished == "Moved notes.md to the Trash")

        work.changes.undoDiscard()
        await work.settled()
        #expect(try work.read("notes.md") == "notes\n")
    }

    @Test func aStagedFileOffersNothingToDiscard() async throws {
        let work = try await worktree()
        try work.write("staged\n", to: "b.txt")
        try await work.git("add", "b.txt")
        await work.open()
        #expect(work.selectedFile.group == .staged)
        #expect(!work.changes.canDiscardSelectedFile)
        work.changes.discardSelectedFile()
        await work.settled()
        #expect(try work.read("b.txt") == "staged\n")
    }

    @Test func undoGoesBackThroughSeveralInTurn() async throws {
        let work = try await worktree()
        try work.write("changed\n", to: "b.txt")
        try work.write("changed\n", to: "src/c.txt")
        await work.open()
        for file in work.unstaged { work.changes.discard(file, in: .unstaged) }
        await work.settled()
        #expect(work.changes.discards.count == 2)

        work.changes.undoDiscard()
        await work.settled()
        #expect(work.branch.finished == "Brought back c.txt")
        #expect(try work.read("b.txt") == "b\n")
        work.changes.undoDiscard()
        await work.settled()
        #expect(try work.read("b.txt") == "changed\n")
        #expect(try work.read("src/c.txt") == "changed\n")
        #expect(work.changes.discards.isEmpty)
    }

    @Test func anUndoThatFailsStaysReady() async throws {
        let work = try await worktree()
        try work.write("changed\n", to: "b.txt")
        await work.open()
        work.changes.discard(try #require(work.unstaged.first), in: .unstaged)
        await work.settled()

        try work.write("written since\n", to: "b.txt")
        work.changes.undoDiscard()
        await work.settled()
        #expect(work.branch.failure?.title == "Can't undo the discard")
        #expect(try work.read("b.txt") == "written since\n")
        #expect(work.changes.discards.count == 1)
        work.branch.failure = nil

        try await work.git("checkout", "--", "b.txt")
        work.changes.undoDiscard()
        await work.settled()
        #expect(work.branch.failure == nil)
        #expect(try work.read("b.txt") == "changed\n")
    }

    // MARK: Hunks

    @Test func aHunkGoesWithoutAskingAndTheFileStays() async throws {
        let work = try await worktree()
        try work.write(numbers(replacing: [3: "three", 30: "thirty"]), to: "a.txt")
        await work.open()
        let headers = try work.hunkHeaders()
        #expect(headers.count == 2)
        #expect(work.changes.hunkDiscard != nil)

        work.changes.discardHunk(at: headers[1])
        await work.settled()
        #expect(try work.read("a.txt") == numbers(replacing: [3: "three"]))
        #expect(work.changes.pendingDiscard == nil)
        #expect(work.branch.finished == "Discarded a hunk of a.txt")
        #expect(work.selectedFile.file?.path == "a.txt")
        #expect(try work.hunkHeaders().count == 1)

        work.changes.undoDiscard()
        await work.settled()
        #expect(try work.read("a.txt") == numbers(replacing: [3: "three", 30: "thirty"]))
        #expect(try work.hunkHeaders().count == 2)
    }

    @Test func theLastHunkTakesTheFileOffTheList() async throws {
        let work = try await worktree()
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        try work.write("changed\n", to: "b.txt")
        await work.open()
        #expect(work.selectedFile.file?.path == "a.txt")
        work.changes.discardHunk(at: try work.hunkHeaders()[0])
        // The next file takes its place, as it does for a file discarded from its row.
        #expect(work.selectedFile.file?.path == "b.txt")
        await work.settled()
        #expect(work.unstaged.map(\.path) == ["b.txt"])
    }

    @Test func theSameHunkCantGoTwiceBeforeTheNewPatchIsRead() async throws {
        let work = try await worktree()
        try work.write(numbers(replacing: [3: "three", 30: "thirty"]), to: "a.txt")
        await work.open()
        let headers = try work.hunkHeaders()
        work.changes.discardHunk(at: headers[0])
        work.changes.discardHunk(at: headers[0])
        work.changes.discardHunk(at: headers[1])
        await work.settled()
        #expect(work.branch.failure == nil)
        #expect(try work.read("a.txt") == numbers(replacing: [30: "thirty"]))
        #expect(work.changes.discards.count == 1)
    }

    @Test func aHunkCanGoAgainAfterThePatchComesBackToTheSame() async throws {
        let work = try await worktree()
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        try work.write("changed\n", to: "b.txt")
        await work.open()
        work.changes.discardHunk(at: try work.hunkHeaders()[0])
        await work.settled()
        work.changes.undoDiscard()
        await work.settled()
        work.changes.select(try #require(work.unstaged.first { $0.path == "a.txt" }), in: .unstaged)
        await work.settled()
        work.changes.discardHunk(at: try work.hunkHeaders()[0])
        await work.settled()
        #expect(try work.read("a.txt") == Self.numbers)
    }

    @Test func aHunkWhoseLinesChangedSaysSoAndChangesNothing() async throws {
        let work = try await worktree()
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        await work.open()
        let header = try work.hunkHeaders()[0]
        try work.write(numbers(replacing: [3: "an agent got here first"]), to: "a.txt")
        work.changes.discardHunk(at: header)
        await work.settled()
        #expect(work.branch.failure?.title == "Can't discard the hunk of a.txt")
        #expect(try work.read("a.txt") == numbers(replacing: [3: "an agent got here first"]))
        #expect(work.changes.discards.isEmpty)
    }

    @Test func onlyAModifiedUnstagedFilesHunksCanGo() async throws {
        let work = try await worktree()
        try FileManager.default.removeItem(atPath: work.path + "/b.txt")
        try work.write(numbers(replacing: [3: "three"]), to: "a.txt")
        try await work.git("add", "a.txt")
        try work.write("new\n", to: "new.txt")
        await work.open()

        #expect(work.selectedFile.file?.path == "b.txt")
        #expect(work.selectedFile.group == .unstaged)
        #expect(work.changes.hunkDiscard == nil)
        work.changes.select(try #require(work.untracked.first), in: .untracked)
        await work.settled()
        #expect(work.changes.hunkDiscard == nil)
        work.changes.select(try #require(work.staged.first), in: .staged)
        await work.settled()
        #expect(work.changes.hunkDiscard == nil)
    }

    // MARK: Folders and headings

    @Test func aFolderAsksFirstAndUndoBringsItAllBack() async throws {
        let work = try await worktree()
        try work.write("changed\n", to: "src/c.txt")
        try work.write("changed\n", to: "src/d.txt")
        try work.write("changed\n", to: "b.txt")
        await work.open()

        work.changes.askToDiscardFolder("src", in: .unstaged)
        let pending = try #require(work.changes.pendingDiscard)
        guard case .files(let files, _, .folder("src")) = pending else {
            Issue.record("It should ask about the folder.")
            return
        }
        #expect(files.map(\.path) == ["src/c.txt", "src/d.txt"])
        #expect(try work.read("src/c.txt") == "changed\n")

        work.changes.confirmDiscard()
        await work.settled()
        #expect(try work.read("src/c.txt") == "c\n")
        #expect(try work.read("b.txt") == "changed\n")
        #expect(work.branch.finished == "Discarded 2 files")

        work.changes.undoDiscard()
        await work.settled()
        #expect(try work.read("src/d.txt") == "changed\n")
    }

    @Test func aFolderWithOneFileDoesntAsk() async throws {
        let work = try await worktree()
        try work.write("changed\n", to: "src/c.txt")
        await work.open()
        work.changes.askToDiscardFolder("src", in: .unstaged)
        #expect(work.changes.pendingDiscard == nil)
        await work.settled()
        #expect(try work.read("src/c.txt") == "c\n")
    }

    @Test func aHeadingAsksAndActsOnlyOnItself() async throws {
        let work = try await worktree()
        try work.write("changed\n", to: "b.txt")
        try work.write("changed\n", to: "src/c.txt")
        try work.write("notes\n", to: "notes.md")
        await work.open()
        work.changes.askToDiscardAll(in: .unstaged)
        #expect(work.changes.pendingDiscard != nil)
        work.changes.confirmDiscard()
        await work.settled()
        #expect(try work.read("b.txt") == "b\n")
        #expect(try work.read("notes.md") == "notes\n")
    }

    @Test func aFilterLimitsAHeading() async throws {
        let work = try await worktree()
        try work.write("changed\n", to: "b.txt")
        try work.write("changed\n", to: "src/c.txt")
        try work.write("changed\n", to: "src/d.txt")
        await work.open()
        work.model.fileList.filter = "src"
        work.changes.askToDiscardAll(in: .unstaged)
        guard case .files(let files, _, .matchingFilter) = work.changes.pendingDiscard else {
            Issue.record("It should ask about what the filter leaves.")
            return
        }
        #expect(files.map(\.path) == ["src/c.txt", "src/d.txt"])
    }

    @Test func cancellingChangesNothing() async throws {
        let work = try await worktree()
        try work.write("changed\n", to: "src/c.txt")
        try work.write("changed\n", to: "src/d.txt")
        await work.open()
        work.changes.askToDiscardFolder("src", in: .unstaged)
        let content = work.changes.dialog(for: try #require(work.changes.pendingDiscard))
        content.dismiss()
        #expect(work.changes.pendingDiscard == nil)
        await work.settled()
        #expect(try work.read("src/c.txt") == "changed\n")
    }

    @Test func aRepositoryInTheFolderStays() async throws {
        let work = try await worktree()
        try await work.git("worktree", "add", "--quiet", "-b", "side", "tools/inner")
        try work.write("notes\n", to: "tools/a.md")
        try work.write("notes\n", to: "tools/b.md")
        await work.open()
        work.changes.askToDiscardFolder("tools", in: .untracked)
        guard case .files(let files, _, _) = work.changes.pendingDiscard else {
            Issue.record("It should ask about the two files.")
            return
        }
        #expect(files.map(\.path) == ["tools/a.md", "tools/b.md"])
        work.changes.confirmDiscard()
        await work.settled()
        #expect(work.exists("tools/inner/.git"))
        #expect(work.untracked.map(\.path) == ["tools/inner/"])
    }

    // MARK: Everything

    @Test func everythingAsksAndUndoBringsItBack() async throws {
        let work = try await worktree()
        try work.write("staged\n", to: "b.txt")
        try await work.git("add", "b.txt")
        try work.write("staged\nunstaged\n", to: "b.txt")
        try work.write("new\n", to: "added.txt")
        try await work.git("add", "added.txt")
        try work.write("notes\n", to: "notes.md")
        await work.open()
        let before = try await work.short()

        work.changes.askToDiscardEverything()
        await work.settled()
        #expect(work.changes.pendingDiscard != nil)
        #expect(try await work.short() == before)

        work.changes.confirmDiscard()
        await work.settled()
        #expect(try await work.short().isEmpty)
        #expect(!work.model.hasWorkingTreeRow)
        #expect(work.branch.finished == "Discarded all changes")
        // It's not selected any more, and the next commit down isn't a file to keep.
        #expect(!work.changes.isSelected)

        work.changes.undoDiscard()
        await work.settled()
        #expect(try await work.short() == before)
        #expect(work.model.hasWorkingTreeRow)
        #expect(work.changes.isSelected)
    }

    @Test func everythingWorksFromTheRowWithoutItsFilesLoaded() async throws {
        let work = try await worktree()
        try work.write("changed\n", to: "b.txt")
        await work.model.appear()
        await work.settled()
        #expect(!work.changes.isSelected)
        #expect(work.model.hasWorkingTreeRow)

        work.changes.askToDiscardEverything()
        await work.settled()
        work.changes.confirmDiscard()
        await work.settled()
        #expect(try work.read("b.txt") == "b\n")
        #expect(!work.model.hasWorkingTreeRow)
    }

    @Test func everythingWaitsWhileAMergeIsStuck() async throws {
        let work = try await worktree()
        try await work.git("switch", "--quiet", "-c", "side")
        try work.write("side\n", to: "b.txt")
        try await work.git("commit", "--quiet", "--all", "--message=Side")
        try await work.git("switch", "--quiet", "main")
        try work.write("main\n", to: "b.txt")
        try await work.git("commit", "--quiet", "--all", "--message=Main")
        var merge = GitCommand("merge", "side", in: work.path)
        merge.successStatuses = [0, 1]
        _ = try await TestGit.make().run(merge)
        await work.open()
        await work.model.check?.value
        work.model.becameActive()
        await work.settled()
        #expect(work.branch.unfinished != nil)

        #expect(!work.changes.canDiscardEverything())
        work.changes.askToDiscardEverything()
        await work.settled()
        #expect(work.changes.pendingDiscard == nil)
        #expect(FileManager.default.fileExists(atPath: work.path + "/.git/MERGE_HEAD"))
    }

    @Test func onlyARepositoryInsideLeavesNothingToAskAbout() async throws {
        let work = try await worktree()
        try await work.git("worktree", "add", "--quiet", "-b", "side", "inner")
        await work.open()
        #expect(work.model.hasWorkingTreeRow)
        work.changes.askToDiscardEverything()
        await work.settled()
        #expect(work.changes.pendingDiscard == nil)
    }

    // MARK: What the dialogs say

    func file(_ path: String, _ status: DiffFile.Status) -> DiffFile {
        DiffFile(status: status, path: path, oldMode: 0o100644, newMode: 0o100644, lines: .init(added: 1, removed: 0))
    }

    func changes() async throws -> SelectedChanges {
        try await worktree().changes
    }

    @Test func aFolderDialogNamesItsFilesAndTheCommand() async throws {
        let files = (1...7).map { file("src/\($0).txt", .modified) }
        let content = try await changes().dialog(for: .files(files, from: .unstaged, place: .folder("src")))
        #expect(content.title == "Discard 7 files in src?")
        #expect(content.cards[0].count == 6)
        #expect(content.cards[0].last == .more("and 2 more"))
        #expect(content.terminal == [
            .command(["restore", "--worktree", "--", "src/1.txt", "src/2.txt", "src/3.txt", "src/4.txt", "src/5.txt"]),
            .comment("and 2 more"),
        ])
        #expect(content.buttons.map(\.title) == ["Cancel", "Discard 7 files"])
        #expect(content.buttons.last?.kind == .destructive)
    }

    @Test func movingToTheTrashIsntRedAndHasNoCommand() async throws {
        let files = [file("a.md", .untracked), file("b.md", .untracked)]
        let content = try await changes().dialog(for: .files(files, from: .untracked, place: .heading))
        #expect(content.title == "Move 2 untracked files to the Trash?")
        #expect(content.terminal.isEmpty)
        #expect(content.buttons.last?.title == "Move to Trash")
        #expect(content.buttons.last?.kind == .primary)
    }

    @Test func everythingSaysWhatGoesWhere() async throws {
        let id = try #require(ObjectID(hex: String(repeating: "a", count: 40)))
        let everything = WorktreeChanges(
            head: id,
            fileCount: 6,
            unstaged: [file("a.txt", .modified), file("b.txt", .modified)],
            untracked: [file("notes.md", .untracked), DiffFile(status: .untracked, path: "inner/", oldMode: 0, newMode: 0, lines: .init(added: 0, removed: 0))],
            staged: [file("a.txt", .modified), file("new.txt", .added)]
        )
        let content = try await changes().dialog(for: .everything(everything))
        #expect(content.title == "Discard all uncommitted changes?")
        #expect(content.cards == [[
            .fact("2 changed files", "go back to HEAD"),
            .fact("1 new staged file", "is deleted"),
            .fact("1 untracked file", "goes to the Trash"),
        ]])
        #expect(content.terminal == [
            .command(["stash", "create"]),
            .command(["reset", "--hard"]),
            .comment("1 file goes to the Trash"),
        ])
        #expect(content.note?.plain == "inner/ stays, because Roga leaves repositories and submodules alone.")
        #expect(content.buttons.last?.kind == .destructive)
    }

    @Test func untrackedFilesAloneDontNeedARedButton() async throws {
        let everything = WorktreeChanges(fileCount: 1, untracked: [file("notes.md", .untracked)])
        let content = try await changes().dialog(for: .everything(everything))
        #expect(content.terminal.isEmpty)
        #expect(content.buttons.last?.kind == .primary)
    }

    // MARK: The lists, until git says for itself

    @Test func discardingCountsAFileThatsStagedToo() {
        let changes = WorktreeChanges(
            fileCount: 3,
            unstaged: [file("a.txt", .modified), file("b.txt", .modified)],
            untracked: [file("c.txt", .untracked)],
            staged: [file("a.txt", .modified)]
        )
        let discarded = changes.discarding([file("a.txt", .modified), file("b.txt", .modified)])
        #expect(discarded.unstaged.isEmpty)
        #expect(discarded.staged.map(\.path) == ["a.txt"])
        #expect(discarded.fileCount == 2)
    }

    @Test func discardingEverythingLeavesWhatRogaLeavesAlone() {
        let module = DiffFile(status: .modified, path: "module", oldMode: DiffFile.submoduleMode, newMode: DiffFile.submoduleMode, lines: .init(added: 0, removed: 0))
        let inner = DiffFile(status: .untracked, path: "inner/", oldMode: 0, newMode: 0, lines: .init(added: 0, removed: 0))
        let changes = WorktreeChanges(
            fileCount: 5,
            unstaged: [file("a.txt", .modified), module],
            untracked: [file("c.txt", .untracked), inner],
            staged: [file("d.txt", .added)]
        )
        let discarded = changes.discardingEverything()
        #expect(discarded.unstaged.map(\.path) == ["module"])
        #expect(discarded.untracked.map(\.path) == ["inner/"])
        #expect(discarded.staged.isEmpty)
        #expect(discarded.fileCount == 2)
    }
}
