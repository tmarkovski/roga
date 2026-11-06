import AppKit
import CommitGraph
import Foundation
import GitCore
import GitRunner
import HistoryUI
import RepositoryEngine
import TestSupport
import Testing
@testable import DiffUI
@testable import RogaUI

/// The models a window keeps for the worktrees it showed, and how they load
/// history.
@Suite(.timeLimit(.minutes(1)))
struct RepositoryModelTests {
    func openSession() async throws -> RepositorySession {
        try await RepositorySession.open(containing: try await Fixture.repository("basic"), git: try await TestGit.make())
    }

    func selection(_ number: Int) -> WorktreeSelection {
        WorktreeSelection(repository: "/work/roga/.git", worktree: "/work/\(number)")
    }

    @Test func keepsTheModelsOfRecentWorktrees() async throws {
        let session = try await openSession()
        let recent = RecentWorktrees()
        let models = (0..<RecentWorktrees.limit).map { recent.model(for: selection($0), session: session) }
        #expect(recent.model(for: selection(0), session: session) === models[0])

        // The first was shown again, so the second one goes to make room.
        _ = recent.model(for: selection(RecentWorktrees.limit), session: session)
        #expect(recent.model(for: selection(0), session: session) === models[0])
        #expect(recent.model(for: selection(2), session: session) === models[2])
        #expect(recent.model(for: selection(1), session: session) !== models[1])
    }

    @Test func replacesAModelWhoseSessionWasReplaced() async throws {
        let recent = RecentWorktrees()
        let model = recent.model(for: selection(0), session: try await openSession())
        #expect(recent.model(for: selection(0), session: try await openSession()) !== model)
    }

    @Test func loadsHistoryOncePerRequest() async throws {
        let repository = try await Fixture.repository("basic")
        let model = RepositoryModel(session: try await openSession(), worktree: repository)
        await model.load()
        #expect(model.history?.isComplete == true)
        let version = model.historyVersion

        await model.load()
        #expect(model.historyVersion == version)
        model.sort = .date
        await model.load()
        #expect(model.historyVersion > version)
        #expect(model.history?.sort == .date)
    }

    @Test func saysHowManyCommitsOnceItHasReadThemAll() async throws {
        let repository = try await Fixture.repository("basic")
        let model = RepositoryModel(session: try await openSession(), worktree: repository)
        #expect(model.commitCountDescription == nil)
        await model.load()
        let count = try #require(model.history?.rows.count)
        #expect(model.commitCountDescription == (count == 1 ? "1 commit" : "\(count.formatted()) commits"))
    }

    /// A model of a copy of the `basic` repository, which can be changed.
    func modelOfACopy(keepsCommitGraphCurrent: Bool = true) async throws -> (RepositoryModel, repository: String) {
        let repository = try makeTemporaryFolder() + "/basic"
        _ = try await TestGit.make().run(GitCommand("clone", "--quiet", "--no-local", try await Fixture.repository("basic"), repository))
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        return (RepositoryModel(session: session, worktree: repository, keepsCommitGraphCurrent: { keepsCommitGraphCurrent }), repository)
    }

    typealias TestError = SelectedFileTests.TestError

    /// The badge of a ref, once history has loaded.
    func badge(_ title: String, in model: RepositoryModel) throws -> CommitRowContent.Badge {
        try #require((0..<model.rowCount).lazy.compactMap { row in model.rowContent(row).badges.first { $0.title == title } }.first)
    }

    /// Lets a checkout and what it starts finish.
    /// Makes the model look at the worktree as it does when Roga becomes active,
    /// and waits for that. A quiet fetch that finishes looks again, which replaces
    /// the check that's running.
    func becomeActive(_ model: RepositoryModel) async {
        model.becameActive()
        await model.branch.quietFetch?.value
        await model.check?.value
    }

    func finishCheckout(_ model: RepositoryModel) async {
        await model.checkout?.value
        await model.check?.value
        await model.load()
    }

    @Test func showsTheBranchItChecksOut() async throws {
        let repository = try makeTemporaryFolder() + "/basic"
        _ = try await TestGit.make().run(GitCommand("clone", "--quiet", "--no-local", try await Fixture.repository("basic"), repository))
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        var branchChanges = 0
        let model = RepositoryModel(session: session, worktree: repository, reportBranchChange: { branchChanges += 1 })
        await model.load()
        #expect(model.headDescription == "main")
        let checks = model.refsChecks

        model.checkOut(try badge("origin/feature", in: model)) { _, _ in Issue.record("It's not in another worktree.") }
        await finishCheckout(model)

        #expect(model.headDescription == "feature")
        #expect(try badge("feature", in: model).kind == .currentBranch)
        #expect(try badge("main", in: model).kind == .branch)
        #expect(branchChanges == 1)
        #expect(model.refsChecks > checks)
        #expect(model.checkoutFailure == nil)
        #expect(model.checkout == nil)
    }

