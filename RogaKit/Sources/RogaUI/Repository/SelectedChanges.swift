import AgentEngine
import DiffUI
import Foundation
import GitCore
import GitRunner
import Observation
import RepositoryEngine

/// A worktree's uncommitted changes while their row in history is selected,
/// and what the panel shows about them. As with a commit, the files that are
/// showing stay until the new ones arrive.
@Observable
final class SelectedChanges {
    enum Files: Equatable {
        case loading
        case loaded(WorktreeChanges)
        /// git couldn't list them. The message says why.
        case failed(String)
    }

    /// The groups in the order the panel lists them.
    static let groups: [WorktreeChanges.Group] = [.conflicted, .unstaged, .untracked, .staged]

    /// Whether the row is selected.
    private(set) var isSelected = false
    private(set) var files = Files.loading
    /// The same one the selected commit uses, because they share the diff
    /// panel.
    let selectedFile: SelectedFile
    /// The same one the selected commit uses, because the panels take each
    /// other's place.
    let fileList: FileListModel
    /// Goes up when the user moves through the list of files, so that the list
    /// knows to scroll to the selected file.
    private(set) var fileSteps = 0

    /// Goes up when something asks for the keyboard to go to the list of files.
    private(set) var focusRequests = 0
    /// What's been thrown away and can still be brought back, oldest first.
    private(set) var discards: [Discard] = []
    /// A discard that's waiting for someone to agree to it.
    var pendingDiscard: PendingDiscard?

    /// Says what's uncommitted, whenever the files have been listed.
    @ObservationIgnored var onLoad: ((WorktreeChanges) -> Void)?
    /// Says what git refused, with a title for saying so.
    @ObservationIgnored var onFailure: ((_ title: String, _ error: any Error) -> Void)?
    /// Says that a discard is done, or that one came back, and whether it can be undone.
    @ObservationIgnored var onDiscard: ((_ words: String, _ canUndo: Bool) -> Void)?
    /// Whether everything can go now, which it can't while something else is running
    /// or the worktree is stuck partway, since `git reset --hard` would end a merge.
    @ObservationIgnored var canDiscardEverything: () -> Bool = { true }
    /// Asks the worktree's model to look at what changed, for when the row isn't selected.
    @ObservationIgnored var lookAgain: () -> Void = {}
    /// Asks the worktree's model to select the row for uncommitted changes.
    @ObservationIgnored var showChanges: () -> Void = {}
    /// Says in the title row which submodules staging left out, and why
    /// (decision 75).
    @ObservationIgnored var onLeftOut: (_ words: String) -> Void = { _ in }
    /// Asks the worktree's model to check out the commit that's recorded for a
    /// submodule, which runs as its other commands do, one at a time.
    @ObservationIgnored var runSubmoduleUpdate: (DiffFile) -> Void = { _ in }
    /// Reading what the rows of the submodules among the files say, which
    /// starts once the files are listed, and nil once they've been read.
    @ObservationIgnored private(set) var readingSubmodules: Task<Void, Never>?
    /// Counts those readings, so that one a newer list has replaced doesn't
    /// say the newer one is done.
    @ObservationIgnored private var submoduleReads = 0
    /// Staging that's waiting for the submodules to be read, because until
    /// then nothing says which of them it would take commits away from.
    @ObservationIgnored private(set) var waitingToStage: Task<Void, Never>?
    /// Finding out what's uncommitted before asking whether all of it should go.
    @ObservationIgnored private(set) var preparingDiscard: Task<Void, Never>?
    /// The patch that a hunk was last taken from, because its button stays until the
    /// new one is read, and the same hunk can't come out twice.
    @ObservationIgnored private var discardedHunkFrom: [UInt8]?
    /// What's waiting to go to git, oldest first.
    @ObservationIgnored private var indexChanges: [IndexChange] = []
    /// The changes being sent to git. Only one git writes the index at a time, and
    /// nothing read in the meantime is up to date.
    @ObservationIgnored private(set) var applyingIndexChanges: Task<Void, Never>?
    /// The load in progress, which a newer one cancels.
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    @ObservationIgnored private var patience: Task<Void, any Error>?
    /// What's been resolved in each conflicted file, which the diff panel shows
    /// (decision 60).
    @ObservationIgnored let conflicts = ConflictResolution()
    /// The conflict being written to its file, which the next one waits for, so
    /// that each starts from what the last one wrote.
    @ObservationIgnored private(set) var resolving: Task<Void, Never>?
    @ObservationIgnored private let session: RepositorySession
    @ObservationIgnored private let worktree: String

    init(session: RepositorySession, worktree: String, selectedFile: SelectedFile, fileList: FileListModel) {
        self.session = session
        self.worktree = worktree
        self.selectedFile = selectedFile
        self.fileList = fileList
        selectedFile.conflictResolution = conflicts
    }

    /// Selects the row, and selects the first file once they're listed.
    func select() {
        guard !isSelected else { return }
        isSelected = true
        selectedFile.cancelLoading()
        startLoading(selectingFirstFile: true)
    }

