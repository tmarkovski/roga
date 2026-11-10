import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import RogaUI

/// What a submodule's row says, what the diff panel shows of it, and staging
/// around one, against real git (decision 75). `SubmoduleRepository` says what
/// each test starts with: the fifth of the submodule's commits recorded and
/// checked out.
@Suite(.timeLimit(.minutes(1)))
struct SubmodulePanelTests {
    let path = SubmoduleRepository.path

    struct Worktree {
        var model: RepositoryModel
        var world: SubmoduleRepository
        var changes: SelectedChanges { model.selectedChanges }
        var composer: CommitComposer { model.composer }
        var file: SelectedFile { model.selectedFile }
    }

    /// A model for the parent's worktree, or for another of its worktrees.
    func worktree(_ world: SubmoduleRepository, at folder: String? = nil) async throws -> Worktree {
        let folder = folder ?? world.parent
        let session = try await RepositorySession.open(containing: folder, git: try await SubmoduleRepository.git())
        let model = RepositoryModel(session: session, worktree: folder, fetchesByItself: { false }, drafts: .none)
        model.branch.timeToPlayHouse = { _ in .zero }
        model.branch.timeToShowFinished = { _ in .seconds(600) }
        return Worktree(model: model, world: world)
    }

    /// Loads the worktree with its row for uncommitted changes selected.
    func open(_ work: Worktree) async throws {
        await work.model.appear()
        work.model.selectRow(0)
        await settled(work)
        #expect(work.changes.isSelected)
    }

    /// Lets everything that's been started finish.
    func settled(_ work: Worktree) async {
        await work.changes.waitingToStage?.value
        await work.changes.applyingIndexChanges?.value
        await work.model.branch.running?.value
        await work.model.check?.value
        await work.model.load()
        await work.changes.applyingIndexChanges?.value
        await work.changes.loading?.value
        await work.changes.readingSubmodules?.value
        await work.model.selectedCommit.loading?.value
        await work.model.selectedCommit.readingSubmodules?.value
        await work.file.loading?.value
    }

    /// Selects one of the parent's commits, as clicking its row would.
    func select(_ commit: String, _ work: Worktree) async throws {
        work.model.selectedCommit.show(try #require(ObjectID(hex: commit)))
        await settled(work)
    }

    func short(_ hash: String) -> String {
        String(hash.prefix(8))
    }

    /// The submodule's row in a group of the uncommitted changes.
    func row(_ group: WorktreeChanges.Group, _ work: Worktree) throws -> DiffFile {
        try #require(work.changes.loaded?[group].first { $0.path == path })
    }

    /// What the diff panel says of the selected file, when it's a submodule.
    func report(_ work: Worktree) throws -> SubmoduleReport {
        let shown = try #require(work.file.shown)
        guard case .submodule(let details) = shown.content else {
            throw Unexpected(description: "The panel isn't showing a submodule: \(shown.content)")
        }
        return SubmoduleReport(details, path: shown.file.path)
    }

    struct Unexpected: Error {
        var description: String
    }

    func paths(_ files: [DiffFile]?) -> [String] {
        (files ?? []).map(\.path)
    }

    // MARK: Uncommitted changes

    @Test func aCheckoutThatsBehindSaysSoAndUpdates() async throws {
        let world = try await SubmoduleRepository.make()
        try await world.checkOut(1)
        let work = try await worktree(world)
        try await open(work)

        let row = try row(.unstaged, work)
        #expect(row.submoduleLabel == SubmoduleLabel(text: "3 behind", spoken: "3 commits behind what's recorded"))
        #expect(row.submoduleStaging == .takesCommitsAway)
        #expect(work.file.file?.path == path)
        #expect(work.file.shownSubmodule?.submoduleStaging == .takesCommitsAway)
        // There's no text to find anything in, and no other layout.
        #expect(!work.file.canFind && !work.file.canChangeLayout)

        let report = try report(work)
        #expect(report.sections.map(\.band) == ["Checked out at \(short(world.commits[1])) · 3 commits behind what's recorded"])
        #expect(report.sections.map(\.goesBack) == [false])
        #expect(report.sections[0].commits.map(\.subject) == ["Parser commit 5", "Parser commit 4", "Parser commit 3"])
        #expect(report.notes == [
            "Update checks out \(short(world.commits[4])), which is what's recorded. Staging the row instead would record \(short(world.commits[1])), without these 3 commits.",
        ])