    @Test func saysWhyACheckoutDidntWork() async throws {
        let (model, repository) = try await modelOfACopy()
        await model.load()
        try await runGit("switch", "--quiet", "--create", "changed", in: repository)
        try write("Changed\n", to: "README.md", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Change", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
        try write("Mine\n", to: "README.md", in: repository)

        model.checkOut(CommitRowContent.Badge(title: "changed", kind: .branch, refName: "refs/heads/changed")) { _, _ in }
        await finishCheckout(model)

        #expect(model.checkoutFailure?.branch == "changed")
        #expect(model.checkoutFailure?.message.contains("would be overwritten") == true)
        #expect(model.headDescription == "main")
        #expect(model.checkout == nil)
    }

    @Test func showsTheWorktreeThatHasTheBranch() async throws {
        let (model, repository) = try await modelOfACopy()
        await model.load()
        let folder = (repository as NSString).deletingLastPathComponent + "/notes"
        try await runGit("worktree", "add", "--quiet", folder, "-b", "feature", "origin/feature", in: repository)

        var shown: [String] = []
        var commits: [ObjectID?] = []
        model.checkOut(CommitRowContent.Badge(title: "feature", kind: .branch, refName: "refs/heads/feature")) {
            shown.append($0)
            commits.append($1)
        }
        await finishCheckout(model)

        #expect(shown == [folder])
        #expect(commits == [ObjectID(hex: Fixture.Basic.feature)])
        #expect(model.headDescription == "main")
        #expect(model.checkoutFailure == nil)
    }

    @Test func aBadgeStandsForEveryRemoteThatHasTheBranchOnItsCommit() async throws {
        let (model, repository) = try await modelOfACopy()
        try await runGit("update-ref", "refs/remotes/backup/main", "main", in: repository)
        try await runGit("update-ref", "refs/remotes/backup/mcp-dev", "main", in: repository)
        // This one is on another commit, so it has its own badge there.
        try await runGit("update-ref", "refs/remotes/mirror/main", "main~1", in: repository)
        await model.load()

        let main = try badge("main", in: model)
        #expect(main.upstream == "refs/remotes/origin/main")
        #expect(main.otherRemoteBranches == ["refs/remotes/backup/main"])
        let row = model.rowContent(try row(of: Fixture.Basic.main, in: model))
        #expect(row.badges.map(\.title) == ["main", "backup/mcp-dev"])
        #expect(try badge("mirror/main", in: model).kind == .remoteBranch)
    }

    @Test func selectsTheLocalBranchOfARemoteBranchItChecksOut() async throws {
        let (model, repository) = try await modelOfACopy()
        try await runGit("branch", "--no-track", "feature", "main~1", in: repository)
        await model.load()
        let local = try await runGit("rev-parse", "feature", in: repository)
        // The first click of the double-click selects the remote branch's row.
        model.selectRow(try row(of: Fixture.Basic.feature, in: model))

        model.checkOut(try badge("origin/feature", in: model)) { _, _ in }
        await finishCheckout(model)

        #expect(model.headDescription == "feature")
        #expect(model.selectedCommit.id == ObjectID(hex: local))
        #expect(model.selectedRow == (try row(of: local, in: model)))
    }

    @Test func checksOutARefsPanelRowByItsName() async throws {
        let (model, repository) = try await modelOfACopy()
        try await runGit("branch", "--no-track", "local", "main~1", in: repository)
        await model.load()
        let local = try await runGit("rev-parse", "local", in: repository)

        model.checkOut(ref: "refs/heads/local") { _, _ in Issue.record("It's not in another worktree.") }
        await finishCheckout(model)
        #expect(model.headDescription == "local")
        #expect(model.selectedCommit.id == ObjectID(hex: local))

        model.checkOut(ref: "refs/remotes/origin/feature") { _, _ in Issue.record("It's not in another worktree.") }
        await finishCheckout(model)
        #expect(model.headDescription == "feature")
        #expect(model.checkoutFailure == nil)
    }

    @Test func namesTheBranchOfARefsPanelRowWhenItsCheckoutFails() async throws {
        let (model, repository) = try await modelOfACopy()
        try await runGit("switch", "--quiet", "--create", "changed", in: repository)
        try write("Changed\n", to: "README.md", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Change", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
        try write("Mine\n", to: "README.md", in: repository)
        await model.load()

        model.checkOut(ref: "refs/heads/changed") { _, _ in }
        await finishCheckout(model)

        #expect(model.checkoutFailure?.branch == "changed")
        #expect(model.headDescription == "main")
    }

    @Test func goesToTheCommitOfARefsPanelRowForARemotesCopyOfTheCurrentBranch() async throws {
        let (model, repository) = try await modelOfACopy()
        try await runGit("reset", "--quiet", "--hard", "main~1", in: repository)
        await model.load()
        let upstream = try await runGit("rev-parse", "origin/main", in: repository)

        model.checkOut(ref: "refs/remotes/origin/main") { _, _ in Issue.record("It's not in another worktree.") }
        await finishCheckout(model)

        #expect(model.headDescription == "main")
        #expect(try await runGit("rev-parse", "main", in: repository) == upstream)
    }

    @Test func showsTheWorktreeThatHasARefsPanelRowsBranch() async throws {
        let (model, repository) = try await modelOfACopy()
        let other = try makeTemporaryFolder() + "/other"
        try await runGit("worktree", "add", "--quiet", "-b", "elsewhere", other, in: repository)
        await model.load()
        var shown: String?

        model.checkOut(ref: "refs/heads/elsewhere") { folder, _ in shown = folder }
        await finishCheckout(model)

        #expect(shown?.hasSuffix("/other") == true)
        #expect(model.headDescription == "main")
    }

    @Test func replacesWhatWasSelectedWithTheCommitItsToldToSelect() async throws {
        let (model, _) = try await modelOfACopy()
        await model.load()
        model.selectRow(try row(of: Fixture.Basic.mainHistory[2], in: model))

        let id = try #require(ObjectID(hex: Fixture.Basic.main))
        model.select(commit: id)

        #expect(model.selectedCommit.id == id)
        #expect(model.selectedRow == (try row(of: Fixture.Basic.main, in: model)))
    }

    @Test func selectsACommitBeforeHistoryHasLoaded() async throws {
        let (model, _) = try await modelOfACopy()
        let id = try #require(ObjectID(hex: Fixture.Basic.mainHistory[1]))
        model.select(commit: id)
        #expect(model.selectedCommit.id == id)
        #expect(model.selectedRow == nil)

        await model.load()
        #expect(model.selectedCommit.id == id)
        #expect(model.selectedRow == (try row(of: Fixture.Basic.mainHistory[1], in: model)))
    }

    @Test func dropsACommitThatHistoryTurnsOutNotToHave() async throws {
        let (model, _) = try await modelOfACopy()
        let missing = try #require(ObjectID(hex: String(repeating: "1", count: 40)))
        model.select(commit: missing)
        await model.load()
        #expect(model.selectedCommit.id == nil)
        #expect(model.selectedRow == nil)
    }

    @Test func leavesTheSelectionForACommitThatLoadedHistoryDoesntHave() async throws {
        let (model, _) = try await modelOfACopy()
        await model.load()
        let selected = try row(of: Fixture.Basic.main, in: model)
        model.selectRow(selected)

        model.select(commit: try #require(ObjectID(hex: String(repeating: "1", count: 40))))

        #expect(model.selectedRow == selected)
        #expect(model.selectedCommit.id == ObjectID(hex: Fixture.Basic.main))
    }

    @Test func runsOneCheckoutAtATime() async throws {
        let (model, _) = try await modelOfACopy()
        await model.load()
        model.checkOut(try badge("origin/feature", in: model)) { _, _ in }
        let running = try #require(model.checkout)
        model.checkOut(CommitRowContent.Badge(title: "nothing", kind: .branch, refName: "refs/heads/nothing")) { _, _ in }
        #expect(model.checkout == running)
        await finishCheckout(model)
        #expect(model.headDescription == "feature")
        #expect(model.checkoutFailure == nil)
    }

    func write(_ text: String, to path: String, in repository: String) throws {
        try Data(text.utf8).write(to: URL(filePath: repository + "/" + path))
    }

    /// Lets the panel's loads finish. A quiet fetch that finishes looks again,
    /// which reads the panel's files again.
    func settled(_ model: RepositoryModel) async {
        await model.branch.quietFetch?.value
        await model.check?.value
        await model.selectedChanges.loading?.value
        await model.selectedCommit.loading?.value
        await model.selectedFile.loading?.value
    }

    func shownLines(_ model: RepositoryModel) -> [String]? {
        guard case .patch(let document) = model.selectedFile.shown?.content else { return nil }
        return document.storage.string.split(separator: "\n").map(String.init)
    }

    // MARK: Changes on disk

    @Test func looksAgainWhenItsFilesChangeOnDisk() async throws {
        let (model, repository) = try await modelOfACopy()
        await model.appear()
        #expect(model.uncommittedFiles == 0)
        try write("new\n", to: "new.txt", in: repository)
        model.filesChangedOnDisk(asNewAs: 1)
        await model.diskLook?.value
        #expect(model.uncommittedFiles == 1)
        #expect(model.hasWorkingTreeRow)
    }

    @Test func loadsHistoryAgainWhenRefsMoveOnDisk() async throws {
        let (model, repository) = try await modelOfACopy()
        await model.appear()
        // A quiet fetch that brings something looks again by itself.
        await model.branch.quietFetch?.value
        await model.check?.value
        let reloads = model.reloads
        let refsChecks = model.refsChecks
        try await runGit("-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "--quiet", "--allow-empty", "-m", "Elsewhere", in: repository)
        model.refsChangedOnDisk(asNewAs: 1)
        await model.diskLook?.value
        #expect(model.reloads == reloads + 1)
        #expect(model.refsChecks > refsChecks)

        // Nothing moved since, so nothing loads again.
        await model.load()
        model.refsChangedOnDisk(asNewAs: 2)
        await model.diskLook?.value
        #expect(model.reloads == reloads + 1)
    }

    @Test func changesThatArriveTogetherAreLookedAtOnce() async throws {
        let log = CommandLog()
        let repository = try makeTemporaryFolder() + "/basic"
        _ = try await TestGit.make().run(GitCommand("clone", "--quiet", "--no-local", try await Fixture.repository("basic"), repository))
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make(log: log))
        let model = RepositoryModel(session: session, worktree: repository)
        for change in 1...3 { model.filesChangedOnDisk(asNewAs: change) }
        await model.diskLook?.value
        #expect(log.entries.count { $0.arguments.contains("status") } == 1)
    }

    @Test func aChangeRightAfterALookWaitsForIt() async throws {
        let (model, repository) = try await modelOfACopy()
        let clock = ContinuousClock()
        let start = clock.now
        model.filesChangedOnDisk(asNewAs: 1)
        await model.diskLook?.value
        // The first look has finished, so this one starts a task of its own,
        // and still waits.
        try write("new\n", to: "new.txt", in: repository)
        model.filesChangedOnDisk(asNewAs: 2)
        await model.diskLook?.value
        #expect(clock.now - start >= ChangePacing.shortestGap)
        #expect(model.uncommittedFiles == 1)
    }

    @Test func aWatchedRepositoryDoesntLookAgainWhenRogaBecomesActive() async throws {
        let (model, _) = try await modelOfACopy()
        await model.appear()
        await model.session.watch(try await model.session.worktrees())
        #expect(model.session.isWatching)
        model.becameActive()
        #expect(model.check == nil)
        await model.branch.quietFetch?.value
        await model.session.close()
    }

    @Test func aCleanWorktreeHasNoRowForChanges() async throws {
        let (model, repository) = try await modelOfACopy()
        #expect(FileManager.default.fileExists(atPath: repository))
        await model.appear()
        #expect(!model.hasWorkingTreeRow)
        #expect(model.rowCount == model.history?.rows.count)
        #expect(!model.rowContent(0).isWorkingTree)
    }

    @Test func putsARowForChangesBeforeTheFirstCommit() async throws {
        let (model, repository) = try await modelOfACopy()
        try write("changed\n", to: "app.txt", in: repository)
        try write("new\n", to: "new.txt", in: repository)
        await model.appear()
        let history = try #require(model.history)
        #expect(model.uncommittedFiles == 2)
        #expect(model.rowCount == history.rows.count + 1)

        let row = model.rowContent(0)
        #expect(row.isWorkingTree)
        #expect(row.subject == "2 uncommitted files")
        #expect(row.shortID.isEmpty)
        let lanes = try #require(row.lanes)
        #expect(lanes.lines.count == 1)

        // The rest of the rows move down one.
        #expect(model.rowContent(1).shortID == String(history.graph.id(at: history.rows[0]).hex.prefix(8)))
        #expect(!model.rowContent(1).isWorkingTree)
        let loaded = await model.loadText(for: 0..<3)
        #expect(loaded == IndexSet([1, 2]))
        #expect(model.rowContent(1).subject != nil)
    }

    @Test func readsABodyWithItsSubject() async throws {
        let (model, _) = try await modelOfACopy()
        await model.appear()
        _ = await model.loadText(for: 0..<model.rowCount)
        let rows = (0..<model.rowCount).map { model.rowContent($0) }
        #expect(rows.first { $0.subject == "Change the app" }?.body == "The body says why.")
        #expect(rows.first { $0.subject == "Add the readme" }?.body == "")
    }

    @Test func saysOneFile() async throws {
        let (model, repository) = try await modelOfACopy()
        try write("new\n", to: "new.txt", in: repository)
        await model.appear()
        #expect(model.rowContent(0).subject == "1 uncommitted file")
    }

    @Test func selectingTheRowShowsItsFiles() async throws {
        let (model, repository) = try await modelOfACopy()
        try write("new\n", to: "new.txt", in: repository)
        await model.appear()
        model.selectRow(1)
        await settled(model)
        #expect(model.selectedCommit.id != nil)

        model.selectRow(0)
        #expect(model.selectedChanges.isSelected)
        #expect(model.selectedCommit.id == nil)
        await settled(model)
        guard case .loaded(let changes) = model.selectedChanges.files else {
            throw TestError("Files aren't loaded: \(model.selectedChanges.files)")
        }
        #expect(changes.untracked.map(\.path) == ["new.txt"])
        #expect(model.selectedFile.file?.path == "new.txt")
        #expect(model.selectedFile.group == .untracked)
        #expect(shownLines(model)?.contains("new") == true)

        model.selectRow(1)
        #expect(!model.selectedChanges.isSelected)
        #expect(model.selectedCommit.id != nil)
        await settled(model)
        #expect(model.selectedFile.group == nil)
    }

    @Test func selectingACommitFindsTheRightRow() async throws {
        let (model, repository) = try await modelOfACopy()
        try write("new\n", to: "new.txt", in: repository)
        await model.appear()
        let history = try #require(model.history)
        model.select(commit: history.graph.id(at: history.rows[2]))
        #expect(model.selectedRow == 3)
        #expect(model.selectedCommit.id == history.graph.id(at: history.rows[2]))
    }

    @Test func theSelectedCommitStaysSelectedWhenTheRowComesAndGoes() async throws {
        let (model, repository) = try await modelOfACopy()
        await model.appear()
        let history = try #require(model.history)
        model.selectRow(2)
        let selected = model.selectedCommit.id
        await settled(model)

        try write("new\n", to: "new.txt", in: repository)
        await becomeActive(model)
        #expect(model.hasWorkingTreeRow)
        #expect(model.selectedRow == 3)
        #expect(model.selectedCommit.id == selected)
        #expect(selected == history.graph.id(at: history.rows[2]))

        try FileManager.default.removeItem(atPath: repository + "/new.txt")
        await becomeActive(model)
        #expect(!model.hasWorkingTreeRow)
        #expect(model.selectedRow == 2)
        #expect(model.selectedCommit.id == selected)
    }

    @Test func nothingIsSelectedOnceTheSelectedChangesAreGone() async throws {
        let (model, repository) = try await modelOfACopy()
        try write("new\n", to: "new.txt", in: repository)
        await model.appear()
        model.selectRow(0)
        await settled(model)

        try FileManager.default.removeItem(atPath: repository + "/new.txt")
        await becomeActive(model)
        await settled(model)
        #expect(!model.hasWorkingTreeRow)
        #expect(model.selectedRow == nil)
        #expect(!model.selectedChanges.isSelected)
        #expect(model.selectedFile.file == nil)
    }

    @Test func aFileWithBothKindsOfChangesHasTwoRowsToSelect() async throws {
        let (model, repository) = try await modelOfACopy()
        try write("staged\n", to: "README.md", in: repository)
        try await runGit("add", "README.md", in: repository)
        try write("staged\nunstaged\n", to: "README.md", in: repository)
        try write("new\n", to: "new.txt", in: repository)
        await model.appear()
        model.selectRow(0)
        await settled(model)

        func selected() -> String { "\(model.selectedFile.group.map { $0.title } ?? "") \(model.selectedFile.file?.path ?? "")" }
        #expect(selected() == "Unstaged README.md")
        #expect(shownLines(model)?.contains("unstaged") == true)
        model.selectFile(by: 1)
        await settled(model)
        #expect(selected() == "Untracked new.txt")
        model.selectFile(by: 1)
        await settled(model)
        #expect(selected() == "Staged README.md")
        #expect(shownLines(model)?.contains("unstaged") == false)
        #expect(shownLines(model)?.contains("staged") == true)
        // It stops at the end of the list.
        model.selectFile(by: 1)
        await settled(model)
        #expect(selected() == "Staged README.md")
    }

    @Test func theUncommittedRowsFollowTheTreeAndTheFilter() async throws {
        let (model, repository) = try await modelOfACopy()
        try FileManager.default.createDirectory(atPath: repository + "/src", withIntermediateDirectories: true)
        try write("a\n", to: "a-new.txt", in: repository)
        try write("b\n", to: "src/b-new.txt", in: repository)
        try write("c\n", to: "src/c-new.txt", in: repository)
        model.fileList.layout = .tree
        await model.appear()
        model.selectRow(0)
        await settled(model)

        // In a tree, the folder comes before the file at the top.
        #expect(model.selectedFile.file?.path == "src/b-new.txt")
        model.selectFile(by: 1)
        await settled(model)
        #expect(model.selectedFile.file?.path == "src/c-new.txt")
        model.selectFile(by: 1)
        await settled(model)
        #expect(model.selectedFile.file?.path == "a-new.txt")

        model.fileList.filter = "c-new"
        model.selectFile(by: 1)
        await settled(model)
        #expect(model.selectedFile.file?.path == "src/c-new.txt")
        #expect(model.selectedFile.group == .untracked)

        // Reading the files again keeps the selected file, match or not.
        model.fileList.filter = "a-new"
        await becomeActive(model)
        await settled(model)
        #expect(model.selectedFile.file?.path == "src/c-new.txt")
    }

    @Test func aPanelThatComesBackSelectsTheFirstFileItShows() async throws {
        let (model, repository) = try await modelOfACopy()
        try FileManager.default.createDirectory(atPath: repository + "/src", withIntermediateDirectories: true)
        try write("a\n", to: "a-new.txt", in: repository)
        try write("b\n", to: "src/b-new.txt", in: repository)
        model.fileList.layout = .tree
        model.fileList.toggleFolder("src", in: .untracked)
        await model.appear()
        model.selectRow(0)
        await settled(model)
        #expect(model.selectedFile.file?.path == "a-new.txt")
    }

    @Test func lookingAgainKeepsTheSameTextUnlessTheFileChanged() async throws {
        let (model, repository) = try await modelOfACopy()
        try write("one\n", to: "new.txt", in: repository)
        await model.appear()
        model.selectRow(0)
        await settled(model)
        guard case .patch(let first) = model.selectedFile.shown?.content else { throw TestError("No patch") }

        await becomeActive(model)
        await settled(model)
        guard case .patch(let second) = model.selectedFile.shown?.content else { throw TestError("No patch") }
        #expect(second === first)

        try write("two\n", to: "new.txt", in: repository)
        await becomeActive(model)
        await settled(model)
        guard case .patch(let third) = model.selectedFile.shown?.content else { throw TestError("No patch") }
        #expect(third !== first)
        #expect(model.selectedFile.shown?.isUpdate == true)
        #expect(shownLines(model)?.contains("two") == true)
        #expect(model.selectedFile.isWaiting == false)
    }

    @Test func selectsTheFirstFileOnceTheSelectedOneIsGone() async throws {
        let (model, repository) = try await modelOfACopy()
        try write("a\n", to: "a-new.txt", in: repository)
        try write("b\n", to: "b-new.txt", in: repository)
        await model.appear()
        model.selectRow(0)
        await settled(model)
        model.selectFile(by: 1)
        await settled(model)
        #expect(model.selectedFile.file?.path == "b-new.txt")

        try FileManager.default.removeItem(atPath: repository + "/b-new.txt")
        await becomeActive(model)
        await settled(model)
        #expect(model.selectedFile.file?.path == "a-new.txt")
    }

    @Test func saysWhyAFileHasNoLinesToShow() async throws {
        let (model, repository) = try await modelOfACopy()
        try write("", to: "empty.txt", in: repository)
        await model.appear()
        model.selectRow(0)
        await settled(model)
        guard case .note(let note) = model.selectedFile.shown?.content else { throw TestError("No note") }
        #expect(note == "This file is empty.")
    }

    @Test func loadsHistoryAgainWhenARefMoved() async throws {
        let (model, repository) = try await modelOfACopy()
        await model.appear()
        let reloads = model.reloads
        await becomeActive(model)
        #expect(model.reloads == reloads)

        try await runGit("commit", "--quiet", "--allow-empty", "--message=New", "--author=Ana <ana@example.com>", in: repository)
        await becomeActive(model)
        #expect(model.reloads == reloads + 1)
        let count = try #require(model.history?.rows.count)
        await model.appear()
        #expect(model.history?.rows.count == count + 1)
    }

    @Test func aRepositoryWithoutCommitsStillShowsItsChanges() async throws {
        let repository = try makeTemporaryFolder() + "/empty"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", in: repository)
        try write("new\n", to: "new.txt", in: repository)
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        let model = RepositoryModel(session: session, worktree: repository, keepsCommitGraphCurrent: { false })
        await model.appear()
        #expect(model.rowCount == 1)
        #expect(model.rowContent(0).lanes?.lines == [])
        model.selectRow(0)
        await settled(model)
        #expect(model.selectedFile.file?.path == "new.txt")
    }

    @Test func reportsHowManyFilesAreUncommitted() async throws {
        let (_, repository) = try await modelOfACopy()
        try write("new\n", to: "new.txt", in: repository)
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        var reported: [Int] = []
        let model = RepositoryModel(session: session, worktree: repository, keepsCommitGraphCurrent: { false }) { reported.append($0) }
        await model.appear()
        #expect(reported.last == 1)
    }

    func chainExists(in repository: String) -> Bool {
        FileManager.default.fileExists(atPath: repository + "/.git/objects/info/commit-graphs/commit-graph-chain")
    }

    @Test func keepingTheCommitGraphUpToDateIsOnByDefault() throws {
        // Nothing writes to these settings, so they leave no file behind.
        let settings = try #require(UserDefaults(suiteName: "roga-tests-never-written"))
        #expect(settings.keepsCommitGraphCurrent)
    }

    @Test func keepsTheCommitGraphUpToDate() async throws {
        let (model, repository) = try await modelOfACopy()
        model.updateCommitGraph()
        #expect(model.commitGraphState == .updating)
        #expect(model.slowHistoryExplanation?.contains("writing one in the background") == true)
        await model.commitGraphUpdate?.value

        #expect(model.commitGraphState == .finished(.written))
        #expect(model.slowHistoryExplanation == nil)
        #expect(chainExists(in: repository))

        model.updateCommitGraph()
        await model.commitGraphUpdate?.value
        #expect(model.commitGraphState == .finished(.upToDate))
    }

    @Test func leavesTheCommitGraphAloneWhenTurnedOff() async throws {
        let (model, repository) = try await modelOfACopy(keepsCommitGraphCurrent: false)
        model.updateCommitGraph()
        #expect(model.commitGraphUpdate == nil)
        #expect(model.commitGraphState == .turnedOff)
        #expect(model.slowHistoryExplanation?.contains("Settings") == true)
        #expect(!chainExists(in: repository))
    }

    @Test func saysWhyItWontWriteTheCommitGraph() async throws {
        let (model, repository) = try await modelOfACopy()
        _ = try await TestGit.make().run(GitCommand("config", "core.commitGraph", "false", in: repository))
        model.updateCommitGraph()
        await model.commitGraphUpdate?.value
        #expect(model.commitGraphState == .finished(.skipped(.turnedOffInGit)))
        #expect(model.slowHistoryExplanation?.contains("core.commitGraph") == true)
    }

    @Test func onlyCallsHistorySlowInALargeRepository() async throws {
        let (model, _) = try await modelOfACopy(keepsCommitGraphCurrent: false)
        await model.load()
        #expect(model.history?.readCommitGraphFiles == false)
        #expect(!model.historyWasSlowToLoad)
    }

    @Test func loadsHistoryAgainAfterALoadWasCancelled() async throws {
        let repository = try await Fixture.repository("basic")
        let model = RepositoryModel(session: try await openSession(), worktree: repository)
        // Like switching to another worktree before history has loaded.
        let cancelled = Task { await model.load() }
        cancelled.cancel()
        await cancelled.value
        #expect(model.history?.isComplete != true)

        await model.load()
        #expect(model.history?.isComplete == true)
    }

    /// A model of the `basic` repository with its history loaded.
    func loadedModel() async throws -> RepositoryModel {
        let model = RepositoryModel(session: try await openSession(), worktree: try await Fixture.repository("basic"))
        await model.load()
        return model
    }

    func row(of hex: String, in model: RepositoryModel) throws -> Int {
        let history = try #require(model.history)
        let id = try #require(ObjectID(hex: hex))
        let position = try #require(history.graph.position(of: id))
        return try #require(history.rows.firstIndex(of: position))
    }

    @Test func showsTheSelectedCommit() async throws {
        let model = try await loadedModel()
        #expect(model.selectedCommit.id == nil)

        model.selectRow(try row(of: Fixture.Basic.main, in: model))
        #expect(model.selectedCommit.id == ObjectID(hex: Fixture.Basic.main))
        await model.selectedCommit.loading?.value

        #expect(model.selectedCommit.info?.subject == "Change the app")
        #expect(model.selectedCommit.info?.body == "The body says why.")
        guard case .loaded(let files) = model.selectedCommit.files else {
            Issue.record("Files aren't loaded: \(model.selectedCommit.files)")
            return
        }
        #expect(files.map(\.path) == ["src/app.txt"])
        #expect(files.first?.lines == .init(added: 1, removed: 0))
        #expect(model.selectedCommit.problem == nil)
    }

    @Test func clearsThePanelWhenNoRowIsSelected() async throws {
        let model = try await loadedModel()
        model.selectRow(0)
        await model.selectedCommit.loading?.value
        #expect(model.selectedCommit.info != nil)

        model.selectRow(nil)
        #expect(model.selectedRow == nil)
        #expect(model.selectedCommit.id == nil)
        #expect(model.selectedCommit.info == nil)
    }

    @Test func showsTheLastCommitSelected() async throws {
        // Stepping through history, faster than git can answer.
        let model = try await loadedModel()
        for row in 0..<model.rowCount { model.selectRow(row) }
        let last = model.selectedCommit.id
        await model.selectedCommit.loading?.value

        #expect(model.selectedCommit.info?.id == last)
        let parents = try #require(model.selectedCommit.info?.parents)
        #expect(parents.isEmpty == (last == ObjectID(hex: Fixture.Basic.mainHistory[2])))
        guard case .loaded(let files) = model.selectedCommit.files else {
            Issue.record("Files aren't loaded: \(model.selectedCommit.files)")
            return
        }
        #expect(files.map(\.path) == ["README.md"])
    }

    @Test func goesToAParent() async throws {
        let model = try await loadedModel()
        let parent = try #require(ObjectID(hex: Fixture.Basic.mainHistory[1]))
        #expect(model.hasCommit(parent))
        model.select(commit: parent)
        #expect(model.selectedCommit.id == parent)
        #expect(model.selectedRow == (try row(of: Fixture.Basic.mainHistory[1], in: model)))
    }

    @Test func ignoresACommitThatHistoryDoesntHave() async throws {
        let model = try await loadedModel()
        let unknown = ObjectID(hex: String(repeating: "1", count: 40))!
        #expect(!model.hasCommit(unknown))
        model.select(commit: unknown)
        #expect(model.selectedCommit.id == nil)
        #expect(model.selectedRow == nil)
    }

    @Test func saysWhenACommitIsMissing() async throws {
        let session = try await openSession()
        let commit = SelectedCommit(session: session)
        commit.show(ObjectID(hex: String(repeating: "1", count: 40))!)
        await commit.loading?.value
        #expect(commit.info == nil)
        #expect(commit.problem?.contains("missing") == true)
    }

    @Test func findsTheSelectedCommitInItsNewRow() async throws {
        let (model, repository) = try await modelOfACopy(keepsCommitGraphCurrent: false)
        await model.load()
        // The oldest commit stays in the last row.
        model.select(commit: try #require(ObjectID(hex: Fixture.Basic.mainHistory[2])))
        let selected = model.selectedCommit.id
        let before = try #require(model.selectedRow)
        #expect(before == model.rowCount - 1)

        _ = try await TestGit.make().run(GitCommand(
            ["-c", "user.name=A", "-c", "user.email=a@example.com", "commit", "--quiet", "--allow-empty", "--message=New"],
            in: repository
        ))
        model.reload()
        await model.load()

        #expect(model.selectedCommit.id == selected)
        #expect(model.selectedRow == before + 1)
    }

    @Test func dropsASelectedCommitThatsGone() async throws {
        let (model, repository) = try await modelOfACopy(keepsCommitGraphCurrent: false)
        let git = try await TestGit.make()
        // A clone only has a remote branch for feature, and removing it leaves
        // its commit out of history.
        await model.load()
        model.select(commit: try #require(ObjectID(hex: Fixture.Basic.feature)))
        await model.selectedCommit.loading?.value
        #expect(model.selectedCommit.info != nil)

        _ = try await git.run(GitCommand("update-ref", "-d", "refs/remotes/origin/feature", in: repository))
        model.reload()
        await model.load()
        #expect(model.selectedCommit.id == nil)
        #expect(model.selectedRow == nil)
    }

    @Test func keepsTheSelectionWhileHistoryHasntReachedTheCommit() async throws {
        // History loads with its first rows and then the rest, so a commit far
        // down isn't in the rows at first.
        let repository = try await Fixture.History.single.repository()
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        let model = RepositoryModel(session: session, worktree: repository)
        await model.load()
        let last = model.rowCount - 1
        #expect(last > 300)
        model.selectRow(last)
        let selected = model.selectedCommit.id

        model.sort = .date
        await model.load()
        #expect(model.selectedCommit.id == selected)
        let row = try #require(model.selectedRow)
        let history = try #require(model.history)
        #expect(history.graph.id(at: history.rows[row]) == selected)
    }

    @Test func copiesTheFullHash() async throws {
        let model = try await loadedModel()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("roga-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        model.selectedCommit.copyHash(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == nil)

        model.select(commit: try #require(ObjectID(hex: Fixture.Basic.main)))
        model.selectedCommit.copyHash(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == Fixture.Basic.main)
    }
}

/// Which refs on a commit share a badge.
struct RowBadgeTests {
    let id = ObjectID(hex: String(repeating: "a", count: 40))!

    func ref(_ name: String, upstream: String? = nil) -> Ref {
        Ref(name: name, target: id, upstream: upstream)
    }

    func titles(_ refs: Ref...) -> [String] {
        RepositoryModel.badges(for: refs, currentBranch: nil).map(\.title)
    }

    @Test func aBranchAndItsUpstreamShareABadge() throws {
        let badges = RepositoryModel.badges(for: [
            ref("refs/heads/main", upstream: "refs/remotes/origin/main"),
            ref("refs/heads/tm/fix", upstream: "refs/remotes/origin/tm/fix"),
            ref("refs/remotes/origin/main"),
            ref("refs/remotes/origin/tm/fix"),
        ], currentBranch: "refs/heads/main")
        #expect(badges.map(\.title) == ["main", "tm/fix"])
        #expect(badges.map(\.kind) == [.currentBranch, .branch])
        #expect(badges.map(\.refName) == ["refs/heads/main", "refs/heads/tm/fix"])
        #expect(badges.map(\.upstream) == ["refs/remotes/origin/main", "refs/remotes/origin/tm/fix"])
    }

    @Test func aBranchThatTracksNothingKeepsItsOwnBadge() {
        #expect(titles(ref("refs/heads/fix"), ref("refs/remotes/origin/fix")) == ["fix", "origin/fix"])
    }

    @Test func anUpstreamOnAnotherCommitIsntMentioned() throws {
        let badges = RepositoryModel.badges(for: [ref("refs/heads/main", upstream: "refs/remotes/origin/main")], currentBranch: nil)
        #expect(badges.map(\.title) == ["main"])
        #expect(badges.first?.upstream == nil)
    }

    @Test func anUpstreamOfAnotherNameKeepsItsOwnBadge() {
        #expect(titles(ref("refs/heads/fix", upstream: "refs/remotes/origin/tm/fix"), ref("refs/remotes/origin/tm/fix")) == ["fix", "origin/tm/fix"])
    }

    @Test func everyRemotesBranchOfTheSameNameJoinsABranchAndItsUpstream() {
        let badges = RepositoryModel.badges(for: [
            ref("refs/heads/tm/fix", upstream: "refs/remotes/origin/tm/fix"),
            ref("refs/remotes/backup/tm/fix"),
            ref("refs/remotes/origin/tm/fix"),
            ref("refs/remotes/upstream/tm/fix"),
        ], currentBranch: "refs/heads/tm/fix")
        #expect(badges.map(\.title) == ["tm/fix"])
        #expect(badges.first?.kind == .currentBranch)
        #expect(badges.first?.upstream == "refs/remotes/origin/tm/fix")
        #expect(badges.first?.otherRemoteBranches == ["refs/remotes/backup/tm/fix", "refs/remotes/upstream/tm/fix"])
    }

    @Test func eachBranchTakesOnlyTheRemoteBranchesWithItsOwnName() {
        let badges = RepositoryModel.badges(for: [
            ref("refs/heads/feature", upstream: "refs/remotes/origin/feature"),
            ref("refs/heads/main", upstream: "refs/remotes/origin/main"),
            ref("refs/remotes/origin/feature"),
            ref("refs/remotes/origin/main"),
            ref("refs/remotes/upstream/main"),
            ref("refs/remotes/upstream/mcp-dev"),
            ref("refs/remotes/upstream/tm/main"),
        ], currentBranch: nil)
        #expect(badges.map(\.title) == ["feature", "main", "upstream/mcp-dev", "upstream/tm/main"])
        #expect(badges.map(\.otherRemoteBranches) == [[], ["refs/remotes/upstream/main"], [], []])
    }

    @Test func anotherRemotesBranchKeepsItsOwnBadgeWithoutAnUpstreamToJoin() {
        // The upstream has moved to another commit, so the branch has no cloud.
        #expect(titles(ref("refs/heads/main", upstream: "refs/remotes/origin/main"), ref("refs/remotes/upstream/main")) == ["main", "upstream/main"])
        #expect(titles(ref("refs/heads/fix"), ref("refs/remotes/origin/fix"), ref("refs/remotes/upstream/fix")) == ["fix", "origin/fix", "upstream/fix"])
        #expect(titles(ref("refs/remotes/origin/main"), ref("refs/remotes/upstream/main")) == ["origin/main", "upstream/main"])
    }

    @Test func aTagIsUnaffected() {
        #expect(titles(ref("refs/heads/main", upstream: "refs/remotes/origin/main"), ref("refs/remotes/origin/main"), ref("refs/tags/v1.0")) == ["main", "v1.0"])
    }
}
