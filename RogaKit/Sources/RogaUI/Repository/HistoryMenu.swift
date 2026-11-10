import AppKit
import GitCore
import HistoryUI
import MenuUI
import RepositoryEngine

/// What right-clicking a commit or a branch offers, in history and in the refs
/// panel (decision 65). The menu goes by what was clicked: a row with a branch on
/// it acts on that branch, as double-clicking does, a badge acts on its own ref,
/// and any other row acts on the commit.
///
/// This only decides the rows, so that they can be tested without a window.
enum HistoryMenu {
    /// What the menu acts on.
    struct Target {
        var commit: ObjectID
        /// What the heading calls the commit when no ref names it.
        var shortID: String
        /// The commit's subject, once it's been read.
        var subject: String?
        /// The full name of the branch or tag it acts on, or nil for only the commit.
        var ref: String?

        var refIsBranch: Bool {
            ref.map { $0.hasPrefix(Ref.branchPrefix) || $0.hasPrefix(Ref.remoteBranchPrefix) } ?? false
        }

        var refIsLocalBranch: Bool {
            ref?.hasPrefix(Ref.branchPrefix) ?? false
        }

        var refIsTag: Bool {
            ref?.hasPrefix(Ref.tagPrefix) ?? false
        }
    }

    /// What's true of the worktree when the menu opens.
    struct Situation {
        /// The full name of the branch checked out, or nil when `HEAD` is detached.
        var currentBranch: String?
        /// The commit `HEAD` is on, or nil when there's none yet.
        var head: ObjectID?
        /// Whether something that moves `HEAD` could start now: nothing's running
        /// and the worktree isn't partway through anything.
        var canChange = true
        /// Whether anything at all has to wait.
        var isBusy = false
        /// How the target's ref stands against `HEAD`, once that's been read.
        var relation: RefRelation?
        /// Whether `HEAD` already has the commit, when that's known.
        var headContains: Bool?
        /// Whether the target's ref is a remote's copy of the current branch, which
        /// has no local branch of its own to check out.
        var isRemoteCopyOfCurrentBranch = false
        /// What the main branch is called, when the target can be reviewed against it.
        var reviewBase: String?
        /// Where the current branch stands against its upstream, for its own row.
        var status: BranchStatus?
        /// The repository's remotes, which Set upstream chooses from.
        var remotes: [String] = []
        /// Where the target's tag would be pushed, when it's a tag and there's a
        /// remote to push it to.
        var tagRemote: String?
    }

    /// What the rows do. Each is about the target the menu was made for, because
    /// history can load again while the menu is open, and the rows move.
    struct Actions {
        var checkOut: () -> Void = {}
        /// Goes to the worktree that has the branch, in place of checking it out, when
        /// that's known ahead of time.
        var showOtherWorktree: (() -> Void)?
        var checkOutCommit: () -> Void = {}
        var integrate: (BranchIntegration.Way) -> Void = { _ in }
        var cherryPick: () -> Void = {}
        var reset: () -> Void = {}
        var revert: () -> Void = {}
        var newBranch: () -> Void = {}
        var newWorktree: () -> Void = {}
        var newTag: () -> Void = {}
        var pull: () -> Void = {}
        var push: () -> Void = {}
        var fetch: () -> Void = {}
        /// Pushes the target's branch, when it can be pushed from here.
        var pushBranch: (() -> Void)?
        /// Fast-forwards the target's branch to its upstream.
        var fastForwardBranch: () -> Void = {}
        /// Pushes the target's tag to `Situation.tagRemote`.
        var pushTag: () -> Void = {}
        /// Makes the target's branch push to and pull from a remote, by its name.
        var setUpstream: (String) -> Void = { _ in }
        var copy: (String) -> Void = { _ in }
        var review: () -> Void = {}
        var replay: (() -> Void)?
        var delete: Delete?
    }