    /// Deselects the row, because something else is selected.
    func deselect() {
        guard isSelected else { return }
        isSelected = false
        loading?.cancel()
        loading = nil
        patience?.cancel()
    }

    /// Lists the files again, and reads the selected file again if it's still
    /// listed. Without it, the first file is selected.
    func refresh() {
        guard isSelected else { return }
        startLoading(selectingFirstFile: false)
    }

    /// Selects one of the files.
    func select(_ file: DiffFile, in group: WorktreeChanges.Group) {
        guard case .loaded(let changes) = files else { return }
        selectedFile.show(file, from: source(group, changes))
    }

    /// Selects the file `step` places from the selected one among the rows that
    /// show, going through the groups in order, and stops at the ends of the list.
    func selectFile(by step: Int) {
        guard case .loaded(let changes) = files else { return }
        select(rows(of: changes).file(step, from: selectedFile.file?.path, in: selectedFile.group), in: changes)
    }

    /// Selects the first file among the rows that show.
    func selectFirstFile() {
        guard case .loaded(let changes) = files else { return }
        select(rows(of: changes).firstFile, in: changes)
    }

    private func select(_ row: FileRow?, in changes: WorktreeChanges) {
        guard let file = row?.file, let group = row?.group else { return }
        selectedFile.show(file, from: source(group, changes))
        fileSteps += 1
    }

    /// The rows that show of every group, in order.
    private func rows(of changes: WorktreeChanges) -> [FileRow] {
        Self.groups.flatMap { fileList.rows(of: changes[$0], in: $0) }
    }

    func askForFocus() {
        focusRequests += 1
    }

    // MARK: Staging

    /// What's loaded, if anything.
    var loaded: WorktreeChanges? {
        if case .loaded(let changes) = files { changes } else { nil }
    }

    /// Stages a file, or takes it back out if it's a staged one. Staging a conflict
    /// says it's resolved.
    func toggle(_ file: DiffFile, in group: WorktreeChanges.Group) {
        // The row as it's listed now, which has what's been read about a
        // submodule since the file was selected, for the row it moves to.
        let file = listed(file, in: group)
        if group == .conflicted {
            conflicts.forget(file.path)
            agentWork[file.path] = nil
        }
        apply(group == .staged ? .unstage([file]) : .stage([file]), from: group)
    }

    /// Stages or takes back out the file selected, the way Space and the menu do.
    /// A submodule's row does nothing unless staging it records new commits,
    /// because Space is pressed down a list without reading each row, and its
    /// own buttons say what's right for it (decision 75).
    func toggleSelectedFile() {
        guard let file = selectedFile.file, let group = selectedFile.group else { return }
        if group == .unstaged, let staging = listed(file, in: group).submoduleStaging, staging != .recordsNewCommits { return }
        toggle(file, in: group)
    }

    /// The file as the list has it now, which says more about a submodule than
    /// the file did when it was selected, once the submodule has been read.
    func listed(_ file: DiffFile, in group: WorktreeChanges.Group) -> DiffFile {
        loaded?[group].first { $0.path == file.path } ?? file
    }

    /// Stages or takes back out every file in a group that the filter leaves.
    func toggleAll(in group: WorktreeChanges.Group) {
        toggle(in: group) { [fileList] changes in fileList.matching(changes[group], in: group) }
    }

    /// Stages or takes back out every file under a folder of a group.
    func toggleFolder(_ path: String, in group: WorktreeChanges.Group) {
        toggle(in: group) { changes in changes[group].filter { $0.path.hasPrefix(path + "/") } }
    }

    /// Stages several files of a group, or takes them back out.
    ///
    /// Staging leaves out a submodule that it would take commits away from, and
    /// the title row says which and why, because nobody staging everything has
    /// looked at each row, and recording a checkout that's behind is how a
    /// branch loses an update someone else made (decision 75). It also leaves
    /// out a submodule with nothing of its own to stage. While the submodules
    /// are still being read, which takes a moment after the list shows, it
    /// waits for that.
    ///
    /// - Parameter pick: Picks the files from the list, which is the newer
    ///   one after a wait.
    private func toggle(in group: WorktreeChanges.Group, afterReading: Bool = false, _ pick: @escaping (WorktreeChanges) -> [DiffFile]) {
        guard let loaded else { return }
        let files = pick(loaded)
        guard group == .unstaged else {
            if !files.isEmpty { apply(group == .staged ? .unstage(files) : .stage(files), from: group) }
            return
        }
        // A row can still say what was read the time before, which a newer
        // reading may be about to change, so this waits for one that's running.
        let hasSubmoduleToRead = files.contains { file in file.submoduleStaging.map { $0 != .nothingToStage } ?? false }
        if !afterReading, let reading = readingSubmodules, hasSubmoduleToRead {
            waitingToStage = Task {
                await reading.value
                toggle(in: group, afterReading: true, pick)
            }
            return
        }
        let staged = files.filter { $0.submoduleStaging.map { $0 == .recordsNewCommits } ?? true }
        if !staged.isEmpty { apply(.stage(staged), from: group) }
        if let words = SubmoduleWords.leftOutSentence(files.filter { $0.submoduleStaging?.isLeftOutOfStagingAll == true }) {
            onLeftOut(words)
        }
    }