        // Space goes down a list without reading each row, so it leaves this one.
        work.changes.toggleSelectedFile()
        #expect(paths(work.changes.loaded?.staged) == [])

        work.changes.updateSubmodule(row)
        #expect(work.model.branch.action == .updatingSubmodule)
        await settled(work)
        #expect(work.model.branch.finished == "Updated parser")
        #expect(try await world.run("rev-parse", "HEAD", in: world.checkout) == world.commits[4])
        #expect(try await work.model.session.status(in: world.parent).fileCount == 0)
        #expect(!work.model.hasWorkingTreeRow)
    }

    @Test func stagingTheRowOfACheckoutThatsBehindIsStillThere() async throws {
        let world = try await SubmoduleRepository.make()
        try await world.checkOut(1)
        let work = try await worktree(world)
        try await open(work)

        // The diff panel's menu stages it, for someone who means to go back.
        work.changes.toggle(try row(.unstaged, work), in: .unstaged)
        await settled(work)
        let staged = try row(.staged, work)
        #expect(staged.newID?.hex == world.commits[1])
        #expect(staged.submoduleLabel == SubmoduleLabel(text: "3 commits back", spoken: "3 commits back"))
        let report = try report(work)
        #expect(report.sections.map(\.band) == ["\(short(world.commits[4])) → \(short(world.commits[1])) · 3 commits back"])
        #expect(report.sections.map(\.goesBack) == [true])
        #expect(report.notes == ["These 3 commits aren't recorded any more."])
    }

    @Test func aCheckoutWithNewCommitsStagesAndSaysTheyArentPushed() async throws {
        let world = try await SubmoduleRepository.make()
        _ = try await world.commitInside("Local one")
        let local = try await world.commitInside("Local two")
        let work = try await worktree(world)
        try await open(work)

        let row = try row(.unstaged, work)
        #expect(row.submoduleLabel == SubmoduleLabel(text: "2 new commits", spoken: "2 new commits"))
        #expect(row.submoduleStaging == .recordsNewCommits)
        var report = try report(work)
        #expect(report.sections.map(\.band) == ["Checked out at \(short(local)) · 2 new commits since \(short(world.commits[4]))"])
        #expect(report.sections[0].commits.map(\.subject) == ["Local two", "Local one"])
        #expect(report.notes == [
            "Stage records \(short(local)).",
            "Neither commit is on any of parser's remotes yet, so push parser before this branch.",
        ])

        work.changes.toggleSelectedFile()
        // Before git has done anything, the row is under Staged, where both of
        // its commits are recorded ones.
        #expect(paths(work.changes.loaded?.staged) == [path])
        #expect(paths(work.changes.loaded?.unstaged) == [])
        #expect(try self.row(.staged, work).submoduleLabel?.text == "2 commits")
        await settled(work)
        #expect(paths(try await work.model.session.status(in: world.parent).staged) == [path])
        #expect(try self.row(.staged, work).submoduleLabel == SubmoduleLabel(text: "2 commits", spoken: "2 commits forward"))
        #expect(work.file.group == .staged)
        report = try self.report(work)
        #expect(report.sections.map(\.band) == ["\(short(world.commits[4])) → \(short(local)) · 2 commits forward"])
        #expect(report.notes == ["Neither commit is on any of parser's remotes yet, so push parser before this branch."])

        // Unstaging it puts the row back as it was.
        work.changes.toggleSelectedFile()
        #expect(try self.row(.unstaged, work).submoduleLabel?.text == "2 new commits")
        await settled(work)
        #expect(try self.row(.unstaged, work).submoduleLabel?.text == "2 new commits")
    }

    @Test func aCheckoutWithFilesOfItsOwnHasNothingToStage() async throws {
        let world = try await SubmoduleRepository.make()
        try world.writeInside("changed\n", to: "lib.txt")
        try world.writeInside("notes\n", to: "Notes.md")
        let work = try await worktree(world)
        try await open(work)

        let row = try row(.unstaged, work)
        #expect(row.submoduleLabel == SubmoduleLabel(text: "2 files inside", spoken: "2 uncommitted files inside", isUncommitted: true))
        #expect(row.submoduleStaging == .nothingToStage)
        let report = try report(work)
        #expect(report.sections.map(\.band) == ["2 uncommitted files inside · checked out at \(short(world.commits[4])), as recorded"])
        #expect(report.sections[0].files.map(\.path) == ["Notes.md", "lib.txt"])
        #expect(report.sections[0].commits.isEmpty)
        #expect(report.notes == ["These are committed inside parser rather than in this repository, so there's nothing here to stage."])

        // Nothing stages it: not Space, and not Stage All, which has nothing to
        // say about it either.
        work.changes.toggleSelectedFile()
        work.changes.toggleAll(in: .unstaged)
        await settled(work)
        #expect(paths(work.changes.loaded?.staged) == [])
        #expect(paths(work.changes.loaded?.unstaged) == [path])
        #expect(work.model.branch.finished == nil)
        // With nothing else changed, there's nothing to commit.
        work.composer.message = "Nothing"
        #expect(work.composer.action == .init(title: "Stage All and Commit", isEnabled: false))
    }

    @Test func aCheckoutWithNewCommitsAndFilesOfItsOwnLeavesTheFilesUnstaged() async throws {
        let world = try await SubmoduleRepository.make()
        let local = try await world.commitInside("Local")
        try world.writeInside("notes\n", to: "Notes.md")
        let work = try await worktree(world)
        try await open(work)

        #expect(try row(.unstaged, work).submoduleLabel?.text == "1 new commit")
        let report = try report(work)
        #expect(report.sections.map(\.band) == [
            "Checked out at \(short(local)) · 1 new commit since \(short(world.commits[4]))",
            "1 uncommitted file inside",
        ])
        #expect(report.sections[1].files.map(\.path) == ["Notes.md"])
        #expect(report.notes == [
            "Stage records \(short(local)).",
            "This commit isn't on any of parser's remotes yet, so push parser before this branch.",
            "The uncommitted files are parser's own, and staging leaves them as they are.",
        ])

        work.changes.toggleSelectedFile()
        // The file inside stays under Unstaged, as git will say too.
        #expect(paths(work.changes.loaded?.staged) == [path])
        #expect(try row(.unstaged, work).submoduleLabel?.text == "1 file inside")
        await settled(work)
        #expect(paths(work.changes.loaded?.staged) == [path])
        #expect(try row(.unstaged, work).submoduleLabel?.text == "1 file inside")
        #expect(try row(.unstaged, work).submoduleStaging == .nothingToStage)
    }

    // MARK: Staging everything

    @Test func stageAllLeavesOutASubmoduleThatsBehindAndSaysWhy() async throws {
        let world = try await SubmoduleRepository.make()
        try await world.checkOut(1)
        try Data("changed\n".utf8).write(to: URL(filePath: world.parent + "/a.txt"))
        let work = try await worktree(world)
        try await open(work)

        work.changes.toggleAll(in: .unstaged)
        #expect(paths(work.changes.loaded?.staged) == ["a.txt"])
        #expect(paths(work.changes.loaded?.unstaged) == [path])
        #expect(work.model.branch.finished == "Left out vendor/parser, which is 3 commits behind")
        await settled(work)
        let status = try await work.model.session.status(in: world.parent)
        #expect(paths(status.staged) == ["a.txt"])
        #expect(paths(status.unstaged) == [path])
    }

    @Test func stageAllWaitsForASubmoduleThatHasntBeenReadYet() async throws {
        let world = try await SubmoduleRepository.make()
        try await world.checkOut(1)
        try Data("changed\n".utf8).write(to: URL(filePath: world.parent + "/a.txt"))
        let work = try await worktree(world)
        await work.model.appear()
        work.model.selectRow(0)
        await work.changes.loading?.value
        // The list shows before anything has read the submodule.
        #expect(try row(.unstaged, work).submoduleStaging == .unknown)
        #expect(try row(.unstaged, work).submoduleLabel == nil)

        work.changes.toggleAll(in: .unstaged)
        #expect(paths(work.changes.loaded?.staged) == [])
        await work.changes.waitingToStage?.value
        #expect(paths(work.changes.loaded?.staged) == ["a.txt"])
        #expect(paths(work.changes.loaded?.unstaged) == [path])
        #expect(work.model.branch.finished == "Left out vendor/parser, which is 3 commits behind")
        await settled(work)
        #expect(paths(try await work.model.session.status(in: world.parent).unstaged) == [path])
    }

    @Test func stageAllTakesASubmoduleWithNewCommits() async throws {
        let world = try await SubmoduleRepository.make()
        _ = try await world.commitInside("Local")
        try Data("changed\n".utf8).write(to: URL(filePath: world.parent + "/a.txt"))
        let work = try await worktree(world)
        try await open(work)

        work.changes.toggleAll(in: .unstaged)
        await settled(work)
        #expect(paths(try await work.model.session.status(in: world.parent).staged).sorted() == ["a.txt", path])
        #expect(work.model.branch.finished == nil)
    }

    @Test func stageAllAndCommitLeavesOutASubmoduleThatsBehind() async throws {
        let world = try await SubmoduleRepository.make()
        try await world.checkOut(1)
        let work = try await worktree(world)
        try await open(work)
        work.composer.message = "Change a file"
        // The submodule is all there is, and staging everything leaves it out.
        #expect(work.composer.action == .init(title: "Stage All and Commit", isEnabled: false))

        try Data("changed\n".utf8).write(to: URL(filePath: world.parent + "/a.txt"))
        work.changes.refresh()
        await settled(work)
        #expect(work.composer.action == .init(title: "Stage All and Commit", isEnabled: true))
        let before = try await world.run("rev-parse", "HEAD", in: world.parent)
        work.composer.commit()
        await settled(work)

        let head = try await world.run("rev-parse", "HEAD", in: world.parent)
        #expect(head != before)
        #expect(work.composer.phase == .idle)
        #expect(work.model.branch.finished == "Committed \(short(head)) · left out vendor/parser, which is 3 commits behind")
        // The commit left the record of the submodule as it was.
        #expect(try await world.run("rev-parse", "HEAD:" + path, in: world.parent) == world.commits[4])
        let status = try await work.model.session.status(in: world.parent)
        #expect(status.staged.isEmpty)
        #expect(paths(status.unstaged) == [path])
    }

    @Test func stageAllAndCommitSaysWhyTheresNothingToCommit() async throws {
        let world = try await SubmoduleRepository.make()
        let work = try await worktree(world)
        try Data("changed\n".utf8).write(to: URL(filePath: world.parent + "/a.txt"))
        try await open(work)
        work.composer.message = "Change a file"
        // Something else puts the file back and leaves the submodule behind,
        // after the list was read.
        try await world.run("checkout", "--quiet", "a.txt", in: world.parent)
        try await world.checkOut(1)
        let before = try await world.run("rev-parse", "HEAD", in: world.parent)
        work.composer.commit()
        await work.model.branch.running?.value

        #expect(try await world.run("rev-parse", "HEAD", in: world.parent) == before)
        #expect(work.composer.phase == .failed(
            "There's nothing to commit, because Stage All left out vendor/parser, which is 3 commits behind. "
                + "Update it, or stage it from the diff panel's menu if you mean to go back."
        ))
        #expect(work.composer.message == "Change a file")
    }

    // MARK: Commits

    @Test func aCommitThatMovesASubmoduleForwardListsItsCommits() async throws {
        let world = try await SubmoduleRepository.make()
        let work = try await worktree(world)
        await work.model.appear()
        try await select(world.forward, work)

        let row = try #require(work.model.selectedCommit.files.all.first { $0.path == path })
        #expect(row.submoduleLabel == SubmoduleLabel(text: "3 commits", spoken: "3 commits forward"))
        #expect(work.file.file?.path == path)
        let report = try report(work)
        #expect(report.sections.map(\.band) == ["\(short(world.commits[1])) → \(short(world.commits[4])) · 3 commits forward"])
        #expect(report.sections.map(\.goesBack) == [false])
        #expect(report.sections[0].commits.map(\.subject) == ["Parser commit 5", "Parser commit 4", "Parser commit 3"])
        #expect(report.sections[0].commits.map(\.author) == ["Sam Lee", "Sam Lee", "Sam Lee"])
        #expect(report.notes.isEmpty)
        // A commit has nothing to stage or update.
        #expect(work.file.shownSubmodule?.submoduleStaging == nil)
    }

    @Test func aCommitThatMovesASubmoduleBackSaysSo() async throws {
        let world = try await SubmoduleRepository.make()
        let work = try await worktree(world)
        await work.model.appear()
        try await select(world.back, work)

        let row = try #require(work.model.selectedCommit.files.all.first { $0.path == path })
        #expect(row.submoduleLabel == SubmoduleLabel(text: "1 commit back", spoken: "1 commit back"))
        let report = try report(work)
        #expect(report.sections.map(\.band) == ["\(short(world.commits[4])) → \(short(world.commits[3])) · 1 commit back"])
        #expect(report.sections.map(\.goesBack) == [true])
        #expect(report.sections[0].commits.map(\.subject) == ["Parser commit 5"])
        #expect(report.notes == ["This commit isn't recorded any more."])
    }

    @Test func aCommitThatAddsASubmoduleSaysWhere() async throws {
        let world = try await SubmoduleRepository.make()
        let work = try await worktree(world)
        await work.model.appear()
        try await select(try await world.run("rev-parse", world.forward + "~1", in: world.parent), work)
        work.model.selectedCommit.select(try #require(work.model.selectedCommit.files.all.first { $0.path == path }))
        await settled(work)

        #expect(work.file.file?.submoduleLabel == nil)
        let report = try report(work)
        #expect(report.sections.map(\.band) == ["Added at \(short(world.commits[1]))"])
        #expect(report.notes.isEmpty)
    }

    @Test func aSubmoduleThatIsntCheckedOutShowsOnlyItsTwoCommits() async throws {
        let world = try await SubmoduleRepository.make()
        // A linked worktree starts with its submodules' folders empty.
        let linked = world.root + "/linked"
        try await world.run("worktree", "add", "--quiet", "-b", "linked", linked, in: world.parent)
        let work = try await worktree(world, at: linked)
        await work.model.appear()
        try await select(world.forward, work)

        let row = try #require(work.model.selectedCommit.files.all.first { $0.path == path })
        #expect(row.submodule?.distance == .notCheckedOut)
        #expect(row.submoduleLabel == nil)
        let report = try report(work)
        #expect(report.sections.map(\.band) == ["\(short(world.commits[1])) → \(short(world.commits[4]))"])
        #expect(report.sections[0].commits.isEmpty)
        #expect(report.notes == ["vendor/parser isn't checked out in this worktree, so its commits can't be listed."])
    }
}