    /// The row that deletes what the menu acts on, which history and the refs panel
    /// word differently.
    struct Delete {
        var title: String
        var isEnabled: Bool
        var action: () -> Void
    }

    /// The rows for right-clicking a commit or a branch, in groups with a line
    /// between them.
    static func entries(for target: Target, in situation: Situation, actions: Actions) -> [RefMenu.Entry] {
        let name = target.ref.map(Ref.shortName)
        let isCurrentBranch = target.ref != nil && target.ref == situation.currentBranch
        let sections: [[RefMenu.Entry]] = [
            isCurrentBranch ? currentBranchRows(target, situation, actions) : goingAndBringingIn(target, name, situation, actions),
            isCurrentBranch ? [] : resettingAndReverting(target, situation, actions),
            moreRows(target, name, situation, actions),
            actions.delete.map { [.command(RefMenu.Title($0.title), isDestructive: true, isEnabled: $0.isEnabled, action: $0.action)] } ?? [],
        ]
        let heading: RefMenu.Title = target.refIsBranch ? .branch(name ?? target.shortID) : RefMenu.Title(name ?? target.shortID)
        var entries: [RefMenu.Entry] = [.header(heading)]
        for (index, section) in sections.filter({ !$0.isEmpty }).enumerated() {
            if index > 0 { entries.append(.divider) }
            entries += section
        }
        return entries
    }

    /// What the rows call where `HEAD` is, which only has the branch icon on a branch.
    private static func headName(_ situation: Situation) -> RefMenu.Title {
        situation.currentBranch.map { .branch(Ref.shortName($0)) } ?? "HEAD"
    }

    /// Which remote the branch pushes to and pulls from, for a repository that
    /// has more than one to choose from.
    private static func upstreamRow(_ target: Target, _ situation: Situation, _ actions: Actions) -> RefMenu.Entry? {
        guard target.refIsLocalBranch, situation.remotes.count > 1, let relation = situation.relation else { return nil }
        let chosen = relation.remote.flatMap { situation.remotes.contains($0) ? $0 : nil }
        return .submenu("Set upstream", value: chosen ?? "None", isEnabled: !situation.isBusy, entries: situation.remotes.map { remote in
            .option(RefMenu.Title(remote), isChecked: remote == chosen) { actions.setUpstream(remote) }
        })
    }

    /// Pull, Push and Fetch, as the title row's menu has them.
    private static func currentBranchRows(_ target: Target, _ situation: Situation, _ actions: Actions) -> [RefMenu.Entry] {
        guard let status = situation.status else { return [] }
        let asks = status.pull == nil && status.hasDiverged
        return [
            .command(asks ? "Pull…" : "Pull", isEnabled: !situation.isBusy && (status.pull != nil || asks), action: actions.pull),
            .command("Push", isEnabled: !situation.isBusy && status.push != nil, action: actions.push),
            .command("Fetch", isEnabled: !situation.isBusy && status.remote != nil, action: actions.fetch),
        ] + [upstreamRow(target, situation, actions)].compactMap(\.self)
    }

    /// Going to what was clicked, and bringing it into the current branch.
    private static func goingAndBringingIn(_ target: Target, _ name: String?, _ situation: Situation, _ actions: Actions) -> [RefMenu.Entry] {
        var rows: [RefMenu.Entry] = []
        let head = headName(situation)
        if target.refIsBranch, let name {
            if let show = actions.showOtherWorktree {
                rows.append(.command("Show worktree", action: show))
            } else if !situation.isRemoteCopyOfCurrentBranch {
                rows.append(.command("Check out", isEnabled: situation.canChange, action: actions.checkOut))
            }
            if situation.head != nil { rows += bringingInBranch(name, head, situation, actions) }
        } else if target.commit != situation.head {
            rows.append(.command("Check out this commit", isEnabled: situation.canChange, action: actions.checkOutCommit))
        }
        if situation.head != nil, target.commit != situation.head, situation.headContains != true {
            rows.append(.command("Cherry-pick into \(head)", isEnabled: situation.canChange, action: actions.cherryPick))
        }
        return rows
    }