    /// Checks out the commit that's recorded for a submodule, which is what's
    /// wanted for one that's behind (decision 75).
    func updateSubmodule(_ file: DiffFile) {
        runSubmoduleUpdate(file)
    }

    // MARK: Resolving conflicts

    /// Resolves one of the selected file's conflicts, or puts one back, when it's
    /// showing its conflicts (decision 60).
    var conflictResolve: ((ConflictRequest) -> Void)? {
        guard selectedFile.shown?.conflicts?.total ?? 0 > 0, case .worktree(_, .conflicted, _) = selectedFile.shown?.source else { return nil }
        return { [weak self] request in self?.resolve(request) }
    }

    /// Writes what resolves a conflict into the selected file, or puts the conflict
    /// back as it was, and shows the file again.
    func resolve(_ request: ConflictRequest) {
        guard let file = selectedFile.file, selectedFile.group == .conflicted else { return }
        update(file, failure: "Can't resolve the conflict in \(file.name)") { progress in
            switch request {
            case .choose(let conflict, let choice):
                progress.choices[conflict] = choice
                progress.writtenBy[conflict] = nil
            case .undo(let conflict):
                progress.choices[conflict] = nil
                progress.writtenBy[conflict] = nil
                progress.shownSides.remove(conflict)
            case .showSides(let conflict, let shows):
                if shows { progress.shownSides.insert(conflict) } else { progress.shownSides.remove(conflict) }
            }
        }
    }

    /// Changes what's been resolved in a conflicted file, writes the file when
    /// that changes what it has, and shows it again. Each change waits for the one
    /// before, so that it starts from what that one wrote.
    private func update(_ file: DiffFile, failure: String, _ change: @escaping (inout ConflictResolution.Progress) -> Void) {
        let previous = resolving
        resolving = Task {
            await previous?.value
            defer { resolving = nil }
            guard var progress = conflicts.progress(of: file.path) else { return }
            let before = progress.current
            change(&progress)
            do {
                if progress.current != before {
                    try await session.write(progress.current, replacing: before, at: file.path, in: worktree)
                }
                conflicts.remember(progress, for: file.path)
            } catch {
                onFailure?(failure, error)
            }
            guard selectedFile.file?.path == file.path, let changes = loaded else { return }
            selectedFile.refresh(file, from: source(.conflicted, changes))
            await selectedFile.loading?.value
        }
    }

    // MARK: Asking an agent

    /// An agent resolving a file's conflicts, or what came of it (decision 60).
    struct AgentWork: Equatable {
        enum Phase: Equatable {
            case working(since: Date)
            case done(explanation: String, resolved: Int, duration: Duration)
            case failed(message: String, output: String?)
        }

        var kind: AgentKind
        /// The agent and its model, as Generate names them.
        var label: String
        /// How many conflicts it was asked about.
        var asked: Int
        var phase: Phase
    }

    /// What agents are doing or did about each conflicted file, by its path.
    private(set) var agentWork: [String: AgentWork] = [:]
    /// The agents running, by the file's path, which Stop cancels.
    @ObservationIgnored private var agentRuns: [String: Task<Void, Never>] = [:]
    /// Runs an agent's command with its standard input, which tests replace.
    @ObservationIgnored var runAgent: (@Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult)?

    /// How many lines on each side of a conflict go to the agent with it.
    static let agentContextLines = 8

    /// Asks the agent Generate runs to resolve the selected file's conflicts that
    /// are left, and writes what it sends back in their place, for someone to
    /// read over. It's the agent and model from the Commit page of Settings
    /// (decision 41), and it runs the same way, with no tools.
    func askAgent(_ setup: GenerationSetup?) {
        guard let setup, let file = selectedFile.file, selectedFile.group == .conflicted, agentRuns[file.path] == nil,
              let sides = selectedFile.shown?.conflicts?.sides, let progress = conflicts.progress(of: file.path), progress.left > 0
        else { return }
        let path = file.path
        let open = progress.original.conflicts.indices.filter { progress.choices[$0] == nil }
        let request = ConflictResolutionRequest(
            worktree: worktree,
            path: path,
            ours: .init(name: sides.ours.name, detail: sides.ours.detail),
            theirs: .init(name: sides.theirs.name, detail: sides.theirs.detail),
            conflicts: open.map { Self.agentConflict($0, of: progress.original) }
        )
        func work(_ phase: AgentWork.Phase) -> AgentWork {
            AgentWork(kind: setup.kind, label: setup.label, asked: open.count, phase: phase)
        }
        guard request.fits else {
            agentWork[path] = work(.failed(message: "These conflicts are too big to send to \(setup.kind.name). Resolve them here or in your editor.", output: nil))
            return
        }
        let run = runAgent ?? { [programs = setup.programs] command, input in
            try await programs.run(command, input: input)
        }
        agentWork[path] = work(.working(since: Date()))
        agentRuns[path] = Task {
            defer { agentRuns[path] = nil }
            do {
                let resolution = try await ConflictResolutionWriter.resolve(request, with: setup.agent, run: run)
                try Task.checkCancellation()
                // Someone may have resolved some of them meanwhile, and those stay.
                update(file, failure: "Unable to save \(setup.kind.name) output for \(file.name)") { progress in
                    for (asked, index) in open.enumerated() where progress.choices[index] == nil {
                        guard let text = resolution.lines[asked] else { continue }
                        progress.choices[index] = .lines(ConflictedFile.lines(typed: text))
                        progress.writtenBy[index] = setup.kind.name
                    }
                }
                await resolving?.value
                let written = conflicts.progress(of: path).map { progress in open.filter { progress.writtenBy[$0] != nil }.count } ?? 0
                agentWork[path] = written == 0 ? nil : work(.done(explanation: resolution.explanation, resolved: written, duration: resolution.duration))
            } catch is CancellationError {
                agentWork[path] = nil
            } catch {
                let output = (error as? CommitMessageError)?.output
                agentWork[path] = work(.failed(message: String(describing: error), output: output))
            }
        }
    }

