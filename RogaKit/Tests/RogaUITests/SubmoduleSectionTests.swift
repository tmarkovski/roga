import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import RogaUI

/// The refs panel's section for a worktree's submodules, and what the panels
/// show of one that's selected there, against real git (decision 75).
/// `SubmoduleRepository` says what each test starts with: the fifth of the
/// submodule's commits recorded and checked out.
extension SubmodulePanelTests {
    /// Reads the section as the refs panel does while it's showing: for the
    /// latest look at the worktree.
    func showSection(_ work: Worktree) async {
        work.model.refs.readSubmodules(asOf: work.model.worktreeLooks)
        await work.model.refs.readingSubmodules?.value
    }

    /// Lets everything that's been started finish, including a reading of the
    /// submodules that a look at the worktree started.
    func settledWithSection(_ work: Worktree) async {
        await settled(work)
        await work.model.refs.readingSubmodules?.value
        await work.file.loading?.value
    }

    /// Loads the worktree with nothing selected, and its section read.
    func openSection(_ work: Worktree) async throws -> Submodule {
        await work.model.appear()
        await showSection(work)
        return try #require(work.model.refs.submodules.first { $0.path == path })
    }

    /// A linked worktree of the parent, which starts with its submodules'
    /// folders empty.
    func linkedWorktree(_ world: SubmoduleRepository) async throws -> String {
        let linked = (world.parent as NSString).deletingLastPathComponent + "/linked"
        try await world.run("worktree", "add", "--quiet", "-b", "linked", linked, in: world.parent)
        return linked
    }