    /// Fast-forward when that's all it takes, nothing when `HEAD` has it all, and
    /// otherwise the two ways of combining them. Until the relation has been read,
    /// the dialogs say what's what.
    private static func bringingInBranch(_ name: String, _ head: RefMenu.Title, _ situation: Situation, _ actions: Actions) -> [RefMenu.Entry] {
        let isEnabled = situation.canChange
        if let relation = situation.relation {
            if relation.ahead == 0 { return [] }
            if relation.behind == 0 {
                return [.command("Fast-forward \(head) to \(branch: name)", isEnabled: isEnabled) { actions.integrate(.fastForward) }]
            }
        }
        return [
            .command("Merge \(branch: name) into \(head)…", isEnabled: isEnabled) { actions.integrate(.merge) },
            .command("Rebase \(head) onto \(branch: name)…", isEnabled: isEnabled) { actions.integrate(.rebase) },
        ]
    }

    private static func resettingAndReverting(_ target: Target, _ situation: Situation, _ actions: Actions) -> [RefMenu.Entry] {
        var rows: [RefMenu.Entry] = []
        if let current = situation.currentBranch, target.commit != situation.head {
            rows.append(.command("Reset \(branch: Ref.shortName(current)) to here…", isEnabled: situation.canChange, action: actions.reset))
        }
        rows.append(.command("Revert…", isEnabled: situation.canChange, action: actions.revert))
        return rows
    }

    private static func moreRows(_ target: Target, _ name: String?, _ situation: Situation, _ actions: Actions) -> [RefMenu.Entry] {
        var rows: [RefMenu.Entry] = [
            .submenu("Create", isEnabled: !situation.isBusy, entries: [
                .command("Branch here…", action: actions.newBranch),
                .command("Worktree here…", action: actions.newWorktree),
                .command("Tag here…", action: actions.newTag),
            ]),
        ]
        let remote = remoteRows(target, name, situation, actions)
        if !remote.isEmpty { rows.append(.submenu("Remote", isEnabled: !situation.isBusy, entries: remote)) }
        if target.ref != situation.currentBranch, let upstream = upstreamRow(target, situation, actions) { rows.append(upstream) }
        rows.append(.submenu("Copy", entries: copyRows(target, name, actions)))
        if let reviewBase = situation.reviewBase {
            rows.append(.command("Review against \(branch: reviewBase)", action: actions.review))
        }
        if let replay = actions.replay {
            rows.append(.command("Replay history", action: replay))
        }
        return rows
    }

    /// For a local branch other than the current one, which the title row can't
    /// push or pull, and for a tag, which nothing else pushes.
    private static func remoteRows(_ target: Target, _ name: String?, _ situation: Situation, _ actions: Actions) -> [RefMenu.Entry] {
        if target.refIsTag, let remote = situation.tagRemote {
            return [.command("Push to \(remote)", action: actions.pushTag)]
        }
        guard target.refIsLocalBranch, target.ref != situation.currentBranch, let name else { return [] }
        var rows: [RefMenu.Entry] = []
        let upstream = situation.relation?.upstream
        if let push = actions.pushBranch {
            // git rejects a push from a branch that's behind.
            let isEnabled = upstream.map { $0.ahead > 0 && $0.behind == 0 } ?? true
            rows.append(.command("Push \(branch: name)", isEnabled: isEnabled, action: push))
        }
        if let upstream {
            rows.append(.command(
                "Fast-forward from \(branch: Ref.shortName(upstream.name))",
                isEnabled: upstream.behind > 0 && upstream.ahead == 0,
                action: actions.fastForwardBranch
            ))
        }
        return rows
    }