    /// Stops the agent resolving a file's conflicts, which changes nothing.
    func stopAgent(for path: String) {
        agentRuns[path]?.cancel()
        agentRuns[path] = nil
        agentWork[path] = nil
    }

    /// Lets go of what an agent said about a file, once it's been read.
    func forgetAgentWork(for path: String) {
        guard agentRuns[path] == nil else { return }
        agentWork[path] = nil
    }

    /// A conflict as an agent is sent it, with a few of the file's lines on each
    /// side, but never into the conflicts next to it.
    static func agentConflict(_ index: Int, of file: ConflictedFile) -> ConflictResolutionRequest.Conflict {
        let conflict = file.conflicts[index]
        let floor = index > 0 ? file.conflicts[index - 1].range.upperBound : 0
        let ceiling = index + 1 < file.conflicts.count ? file.conflicts[index + 1].range.lowerBound : file.bytes.count
        func text(_ bytes: ArraySlice<UInt8>) -> String { String(decoding: bytes, as: UTF8.self) }
        // The lines before end at the conflict's first marker, which starts a line.
        var start = conflict.range.lowerBound
        var lines = 0
        while start > floor, lines <= agentContextLines {
            start -= 1
            if file.bytes[start] == 0x0A { lines += 1 }
        }
        if start > floor || lines > agentContextLines { start += 1 }
        var end = conflict.range.upperBound
        lines = 0
        while end < ceiling, lines < agentContextLines {
            if file.bytes[end] == 0x0A { lines += 1 }
            end += 1
        }
        return ConflictResolutionRequest.Conflict(
            before: text(file.bytes[start..<conflict.range.lowerBound]),
            ours: text(file.bytes[conflict.ours]),
            base: conflict.base.map { text(file.bytes[$0]) },
            theirs: text(file.bytes[conflict.theirs]),
            after: text(file.bytes[conflict.range.upperBound..<end])
        )
    }

    /// Puts a file's conflicts back: as Roga first read them when it has resolved
    /// some, or as git first wrote them otherwise, such as after an editor or an
    /// agent resolved them outside Roga.
    func putConflictsBack(in file: DiffFile) {
        agentWork[file.path] = nil
        if let progress = conflicts.progress(of: file.path), !progress.choices.isEmpty {
            update(file, failure: "Can't put the conflicts back in \(file.name)") { progress in
                progress.choices = [:]
                progress.writtenBy = [:]
                progress.shownSides = []
            }
            return
        }
        conflicts.forget(file.path)
        let previous = resolving
        resolving = Task {
            await previous?.value
            defer { resolving = nil }
            do {
                try await session.putConflictsBack(in: file.path, in: worktree)
            } catch {
                onFailure?("Can't put the conflicts back in \(file.name)", error)
            }
            refresh()
        }
    }

    /// Takes one side's whole version of a conflicted file, and marks it resolved.
    func keep(_ side: ConflictSide, of file: DiffFile) {
        conflicts.forget(file.path)
        let previous = resolving
        resolving = Task {
            await previous?.value
            defer { resolving = nil }
            do {
                try await session.keep(side, of: file.path, in: worktree)
            } catch {
                onFailure?("Can't keep a version of \(file.name)", error)
            }
            refresh()
            lookAgain()
        }
    }

    // MARK: Discarding

    /// Something thrown away that can still be brought back (decision 39).
    struct Discard {
        let changes: DiscardedChanges
        let broughtBackWords: String
    }

    /// A discard of more than one file, or of everything, which asks first.
    enum PendingDiscard {
        /// Where the files are, which the dialog says.
        enum Place: Equatable {
            case folder(String)
            case heading
            case matchingFilter
        }

        case files([DiffFile], from: WorktreeChanges.Group, place: Place)
        case everything(WorktreeChanges)
    }

    /// How many discards can be brought back, one at a time, and how much memory their
    /// patches can take. It's for slips rather than a history, so the oldest go first.
    static let discardLimit = 20
    static let discardedBytesLimit = 128 << 20