/// What Roga says about a submodule, without git.
struct SubmoduleWordsTests {
    let one = ObjectID(hex: "1111111111111111111111111111111111111111")
    let two = ObjectID(hex: "2222222222222222222222222222222222222222")

    func row(_ checkout: SubmoduleChange.Checkout?, _ distance: SubmoduleChange.Distance?, files: Int? = nil, path: String = "vendor/parser") -> DiffFile {
        DiffFile(
            status: .modified, path: path, oldMode: DiffFile.submoduleMode, newMode: DiffFile.submoduleMode,
            submodule: SubmoduleChange(checkout: checkout, distance: distance, filesInside: files)
        )
    }

    func commits(_ count: Int) -> [SubmoduleDetails.Commit] {
        (0..<count).map { SubmoduleDetails.Commit(id: one!, subject: "Commit \($0)", author: "Sam Lee", time: 0) }
    }

    @Test func aRowSaysHowItsPointerMoves() {
        // Under Unstaged, against the checkout.
        #expect(row([.commitChanged], nil).submoduleLabel == nil)
        #expect(row([.commitChanged], .counted(ahead: 1, behind: 0)).submoduleLabel?.text == "1 new commit")
        #expect(row([.commitChanged], .counted(ahead: 0, behind: 1)).submoduleLabel?.spoken == "1 commit behind what's recorded")
        #expect(row([.commitChanged], .counted(ahead: 2, behind: 3)).submoduleLabel == SubmoduleLabel(
            text: "2 new, 3 behind", spoken: "2 new commits, and 3 behind what's recorded"
        ))
        #expect(row([.commitChanged], .commitMissing).submoduleLabel == SubmoduleLabel(
            text: "not fetched", spoken: "the commit that's recorded isn't fetched"
        ))
        #expect(row([.commitChanged, .modifiedFiles], .counted(ahead: 0, behind: 1_200), files: 4).submoduleLabel?.text == "1,200 behind")
        // Status says there are files inside before anything has counted them.
        #expect(row([.untrackedFiles], nil).submoduleLabel == SubmoduleLabel(
            text: "files inside", spoken: "uncommitted files inside", isUncommitted: true
        ))
        #expect(row([.modifiedFiles], .counted(ahead: 0, behind: 0), files: 1).submoduleLabel?.text == "1 file inside")
        #expect(row([], .counted(ahead: 0, behind: 0)).submoduleLabel == nil)

        // Everywhere else, between two commits that are recorded.
        #expect(row(nil, nil).submoduleLabel == nil)
        #expect(row(nil, .counted(ahead: 1, behind: 0)).submoduleLabel?.text == "1 commit")
        #expect(row(nil, .counted(ahead: 2, behind: 3)).submoduleLabel == SubmoduleLabel(
            text: "2 forward, 3 back", spoken: "2 commits forward and 3 back"
        ))
        #expect(row(nil, .notCheckedOut).submoduleLabel == nil)
        #expect(row(nil, .commitMissing).submoduleLabel == nil)
        #expect(DiffFile(status: .modified, path: "a.txt", oldMode: 0o100644, newMode: 0o100644).submoduleLabel == nil)
    }

    @Test func thePanelSaysWhatEachButtonWouldDoWhenACheckoutHasBothKindsOfCommits() {
        let details = SubmoduleDetails(
            from: one, to: two, comparesCheckout: true, distance: .counted(ahead: 2, behind: 3),
            added: commits(2), removed: commits(3), unpushed: 1
        )
        let report = SubmoduleReport(details, path: "vendor/parser")
        #expect(report.sections.map(\.band) == [
            "Checked out at 22222222 · 2 new commits, and 3 behind what's recorded",
            "3 commits recorded that the checkout is missing",
        ])
        #expect(report.sections.map(\.commits.count) == [2, 3])
        #expect(report.sections.map(\.goesBack) == [false, false])
        #expect(report.notes == [
            "Updating would check out 11111111, without the 2 new commits, and staging would record 22222222, without the other 3. To keep both, merge or rebase inside parser first.",
            "1 of these commits isn't on any of parser's remotes yet, so push parser before this branch.",
        ])
    }

    @Test func thePanelSaysWhenTheRecordedCommitIsntFetched() {
        let details = SubmoduleDetails(from: one, to: two, comparesCheckout: true, distance: .commitMissing)
        let report = SubmoduleReport(details, path: "parser")
        #expect(report.sections.map(\.band) == ["Checked out at 22222222 · 11111111 is recorded, and this checkout doesn't have it yet"])
        #expect(report.notes == ["Update fetches 11111111 and checks it out. Staging the row instead would record 22222222."])
    }

    @Test func aPointerThatGoesBothWaysListsBothAndSaysItGoesBack() {
        var details = SubmoduleDetails(
            from: one, to: two, comparesCheckout: false, distance: .counted(ahead: 2, behind: 1), added: commits(2), removed: commits(1)
        )
        var report = SubmoduleReport(details, path: "vendor/parser")
        #expect(report.sections.map(\.band) == ["11111111 → 22222222 · 2 commits forward, 1 back", "1 commit that isn't recorded any more"])
        #expect(report.sections.map(\.goesBack) == [true, true])
        #expect(report.notes.isEmpty)

        // A list that stops at its limit says how many more there are.
        details.distance = .counted(ahead: 1_502, behind: 0)
        details.removed = []
        report = SubmoduleReport(details, path: "vendor/parser")
        #expect(report.sections.map(\.band) == ["11111111 → 22222222 · 1,502 commits forward"])
        #expect(report.sections.map(\.moreCommits) == [1_500])

        details = SubmoduleDetails(from: one, to: nil, comparesCheckout: false, distance: .notCheckedOut)
        #expect(SubmoduleReport(details, path: "vendor/parser").sections.map(\.band) == ["Removed · it was at 11111111"])
        details = SubmoduleDetails(from: one, to: two, comparesCheckout: false, distance: .commitMissing)
        #expect(SubmoduleReport(details, path: "vendor/parser").notes == [
            "The copy of vendor/parser that's checked out in this worktree doesn't have both of these commits, so the commits between them can't be listed.",
        ])
    }

    @Test func theTitleRowSaysWhatStagingLeftOutAndWhy() {
        #expect(SubmoduleWords.leftOut([]) == nil)
        #expect(SubmoduleWords.leftOutSentence([row([.commitChanged], .counted(ahead: 0, behind: 1))]) == "Left out vendor/parser, which is 1 commit behind")
        #expect(SubmoduleWords.leftOut([row([.commitChanged], .counted(ahead: 2, behind: 3))]) == "left out vendor/parser, which is 3 commits behind")
        #expect(SubmoduleWords.leftOut([row([.commitChanged], .commitMissing)]) == "left out vendor/parser, whose recorded commit isn't fetched")
        #expect(SubmoduleWords.leftOut([row([.commitChanged], nil)]) == "left out vendor/parser, which couldn't be read")
        let two = [row([.commitChanged], .counted(ahead: 0, behind: 1)), row([.commitChanged], .commitMissing, path: "vendor/other")]
        #expect(SubmoduleWords.leftOutSentence(two) == "Left out 2 submodules that are behind")
    }
}