    private static func copyRows(_ target: Target, _ name: String?, _ actions: Actions) -> [RefMenu.Entry] {
        var rows: [RefMenu.Entry] = [.command("Hash") { actions.copy(target.commit.hex) }]
        if let subject = target.subject {
            rows.append(.command("Subject") { actions.copy(subject) })
        }
        if let name {
            rows.append(.command(target.refIsBranch ? "Branch name" : "Tag name") { actions.copy(name) })
        }
        return rows
    }
}

extension RepositoryModel {
    /// How far back to look for a commit from `HEAD` while a menu opens, which
    /// takes a few milliseconds at most.
    private static let headSearchLimit = 20_000

    /// What right-clicking a row in history offers.
    func menuEntries(
        forRow row: Int,
        badge: CommitRowContent.Badge?,
        pasteboard: NSPasteboard = .general,
        showWorktree: @escaping (String, ObjectID?) -> Void
    ) -> [RefMenu.Entry] {
        let content = rowContent(row)
        if content.isWorkingTree {
            return [
                .command("Discard all changes…", isDestructive: true, isEnabled: selectedChanges.canDiscardEverything()) { [selectedChanges] in
                    selectedChanges.askToDiscardEverything()
                },
            ]
        }
        guard let commit = commit(atRow: row) else { return [] }
        // A badge says which ref. Elsewhere on the row it's the current branch if
        // that's here, and then local branches, which come first.
        let current = content.badges.first { $0.kind == .currentBranch }?.refName
        let ref = badge?.refName ?? current ?? content.branches.first
        let target = HistoryMenu.Target(commit: commit, shortID: content.shortID, subject: content.subject, ref: ref)
        var actions = actions(for: target, pasteboard: pasteboard, showWorktree: showWorktree)
        // Every branch on a row has the same history.
        if let branch = content.branches.first {
            actions.replay = { [weak self] in self?.replayHistory(ofBranch: branch) }
        }
        if content.hasBranchThatCanGo {
            let branches = content.branches
            actions.delete = HistoryMenu.Delete(title: "Delete…", isEnabled: !branch.isBusy) { [weak self] in
                self?.askToDeleteBranches(branches)
            }
        }
        var situation = situation(for: target)
        situation.headContains = situation.relation.map { $0.ahead == 0 } ?? headContains(row: row)
        return HistoryMenu.entries(for: target, in: situation, actions: actions)
    }

    /// What right-clicking a branch or remote branch in the refs panel offers. Only
    /// the commit at its tip is known here, and whether `HEAD` has it comes from
    /// how the branch stands against `HEAD`.
    func menuEntries(
        forBranch name: String,
        tip: ObjectID,
        otherWorktree: String? = nil,
        review: (() -> Void)? = nil,
        delete: HistoryMenu.Delete,
        pasteboard: NSPasteboard = .general,
        showWorktree: @escaping (String, ObjectID?) -> Void
    ) -> [RefMenu.Entry] {
        let target = HistoryMenu.Target(commit: tip, shortID: String(tip.hex.prefix(8)), ref: name)
        var situation = situation(for: target)
        situation.headContains = situation.relation.map { $0.ahead == 0 }
        var actions = actions(for: target, pasteboard: pasteboard, showWorktree: showWorktree)
        if let otherWorktree { actions.showOtherWorktree = { showWorktree(otherWorktree, tip) } }
        if let review { actions.review = review }
        actions.replay = { [weak self] in self?.replayHistory(ofBranch: name) }
        actions.delete = delete
        return HistoryMenu.entries(for: target, in: situation, actions: actions)
    }