    /// Takes back a file's changes, without asking, since Undo brings them back.
    func discard(_ file: DiffFile, in group: WorktreeChanges.Group) {
        guard group.discarding(file) != nil else { return }
        apply(.discard([file], from: group), from: group)
    }

    /// Whether the file selected has something to discard.
    var canDiscardSelectedFile: Bool {
        guard let file = selectedFile.file, let group = selectedFile.group else { return false }
        return group.discarding(file) != nil
    }

    func discardSelectedFile() {
        guard let file = selectedFile.file, let group = selectedFile.group else { return }
        discard(file, in: group)
    }

    /// Asks whether every file in a group that the filter leaves should go.
    func askToDiscardAll(in group: WorktreeChanges.Group) {
        guard let loaded else { return }
        ask(toDiscard: fileList.matching(loaded[group], in: group), from: group, place: fileList.filter.isEmpty ? .heading : .matchingFilter)
    }

    /// Asks whether every file under a folder of a group should go.
    func askToDiscardFolder(_ path: String, in group: WorktreeChanges.Group) {
        guard let loaded else { return }
        ask(toDiscard: loaded[group].filter { $0.path.hasPrefix(path + "/") }, from: group, place: .folder(path))
    }

    /// One file doesn't ask, wherever it's asked from, because it's the same as
    /// discarding it from its own row.
    private func ask(toDiscard files: [DiffFile], from group: WorktreeChanges.Group, place: PendingDiscard.Place) {
        let files = files.filter { group.discarding($0) != nil }
        if files.count == 1 {
            discard(files[0], in: group)
        } else if !files.isEmpty {
            pendingDiscard = .files(files, from: group, place: place)
        }
    }

    /// Asks whether everything uncommitted should go, from what git says now, because
    /// the row can be right-clicked while its files aren't loaded.
    func askToDiscardEverything() {
        guard canDiscardEverything() else { return }
        preparingDiscard = Task {
            do {
                let changes = try await session.status(in: worktree)
                guard changes.hasSomethingToDiscard else { return }
                pendingDiscard = .everything(changes)
            } catch {
                onFailure?("Can't discard the changes", error)
            }
        }
    }

    /// Goes ahead with what's been asked.
    func confirmDiscard() {
        guard let pending = pendingDiscard else { return }
        pendingDiscard = nil
        switch pending {
        case .files(let files, let group, _):
            apply(.discard(files, from: group), from: group)
        case .everything(let changes):
            guard canDiscardEverything() else { return }
            let change = IndexChange.discardEverything(trashing: changes.trashedWhenDiscardingEverything)
            if isSelected, let loaded {
                let changed = change.applied(to: loaded)
                files = .loaded(changed)
                onLoad?(changed)
            }
            indexChanges.append(change)
            startApplyingIndexChanges()
        }
    }

    /// What takes a hunk of the diff out of the file, by the index of its header among
    /// the patch's lines, or nil when the hunks showing can't be taken out on their own:
    /// staged ones, and the only hunk of a file that's new or gone, which is the file.
    /// A whole file has no hunks to take out either (decision 74).
    var hunkDiscard: ((Int) -> Void)? {
        guard let shown = selectedFile.shown, case .worktree(_, .unstaged, _) = shown.source, shown.file.status == .modified,
              case .patch(let document) = shown.content, document.layout == .hunks
        else { return nil }
        return { [weak self] header in self?.discardHunk(at: header) }
    }

    func discardHunk(at header: Int) {
        guard loaded != nil, hunkDiscard != nil, let shown = selectedFile.shown, let patch = selectedFile.shownPatch,
              patch.bytes != discardedHunkFrom, let hunk = patch.hunk(at: header)
        else { return }
        discardedHunkFrom = patch.bytes
        apply(.discardHunk(hunk, of: shown.file, isLast: patch.hunkCount == 1), from: .unstaged)
    }

    /// Brings back the latest discard, whichever that is, so that one key goes back
    /// through a few slips in a row.
    func undoDiscard() {
        guard let last = discards.popLast() else { return }
        indexChanges.append(.bringBack(last))
        startApplyingIndexChanges()
    }

    private func remember(_ changes: DiscardedChanges, words: (discarded: String, broughtBack: String)) {
        guard changes.canBeBroughtBack else {
            onDiscard?(words.discarded, false)
            return
        }
        discards.append(Discard(changes: changes, broughtBackWords: words.broughtBack))
        while discards.count > Self.discardLimit || discards.reduce(0, { $0 + $1.changes.keptBytes }) > Self.discardedBytesLimit, discards.count > 1 {
            discards.removeFirst()
        }
        onDiscard?(words.discarded, true)
    }