    func submodule(ahead: Int = 0, behind: Int = 0, files: Int? = nil, checkedOut: String? = "52e8a1b0") throws -> Submodule {
        let recorded = try #require(ObjectID(hex: "9d41c07f" + String(repeating: "0", count: 32)))
        let head = try checkedOut.map { try #require(ObjectID(hex: $0 + String(repeating: "0", count: 32))) }
        var flags: SubmoduleChange.Checkout = ahead + behind > 0 ? [.commitChanged] : []
        if files != nil { flags.insert(.modifiedFiles) }
        return Submodule(
            name: "vendor/parser", path: "vendor/parser", recorded: recorded, checkedOut: head,
            change: head == nil ? nil : SubmoduleChange(checkout: flags, distance: .counted(ahead: ahead, behind: behind), filesInside: files)
        )
    }

    // MARK: What a row says

    @Test func aRowsSecondLineSaysWhereTheCheckoutStands() throws {
        #expect(try submodule().subtitle == "52e8a1b0 · as recorded")
        #expect(try submodule(behind: 3).subtitle == "52e8a1b0 · 3 behind what's recorded")
        #expect(try submodule(ahead: 2).subtitle == "52e8a1b0 · 2 new commits")
        #expect(try submodule(ahead: 1).subtitle == "52e8a1b0 · 1 new commit")
        #expect(try submodule(files: 2).subtitle == "52e8a1b0 · 2 uncommitted files")
        #expect(try submodule(files: 1).subtitle == "52e8a1b0 · 1 uncommitted file")
        #expect(try submodule(ahead: 2, behind: 3).subtitle == "52e8a1b0 · 2 new, 3 behind what's recorded")
        #expect(try submodule(ahead: 2, files: 1).subtitle == "52e8a1b0 · 2 new commits, 1 uncommitted file")
        #expect(try submodule(checkedOut: nil).subtitle == "not checked out")

        var missing = try submodule()
        missing.change = SubmoduleChange(checkout: [.commitChanged], distance: .commitMissing)
        #expect(missing.subtitle == "52e8a1b0 · recorded commit not fetched")

        // Until its own repository has been read, the hash is all there is.
        var unread = try submodule()
        unread.change = Submodule.unread(recorded: unread.recorded, checkedOut: unread.checkedOut)
        #expect(unread.subtitle == "52e8a1b0")
        #expect(unread.standing == nil)
    }

    @Test func theCountsBesideANameAreTheOnesItsSecondLineSays() throws {
        #expect(try submodule().counts == (ahead: 0, behind: 0, files: 0))
        #expect(try submodule(behind: 3).counts == (ahead: 0, behind: 3, files: 0))
        #expect(try submodule(ahead: 2, files: 4).counts == (ahead: 2, behind: 0, files: 4))
        #expect(try submodule(checkedOut: nil).counts == (ahead: 0, behind: 0, files: 0))
    }

    @Test func theSectionIsntThereUntilTheresASubmodule() {
        let section = RefsModel.Section.submodules
        #expect(section.title == "Submodules")
        #expect(RefsModel.Section.allCases.last == .submodules)
        #expect(!section.isShown(count: 0, isFiltering: false))
        #expect(section.isShown(count: 1, isFiltering: false))
        #expect(!section.isShown(count: 0, isFiltering: true))
    }

    // MARK: The section

    @Test func aCleanSubmoduleListsAsRecorded() async throws {
        let world = try await SubmoduleRepository.make()
        let work = try await worktree(world)
        let listed = try await openSection(work)

        #expect(work.model.refs.submodules.count == 1)
        #expect(listed.subtitle == "\(short(world.commits[4])) · as recorded")
        #expect(listed.counts == (ahead: 0, behind: 0, files: 0))
        #expect(listed.address == world.origin)
        // Nothing in history or under uncommitted changes shows it.
        #expect(!work.model.hasWorkingTreeRow)
    }

    @Test func aCheckoutThatsBehindListsHowFar() async throws {
        let world = try await SubmoduleRepository.make()
        try await world.checkOut(1)
        let work = try await worktree(world)
        let listed = try await openSection(work)

        #expect(listed.subtitle == "\(short(world.commits[1])) · 3 behind what's recorded")
        #expect(listed.counts == (ahead: 0, behind: 3, files: 0))
    }

    @Test func aCheckoutWithNewCommitsListsHowMany() async throws {
        let world = try await SubmoduleRepository.make()
        _ = try await world.commitInside("Sixth")
        let newest = try await world.commitInside("Seventh")
        let work = try await worktree(world)
        let listed = try await openSection(work)

        #expect(listed.subtitle == "\(short(newest)) · 2 new commits")
        #expect(listed.counts == (ahead: 2, behind: 0, files: 0))
    }

    @Test func aCheckoutWithFilesOfItsOwnListsHowMany() async throws {
        let world = try await SubmoduleRepository.make()
        try world.writeInside("changed\n", to: "lib.txt")
        try world.writeInside("notes\n", to: "Notes.md")
        let work = try await worktree(world)
        let listed = try await openSection(work)

        #expect(listed.subtitle == "\(short(world.commits[4])) · 2 uncommitted files")
        #expect(listed.counts == (ahead: 0, behind: 0, files: 2))
    }

    @Test func aSubmoduleThatIsntCheckedOutSaysSo() async throws {
        let world = try await SubmoduleRepository.make()
        let work = try await worktree(world, at: try await linkedWorktree(world))
        let listed = try await openSection(work)

        #expect(listed.checkedOut == nil)
        #expect(listed.subtitle == "not checked out")
        #expect(listed.counts == (ahead: 0, behind: 0, files: 0))
    }

    @Test func aWorktreeWithoutSubmodulesHasNoSection() async throws {
        let world = try await SubmoduleRepository.make()
        // The submodule's own repository has none.
        let work = try await worktree(world, at: world.origin)
        await work.model.appear()
        await showSection(work)
        #expect(work.model.refs.submodules.isEmpty)
        #expect(!RefsModel.Section.submodules.isShown(count: work.model.refs.shownSubmodules.count, isFiltering: false))
    }

    @Test func theFilterNarrowsSubmodulesByTheirPaths() async throws {
        let world = try await SubmoduleRepository.make()
        let work = try await worktree(world)
        _ = try await openSection(work)

        work.model.refs.filter = "PARS"
        #expect(work.model.refs.shownSubmodules.map(\.path) == [path])
        work.model.refs.filter = "lexer"
        #expect(work.model.refs.shownSubmodules.isEmpty)
        work.model.refs.closeFilter()
        #expect(work.model.refs.shownSubmodules.map(\.path) == [path])
    }

    @Test func theListShowsBeforeAnythingReadsEachSubmodule() async throws {
        let world = try await SubmoduleRepository.make()
        try await world.checkOut(1)
        let work = try await worktree(world)
        await work.model.appear()
        var lists: [(subtitles: [String], isRead: Bool)] = []
        work.model.refs.onSubmodules = { submodules, isRead in lists.append((submodules.map(\.subtitle), isRead)) }
        await showSection(work)

        #expect(lists.map(\.isRead) == [false, true])
        #expect(lists.map(\.subtitles) == [[short(world.commits[1])], ["\(short(world.commits[1])) · 3 behind what's recorded"]])

        // The next time, a row keeps what it said until it's been read again.
        lists = []
        work.model.refsChanged()
        await settledWithSection(work)
        await showSection(work)
        #expect(lists.map(\.subtitles) == Array(repeating: ["\(short(world.commits[1])) · 3 behind what's recorded"], count: 2))
    }

    @Test func oneLookAtTheWorktreeReadsTheSubmodulesOnce() async throws {
        let world = try await SubmoduleRepository.make()
        let work = try await worktree(world)
        _ = try await openSection(work)
        let log = work.model.session.git.log
        func listings() -> Int {
            log.entries.count { $0.arguments.contains("ls-files") }
        }

        // The panel and the worktree's model can both ask about the same look.
        let before = listings()
        await showSection(work)
        await showSection(work)
        #expect(listings() == before)

        // Another look reads them again, once, however many ask meanwhile.
        work.model.refsChanged()
        await settled(work)
        work.model.refs.readSubmodules(asOf: work.model.worktreeLooks)
        work.model.refs.readSubmodules(asOf: work.model.worktreeLooks)
        await work.model.refs.readingSubmodules?.value
        #expect(listings() == before + 1)
    }

    // MARK: Another worktree

    @Test func eachWorktreeListsItsOwnAndReadsItAgainWhenItShows() async throws {
        let world = try await SubmoduleRepository.make()
        try await world.checkOut(1)
        let linked = try await linkedWorktree(world)
        let main = try await worktree(world)
        // The window's other worktree is another model on the same session.
        let other = Worktree(
            model: RepositoryModel(session: main.model.session, worktree: linked, fetchesByItself: { false }, drafts: .none),
            world: world
        )

        #expect(try await openSection(main).subtitle == "\(short(world.commits[1])) · 3 behind what's recorded")
        #expect(try await openSection(other).subtitle == "not checked out")

        // While the window shows the first one, the other one's submodule is
        // checked out and moved, which nothing reads until it shows again.
        try await world.run("submodule", "--quiet", "update", "--init", in: linked)
        try await world.run("checkout", "--quiet", "--detach", world.commits[2], in: linked + "/" + path)
        #expect(other.model.refs.submodules.first?.subtitle == "not checked out")

        // Showing a worktree again looks at it, and its panel reads for that look.
        await other.model.appear()
        await showSection(other)
        #expect(other.model.refs.submodules.first?.subtitle == "\(short(world.commits[2])) · 2 behind what's recorded")
        // The first worktree's list is still its own.
        await main.model.appear()
        await showSection(main)
        #expect(main.model.refs.submodules.first?.subtitle == "\(short(world.commits[1])) · 3 behind what's recorded")
    }

    // MARK: A submodule in the panels

    @Test func selectingASubmoduleShowsItInThePanelsWithNoRowSelected() async throws {
        let world = try await SubmoduleRepository.make()
        let work = try await worktree(world)
        let listed = try await openSection(work)
        work.model.selectRow(0)
        await settledWithSection(work)
        #expect(work.model.selectedRows == [0])

        work.model.select(submodule: listed)
        await settledWithSection(work)
        #expect(work.model.selectedRows.isEmpty)
        #expect(work.model.selectedCommit.submodule == listed)
        #expect(work.model.selectedCommit.id == nil)
        #expect(work.model.selectedCommit.hashToCopy == nil)
        #expect(work.model.refs.selectedRef == "submodule:" + path)
        // It has no files of the parent's, so there's nothing to filter.
        #expect(work.model.selectedCommit.files == .loaded([]))
        #expect(!work.model.canFilterFiles)

        // The diff panel shows what the row would show under Unstaged, under
        // no heading, since nothing is uncommitted.
        #expect(work.file.source == .submodule(worktree: world.parent))
        #expect(work.file.group == nil)
        #expect(work.file.file?.path == path)
        let report = try report(work)
        #expect(report.sections.map(\.band) == ["Checked out at \(short(world.commits[4])), as recorded"])
        #expect(report.notes == ["There's nothing to update or stage."])
        #expect(work.file.shownSubmodule?.submoduleStaging == .nothingToStage)

        // Selecting a commit takes its place.
        work.model.selectRow(0)
        await settledWithSection(work)
        #expect(work.model.selectedCommit.submodule == nil)
        #expect(work.model.selectedCommit.id != nil)
    }

    @Test func aSubmoduleThatsBehindUpdatesFromItsPanel() async throws {
        let world = try await SubmoduleRepository.make()
        try await world.checkOut(1)
        let work = try await worktree(world)
        work.model.select(submodule: try await openSection(work))
        await settledWithSection(work)

        #expect(try report(work).sections.map(\.band) == ["Checked out at \(short(world.commits[1])) · 3 commits behind what's recorded"])
        #expect(try report(work).sections[0].commits.map(\.subject) == ["Parser commit 5", "Parser commit 4", "Parser commit 3"])
        let shown = try #require(work.file.shownSubmodule)
        #expect(shown.submoduleStaging == .takesCommitsAway)

        // Update is the header's button, and the panels follow what it did
        // without the refs panel having to be there.
        work.model.updateSubmodule(shown)
        #expect(work.model.branch.action == .updatingSubmodule)
        await settledWithSection(work)
        #expect(work.model.branch.finished == "Updated parser")
        #expect(try await world.run("rev-parse", "HEAD", in: world.checkout) == world.commits[4])

        let followed = try #require(work.model.selectedCommit.submodule)
        #expect(followed.subtitle == "\(short(world.commits[4])) · as recorded")
        #expect(work.model.refs.submodules == [followed])
        #expect(try report(work).sections.map(\.band) == ["Checked out at \(short(world.commits[4])), as recorded"])
        #expect(work.file.shownSubmodule?.submoduleStaging == .nothingToStage)
        #expect(work.model.selectedRows.isEmpty)
    }

    @Test func aSubmoduleWithNewCommitsStagesFromItsPanel() async throws {
        let world = try await SubmoduleRepository.make()
        let newest = try await world.commitInside("Sixth")
        let work = try await worktree(world)
        work.model.select(submodule: try await openSection(work))
        await settledWithSection(work)

        let report = try report(work)
        #expect(report.sections.map(\.band) == ["Checked out at \(short(newest)) · 1 new commit since \(short(world.commits[4]))"])
        #expect(report.notes.first == "Stage records \(short(newest)).")
        let shown = try #require(work.file.shownSubmodule)
        #expect(shown.submoduleStaging == .recordsNewCommits)

        // The lists of uncommitted files aren't showing, and it still stages.
        #expect(!work.changes.isSelected)
        work.model.stageSubmodule(shown)
        await settledWithSection(work)
        #expect(try await world.run("ls-files", "--stage", "--", path, in: world.parent).contains(newest))
        #expect(work.model.stagedFiles == 1)

        // What's recorded is now what's checked out, and the row stays.
        let followed = try #require(work.model.selectedCommit.submodule)
        #expect(followed.recorded.hex == newest)
        #expect(followed.subtitle == "\(short(newest)) · as recorded")
        #expect(try self.report(work).sections.map(\.band) == ["Checked out at \(short(newest)), as recorded"])
        #expect(work.file.shownSubmodule?.submoduleStaging == .nothingToStage)
    }

    @Test func aSubmoduleWithFilesOfItsOwnListsThemAndHasNothingToStage() async throws {
        let world = try await SubmoduleRepository.make()
        try world.writeInside("changed\n", to: "lib.txt")
        try world.writeInside("notes\n", to: "Notes.md")
        let work = try await worktree(world)
        work.model.select(submodule: try await openSection(work))
        await settledWithSection(work)

        let report = try report(work)
        #expect(report.sections.map(\.band) == ["2 uncommitted files inside · checked out at \(short(world.commits[4])), as recorded"])
        #expect(report.sections[0].files.map(\.path) == ["Notes.md", "lib.txt"])
        #expect(work.file.shownSubmodule?.submoduleStaging == .nothingToStage)
    }

    @Test func aSubmoduleThatIsntCheckedOutShowsWhatsRecorded() async throws {
        let world = try await SubmoduleRepository.make()
        let work = try await worktree(world, at: try await linkedWorktree(world))
        work.model.select(submodule: try await openSection(work))
        await settledWithSection(work)

        let report = try report(work)
        #expect(report.sections.map(\.band) == ["\(short(world.commits[4])) is recorded"])
        #expect(report.notes == ["\(path) isn't checked out in this worktree."])
        // There's no checkout to stage or to go back from.
        #expect(work.file.shownSubmodule?.submoduleStaging == .nothingToStage)
    }

    @Test func aSelectedSubmoduleFollowsWhatChangesOnDisk() async throws {
        let world = try await SubmoduleRepository.make()
        let work = try await worktree(world)
        work.model.select(submodule: try await openSection(work))
        await settledWithSection(work)
        #expect(work.model.selectedCommit.submodule?.subtitle == "\(short(world.commits[4])) · as recorded")

        // Something outside Roga moves the checkout, and the next look at the
        // worktree finds it, whether or not the refs panel is showing.
        try await world.checkOut(1)
        work.model.refsChanged()
        await settledWithSection(work)
        #expect(work.model.selectedCommit.submodule?.subtitle == "\(short(world.commits[1])) · 3 behind what's recorded")
        #expect(try report(work).sections.map(\.band) == ["Checked out at \(short(world.commits[1])) · 3 commits behind what's recorded"])
        #expect(work.file.shownSubmodule?.submoduleStaging == .takesCommitsAway)

        // Once it isn't a submodule here any more, the panels have nothing.
        try await world.run("rm", "--quiet", "--cached", path, in: world.parent)
        work.model.refsChanged()
        await settledWithSection(work)
        #expect(work.model.refs.submodules.isEmpty)
        #expect(work.model.selectedCommit.subject == nil)
        #expect(work.file.file == nil)
    }
}