    /// What right-clicking a tag in the refs panel offers, which is what its badge
    /// in history offers.
    ///
    /// - Parameter looksForHead: Whether to find out if `HEAD` has the commit, which
    ///   walks back from `HEAD`. Without it, Cherry-pick is offered unless the
    ///   commit is `HEAD`'s, and its dialog says if `HEAD` has it.
    func menuEntries(
        forTag name: String,
        commit: ObjectID,
        looksForHead: Bool = true,
        pasteboard: NSPasteboard = .general,
        showWorktree: @escaping (String, ObjectID?) -> Void
    ) -> [RefMenu.Entry] {
        let target = HistoryMenu.Target(commit: commit, shortID: String(commit.hex.prefix(8)), ref: name)
        var situation = situation(for: target)
        situation.headContains = looksForHead ? headContains(commit: commit) : nil
        let actions = actions(for: target, pasteboard: pasteboard, showWorktree: showWorktree)
        return HistoryMenu.entries(for: target, in: situation, actions: actions)
    }

    private func situation(for target: HistoryMenu.Target) -> HistoryMenu.Situation {
        HistoryMenu.Situation(
            currentBranch: history?.refs.currentBranch,
            head: history?.refs.head,
            canChange: canChangeHistory,
            isBusy: branch.isBusy,
            relation: target.ref.flatMap(relation),
            isRemoteCopyOfCurrentBranch: target.ref.map(isRemoteCopyOfCurrentBranch) ?? false,
            reviewBase: target.refIsBranch ? target.ref.flatMap(reviewBase(for:))?.title : nil,
            status: branch.status,
            remotes: remoteNames,
            tagRemote: target.refIsTag ? branch.tagRemote : nil
        )
    }

    private func actions(
        for target: HistoryMenu.Target,
        pasteboard: NSPasteboard,
        showWorktree: @escaping (String, ObjectID?) -> Void
    ) -> HistoryMenu.Actions {
        let commit = target.commit
        let short = String(commit.hex.prefix(8))
        let label = target.ref.map(Ref.shortName) ?? short
        var actions = HistoryMenu.Actions()
        actions.checkOut = { [weak self] in
            guard let self, let ref = target.ref else { return }
            checkOut(ref: ref, showWorktree: showWorktree)
        }
        actions.checkOutCommit = { [weak self] in self?.checkOutDetached(commit: commit) }
        actions.integrate = { [weak self] way in
            guard let ref = target.ref else { return }
            self?.branch.askToIntegrate(way, ref: ref)
        }
        actions.cherryPick = { [weak self] in self?.askToCherryPick(commit: commit) }
        actions.reset = { [weak self] in self?.askToReset(to: commit, subject: target.subject) }
        actions.revert = { [weak self] in self?.askToRevert(commit: commit) }
        actions.newBranch = { [weak self] in self?.branch.startNewBranch(at: commit, named: label) }
        actions.newWorktree = { [weak self] in self?.branch.startNewBranch(at: commit, named: label, inNewWorktree: true) }
        actions.newTag = { [weak self] in self?.branch.startNewTag(at: commit, named: label) }
        actions.pull = { [weak self] in self?.branch.pull() }
        actions.push = { [weak self] in self?.branch.push() }
        actions.fetch = { [weak self] in self?.branch.fetch() }
        if let ref = target.ref, target.refIsLocalBranch, ref != history?.refs.currentBranch {
            let upstream = relation(of: ref)?.upstream
            let pushRemote = relation(of: ref)?.pushRemote
            if upstream?.remote != nil || (upstream == nil && (pushRemote ?? branch.status?.pushRemote) != nil) {
                actions.pushBranch = { [weak self] in self?.branch.push(branch: ref, upstream: upstream, pushRemote: pushRemote) }
            }
            if let upstream {
                actions.fastForwardBranch = { [weak self] in self?.branch.fastForward(branch: ref, toUpstream: upstream.name) }
            }
        }
        if let ref = target.ref, target.refIsTag, let remote = branch.tagRemote {
            actions.pushTag = { [weak self] in self?.branch.push(tag: Ref.shortName(ref), to: remote) }
        }
        actions.copy = { text in
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        if let ref = target.ref {
            actions.review = { [weak self] in self?.review(branch: ref) }
            actions.setUpstream = { [weak self] remote in self?.setUpstream(of: ref, to: remote) }
        }
        return actions
    }
}