    /// Moves files straight away, and sends the change to git behind that, because
    /// on a large repository, waiting for git and then for a new list after each
    /// press of Space would feel slow. A new list follows and corrects the counts.
    private func apply(_ change: IndexChange, from group: WorktreeChanges.Group) {
        guard let loaded else { return }
        let before = rows(of: loaded).filter { $0.file != nil }
        let path = selectedFile.file?.path
        let isMovingSelection = selectedFile.group == group && path.map { path in change.files.contains { $0.path == path } } == true
        let place = isMovingSelection ? before.firstIndex { $0.group == group && $0.file?.path == path } : nil

        let changed = change.applied(to: loaded)
        files = .loaded(changed)
        onLoad?(changed)
        if let place {
            // What took its place, so that going down a list is one key per file.
            let after = rows(of: changed).filter { $0.file != nil }
            if after.isEmpty {
                selectedFile.show(nil, from: nil)
            } else {
                select(after[min(place, after.count - 1)], in: changed)
            }
        }
        indexChanges.append(change)
        startApplyingIndexChanges()
    }

    private func startApplyingIndexChanges() {
        guard applyingIndexChanges == nil else { return }
        applyingIndexChanges = Task {
            var hasDiscarded = false
            while let next = takeIndexChanges() {
                hasDiscarded = hasDiscarded || next.isDiscard
                do {
                    try await send(next)
                } catch is CancellationError {
                } catch {
                    // Whatever was waiting was based on this working. The new list
                    // shows how things really are. What didn't come back stays ready,
                    // because its patch is the only copy.
                    discards += ([next] + indexChanges).reversed().compactMap(\.broughtBack)
                    indexChanges = []
                    discardedHunkFrom = nil
                    onFailure?(next.failureTitle, error)
                }
            }
            applyingIndexChanges = nil
            if hasDiscarded, !isSelected {
                lookAgain()
            } else {
                refresh()
            }
        }
    }

    /// The oldest change, along with the ones right after it of the same kind, so
    /// that several presses in a row go to one git.
    private func takeIndexChanges() -> IndexChange? {
        guard var change = indexChanges.first else { return nil }
        var taken = 1
        for next in indexChanges.dropFirst() {
            guard let merged = change.merging(next) else { break }
            change = merged
            taken += 1
        }
        indexChanges.removeFirst(taken)
        return change
    }

    private func send(_ change: IndexChange) async throws {
        switch change {
        case .stage(let files): try await session.stage(files, in: worktree)
        case .unstage(let files): try await session.unstage(files, in: worktree)
        case .discard(let files, let group):
            remember(try await session.discard(files, from: group, in: worktree), words: IndexChange.words(discarding: files, from: group))
        case .discardHunk(let hunk, let file, _):
            remember(try await session.discard(hunk, in: worktree), words: ("Discarded a hunk of \(file.name)", "Brought back a hunk of \(file.name)"))
        case .discardEverything(let files):
            remember(try await session.discardEverything(trashing: files, in: worktree), words: ("Discarded all changes", "Brought back the changes"))
        case .bringBack(let discard):
            try await session.bringBack(discard.changes, in: worktree)
            discardedHunkFrom = nil
            onDiscard?(discard.broughtBackWords, false)
            showChanges()
        }
    }

    private func source(_ group: WorktreeChanges.Group, _ changes: WorktreeChanges) -> PatchSource {
        .worktree(path: worktree, group: group, head: changes.head)
    }

    private func startLoading(selectingFirstFile: Bool) {
        loading?.cancel()
        patience?.cancel()
        patience = Task {
            try await Task.sleep(for: SelectedFile.patience)
            try Task.checkCancellation()
            // Looking at the files again leaves the list as it is meanwhile.
            if case .loaded = files, !selectingFirstFile { return }
            files = .loading
        }
        loading = Task { await load(selectingFirstFile: selectingFirstFile) }
    }

    private func load(selectingFirstFile: Bool) async {
        do {
            var changes = try await session.changes(in: worktree)
            try Task.checkCancellation()
            patience?.cancel()
            // It's out of date already. A new list follows once git has them all.
            guard applyingIndexChanges == nil, indexChanges.isEmpty else { return }
            // What was read about a submodule stays on its row until it's been
            // read again, so that the row doesn't lose its words on every look.
            if let loaded { changes.keepSubmodules(readIn: loaded) }
            files = .loaded(changes)
            onLoad?(changes)
            readSubmodules(in: changes)

            if !selectingFirstFile, let group = selectedFile.group, let path = selectedFile.file?.path,
               let file = changes[group].first(where: { $0.path == path })
            {
                selectedFile.refresh(file, from: source(group, changes))
                // The patch showing is as new as it gets, so the guard against taking
                // the same hunk twice has done its job. The file could come back to
                // exactly this patch later.
                await selectedFile.loading?.value
                discardedHunkFrom = nil
                return
            }
            // A filter that leaves none of them leaves the diff panel the first
            // of all.
            let first = rows(of: changes).firstFile.flatMap { row in row.file.flatMap { file in row.group.map { ($0, file) } } }
                ?? Self.groups.lazy.compactMap { group in changes[group].first.map { (group, $0) } }.first
            selectedFile.show(first?.1, from: first.map { source($0.0, changes) })
        } catch is CancellationError {
        } catch {
            patience?.cancel()
            files = .failed(String(describing: error))
            selectedFile.show(nil, from: nil)
        }
    }

    /// Reads what the rows of the submodules among the files say, such as how
    /// far a checkout is behind what's recorded, and adds that to the rows
    /// (decision 75). It reads each submodule's own repository, so it starts
    /// once the list shows, and listing a worktree's files takes no longer than
    /// it did. A row that has changed since it was listed keeps what it has.
    private func readSubmodules(in changes: WorktreeChanges) {
        readingSubmodules?.cancel()
        let groups: [WorktreeChanges.Group] = [.unstaged, .staged]
        guard groups.contains(where: { changes[$0].contains { $0.isSubmodule } }) else {
            readingSubmodules = nil
            return
        }
        submoduleReads += 1
        let number = submoduleReads
        readingSubmodules = Task { [session, worktree] in
            for group in groups {
                let submodules = changes[group].filter(\.isSubmodule)
                guard !submodules.isEmpty,
                      let read = try? await session.submoduleChanges(of: submodules, from: source(group, changes), in: worktree),
                      !Task.isCancelled, var current = loaded
                else { continue }
                current.setSubmodules(read, in: group, asListed: submodules)
                if current != loaded { files = .loaded(current) }
            }
            // Nothing is being read any more, unless a newer list has started
            // reading its own.
            if number == submoduleReads { readingSubmodules = nil }
        }
    }
}

/// One change to a worktree's index that someone asked for.
private enum IndexChange {
    case stage([DiffFile])
    case unstage([DiffFile])
    case discard([DiffFile], from: WorktreeChanges.Group)
    /// `isLast` says that it's the file's only hunk, so the file goes from the list too.
    case discardHunk(HunkPatch, of: DiffFile, isLast: Bool)
    case discardEverything(trashing: [DiffFile])
    case bringBack(SelectedChanges.Discard)

    /// The files that leave their list, which the selection can't stay on.
    var files: [DiffFile] {
        switch self {
        case .stage(let files), .unstage(let files), .discard(let files, _): files
        case .discardHunk(_, let file, let isLast): isLast ? [file] : []
        case .discardEverything, .bringBack: []
        }
    }

    var isDiscard: Bool {
        switch self {
        case .stage, .unstage: false
        case .discard, .discardHunk, .discardEverything, .bringBack: true
        }
    }

    var broughtBack: SelectedChanges.Discard? {
        if case .bringBack(let discard) = self { discard } else { nil }
    }

    var failureTitle: String {
        switch self {
        case .stage(let files): files.count == 1 ? "Can't stage \(files[0].name)" : "Can't stage the files"
        case .unstage(let files): files.count == 1 ? "Can't unstage \(files[0].name)" : "Can't unstage the files"
        case .discard(let files, _): files.count == 1 ? "Can't discard \(files[0].name)" : "Can't discard the files"
        case .discardHunk(_, let file, _): "Can't discard the hunk of \(file.name)"
        case .discardEverything: "Can't discard the changes"
        case .bringBack: "Can't undo the discard"
        }
    }

    /// What the title row says about discarding some files, and bringing them back.
    static func words(discarding files: [DiffFile], from group: WorktreeChanges.Group) -> (discarded: String, broughtBack: String) {
        let isOne = files.count == 1
        let named = isOne ? files[0].name : "\(files.count.formatted()) files"
        let goToTrash = files.allSatisfy { group.discarding($0) == .trash }
        return (goToTrash ? "Moved \(named) to the Trash" : "Discarded \(named)", "Brought back \(named)")
    }

    /// This and the next one as one, if they're the same kind.
    func merging(_ next: IndexChange) -> IndexChange? {
        switch (self, next) {
        case (.stage(let files), .stage(let more)): .stage(files + more)
        case (.unstage(let files), .unstage(let more)): .unstage(files + more)
        default: nil
        }
    }

    func applied(to changes: WorktreeChanges) -> WorktreeChanges {
        switch self {
        case .stage(let files): changes.staging(files)
        case .unstage(let files): changes.unstaging(files)
        case .discard(let files, _): changes.discarding(files)
        case .discardHunk(_, let file, let isLast): isLast ? changes.discarding([file]) : changes
        case .discardEverything: changes.discardingEverything()
        case .bringBack: changes
        }
    }
}

extension WorktreeChanges {
    /// How the lists will look once git has staged these files, until git says for
    /// itself. A file with changes on both sides adds up its counts.
    func staging(_ moved: [DiffFile]) -> WorktreeChanges {
        var changes = self
        let paths = Set(moved.map(\.path))
        changes.unstaged.removeAll { paths.contains($0.path) }
        changes.untracked.removeAll { paths.contains($0.path) }
        changes.conflicted.removeAll { paths.contains($0.path) }
        for var file in moved {
            switch file.status {
            case .untracked: file.status = .added
            case .conflicted: file.status = .modified
            default: break
            }
            if let checkout = file.submodule?.checkout {
                // A submodule's uncommitted files stay behind under Unstaged,
                // since staging records only its commit (decision 75).
                if checkout.hasFilesInside, file.newMode == DiffFile.submoduleMode {
                    var left = file
                    left.submodule = SubmoduleChange(
                        checkout: checkout.subtracting(.commitChanged), distance: .counted(ahead: 0, behind: 0), filesInside: file.submodule?.filesInside
                    )
                    changes.unstaged.append(left)
                }
                // Under Staged, both of its commits are recorded ones.
                file.submodule?.checkout = nil
                file.submodule?.filesInside = nil
            }
            Self.add(file, to: &changes.staged)
        }
        changes.staged.sort { $0.path < $1.path }
        changes.unstaged.sort { $0.path < $1.path }
        return changes
    }

    /// How the lists will look once git has taken these files back out of the
    /// index, until git says for itself.
    func unstaging(_ moved: [DiffFile]) -> WorktreeChanges {
        var changes = self
        let paths = Set(moved.map(\.path))
        changes.staged.removeAll { paths.contains($0.path) }
        for var file in moved {
            switch file.status {
            case .added, .copied:
                file.status = .untracked
                file.oldPath = nil
                changes.untracked.append(file)
            case .renamed:
                // The new path isn't tracked, and the old one is gone from the disk.
                var old = file
                old.status = .deleted
                old.path = file.oldPath ?? file.path
                old.oldPath = nil
                Self.add(old, to: &changes.unstaged)
                file.status = .untracked
                file.oldPath = nil
                changes.untracked.append(file)
            default:
                // A submodule's row under Unstaged compares what's recorded
                // with its checkout, which is on the commit that was staged.
                if file.submodule != nil, file.newMode == DiffFile.submoduleMode { file.submodule?.checkout = [.commitChanged] }
                Self.add(file, to: &changes.unstaged)
            }
        }
        changes.unstaged.sort { $0.path < $1.path }
        changes.untracked.sort { $0.path < $1.path }
        return changes
    }

    /// How the lists will look once these files have gone. One that's staged too is
    /// still uncommitted, so it still counts.
    func discarding(_ files: [DiffFile]) -> WorktreeChanges {
        var changes = self
        let paths = Set(files.map(\.path))
        changes.unstaged.removeAll { paths.contains($0.path) }
        changes.untracked.removeAll { paths.contains($0.path) }
        changes.fileCount -= paths.subtracting(changes.staged.map(\.path)).count
        return changes
    }

    /// How the lists will look once everything Roga can discard has gone.
    func discardingEverything() -> WorktreeChanges {
        var changes = self
        changes.staged = []
        changes.unstaged = unstaged.filter { Group.unstaged.discarding($0) == nil }
        changes.untracked = untracked.filter { Group.untracked.discarding($0) == nil }
        changes.fileCount = changes.conflicted.count + changes.unstaged.count + changes.untracked.count
        return changes
    }

    /// Whether going back to `HEAD` would do anything, because a repository inside the
    /// worktree or a submodule can be all there is, and those stay.
    var hasSomethingToDiscard: Bool {
        !staged.isEmpty
            || unstaged.contains { Group.unstaged.discarding($0) != nil }
            || untracked.contains { Group.untracked.discarding($0) != nil }
    }

    /// Gives each submodule's row what was read about it when it was last
    /// listed, as long as the row is the same: its commits, and what status says
    /// about its checkout. A newer reading replaces it.
    mutating func keepSubmodules(readIn previous: WorktreeChanges) {
        for group in [Group.unstaged, .staged] {
            let read = previous[group].filter { $0.submodule?.distance != nil }
            guard !read.isEmpty else { continue }
            update(group) { files in
                for index in files.indices where files[index].isSubmodule {
                    let file = files[index]
                    guard let before = read.first(where: { $0.path == file.path }), before.isSameRow(as: file) else { continue }
                    files[index].submodule = before.submodule
                }
            }
        }
    }

    /// Adds what was read about some submodules to their rows in a group, for
    /// the rows that are still as they were listed.
    mutating func setSubmodules(_ read: [String: SubmoduleChange], in group: Group, asListed listed: [DiffFile]) {
        update(group) { files in
            for index in files.indices where files[index].isSubmodule {
                let file = files[index]
                guard let change = read[file.path], let before = listed.first(where: { $0.path == file.path }), before.isSameRow(as: file) else { continue }
                files[index].submodule = change
            }
        }
    }

    private mutating func update(_ group: Group, _ change: (inout [DiffFile]) -> Void) {
        switch group {
        case .conflicted: change(&conflicted)
        case .unstaged: change(&unstaged)
        case .untracked: change(&untracked)
        case .staged: change(&staged)
        }
    }
}

private extension DiffFile {
    /// Whether another listing's row is this one unchanged, as far as a list
    /// of files can tell: the same change between the same two objects, and for
    /// a submodule, the same said about its checkout.
    func isSameRow(as other: DiffFile) -> Bool {
        status == other.status && oldMode == other.oldMode && newMode == other.newMode && oldID == other.oldID && newID == other.newID
            && submodule?.checkout == other.submodule?.checkout
    }
}

extension WorktreeChanges {

    private static func add(_ file: DiffFile, to list: inout [DiffFile]) {
        guard let index = list.firstIndex(where: { $0.path == file.path }) else {
            list.append(file)
            return
        }
        if let lines = file.lines, let others = list[index].lines {
            list[index].lines = DiffFile.LineCounts(added: lines.added + others.added, removed: lines.removed + others.removed)
        }
    }
}
