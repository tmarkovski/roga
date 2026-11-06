import AppKit
import GitCore
import HistoryUI
import IconUI
import MenuUI
import SwiftUI

/// The repository's name in the title row, which opens the menu of its
/// worktrees. Its icon says whether the window shows the main worktree or a
/// linked one, which nothing else in the title row does.
struct RepositoryChip: View {
    let name: String
    let isMain: Bool
    let entries: [RefMenu.Entry]
    @State private var isHovering = false
    @State private var opener = RefMenuOpener()

    var body: some View {
        HStack(spacing: 5) {
            (isMain ? Icon.repository : Icon.worktree).image
                .foregroundStyle(.secondary)
            Text(name)
                .fontWeight(.medium)
            Icon.dropdown.image
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovering ? Palette.hover : .clear)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .overlay { RefMenuArea(entries: entries, opensOnClick: true, opener: opener) }
        .help(description)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Repository \(name)")
        .accessibilityValue(isMain ? "Main worktree" : "Linked worktree")
        .accessibilityAddTraits(.isButton)
        // Pressing it opens the menu, as a click does, and each worktree and
        // command is an action of its own too.
        .accessibilityAction { opener.open() }
        .accessibilityActions { refMenuActions(entries) }
    }

    private var description: String {
        isMain ? "The main worktree of \(name)" : "A linked worktree of \(name)"
    }
}

/// The chip for the worktree a window shows, with the menu of its repository's
/// worktrees.
///
/// It works the menu out in its own body, which reads what agents are doing,
/// so that a mark changing redraws the chip rather than the whole window.
/// While an agent works or waits in one of the worktrees, it also redraws as
/// that agent reaches another minute, so that the menu says for how long.
struct WorktreeChip: View {
    let repository: ListedRepository
    let worktree: Worktree
    /// The model of the worktree on screen, once its repository is open.
    let model: RepositoryModel?
    let actions: WorktreeMenu.Actions
    let monitor: AgentMonitor
    let list: RepositoryList
    /// Whether the menu says what agents are doing. It follows the sidebar's
    /// marks, so that turning them off hides agents here too.
    var marks = AgentMarksSetting()

    var body: some View {
        let facts = facts
        TimelineView(WholeMinutes(of: facts.map(\.agent))) { context in
            RepositoryChip(
                name: repository.name,
                isMain: worktree.isMain,
                entries: WorktreeMenu.entries(for: facts, shown: worktree.path, now: context.date, actions: actions)
            )
        }
    }

    /// What the menu says about each of the repository's worktrees.
    var facts: [WorktreeFacts] {
        WorktreeMenu.facts(of: repository, shown: worktree.path, model: model, agents: marks.monitor(monitor), in: list)
    }
}

/// What the menu of a repository's worktrees says about one of them.
struct WorktreeFacts: Equatable {
    var worktree: Worktree
    var uncommittedFiles = 0
    var hasConflicts = false
    var unfinished: UnfinishedWork?
    var upstream: UpstreamCounts?
    var isDeleting = false
    /// What agents are doing in it, as its mark in the sidebar shows.
    var agent: AgentSummary?
}

/// The menu that the repository's name in the title row opens. It lists each of
/// the repository's worktrees on two lines, the main worktree first, with
/// commands for the one the window shows after them.
enum WorktreeMenu {
    struct Actions {
        /// Shows the worktree in this folder in the window.
        var show: (String) -> Void
        /// Starts a new branch in a new worktree, or nil when that can't
        /// start yet.
        var newWorktree: (() -> Void)?
        var reveal: (String) -> Void
        var openInTerminal: (String) -> Void
    }

    /// - Parameter now: The time to say how long agents have been at it from.
    static func entries(for facts: [WorktreeFacts], shown: String, now: Date = .now, actions: Actions) -> [RefMenu.Entry] {
        var entries: [RefMenu.Entry] = facts.filter { !$0.worktree.isBare }.map { facts in
            .choice(choice(for: facts, isCurrent: facts.worktree.path == shown, now: now) { actions.show(facts.worktree.path) })
        }
        entries.append(.divider)
        entries.append(.command("New Worktree…", isEnabled: actions.newWorktree != nil) { actions.newWorktree?() })
        entries.append(.command("Show in Finder") { actions.reveal(shown) })
        entries.append(.command("Open in Terminal") { actions.openInTerminal(shown) })
        return entries
    }

    /// A worktree's row, named for its branch as the sidebar names it.
    static func choice(for facts: WorktreeFacts, isCurrent: Bool, now: Date = .now, action: @escaping () -> Void) -> RefMenu.Choice {
        let worktree = facts.worktree
        return RefMenu.Choice(
            title: worktree.title,
            icon: (worktree.isMain ? Icon.repository : Icon.worktree).nsImage,
            details: details(for: facts, now: now),
            count: count(for: facts),
            isCurrent: isCurrent,
            isEnabled: !worktree.isPrunable && !facts.isDeleting,
            help: worktree.path,
            action: isCurrent ? {} : action
        )
    }

    /// The second line: what agents are doing there, as in "Agent working · 6
    /// min", in amber while one waits for you (decision 41), whether the
    /// worktree is going away or its folder is missing, what it's stuck partway
    /// through, how far its branch is from its upstream, whether it's locked,
    /// and last, its folder, which is the part to cut short.
    static func details(for facts: WorktreeFacts, now: Date = .now) -> [RefMenu.Detail] {
        let worktree = facts.worktree
        var details: [RefMenu.Detail] = []
        if let agent = facts.agent {
            let isWaiting = if case .waiting = agent.state { true } else { false }
            details.append(RefMenu.Detail(agent.menuDetail(now: now), color: isWaiting ? agentWaitingColor : nil))
        }
        if facts.isDeleting {
            details.append(RefMenu.Detail("Deleting…"))
        } else if worktree.isPrunable {
            details.append(RefMenu.Detail("Folder missing"))
        }
        if let unfinished = facts.unfinished {
            details.append(RefMenu.Detail(unfinished.title, color: unfinished.hasConflicts ? GitColors.red : nil))
        }
        if let upstream = facts.upstream {
            if upstream.isGone {
                details.append(RefMenu.Detail("Upstream gone"))
            } else if let counts = counts(upstream) {
                details.append(RefMenu.Detail(counts))
            }
        }
        if worktree.isLocked { details.append(RefMenu.Detail("Locked")) }
        details.append(RefMenu.Detail((worktree.path as NSString).abbreviatingWithTildeInPath))
        return details
    }

    /// As in `↓3 ↑2`, in the order the title row shows them, or nil when the
    /// branch is up to date.
    static func counts(_ upstream: UpstreamCounts) -> String? {
        let parts = [
            upstream.behind > 0 ? "↓" + upstream.behind.formatted() : nil,
            upstream.ahead > 0 ? "↑" + upstream.ahead.formatted() : nil,
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Its uncommitted files, in orange as in the sidebar, or in red with a
    /// triangle when some have conflicts.
    static func count(for facts: WorktreeFacts) -> RefMenu.Count? {
        guard facts.uncommittedFiles > 0 else { return nil }
        return facts.hasConflicts
            ? RefMenu.Count(facts.uncommittedFiles.formatted(), color: GitColors.red, icon: Icon.warning.nsImage)
            : RefMenu.Count(facts.uncommittedFiles.formatted(), color: .systemOrange)
    }

    /// The amber of the waiting mark, for the menu, which AppKit draws. Made
    /// from SwiftUI's color, it keeps both its light and its dark version.
    static let agentWaitingColor = NSColor(AgentColors.warn)

    /// What's known about each of a repository's worktrees. The one the window
    /// shows takes what its model last read, which is fresher than the
    /// sidebar's look.
    ///
    /// - Parameters:
    ///   - agents: What agents are doing in them, or nil while their marks are
    ///     turned off.
    ///   - list: The sidebar's list, in which the monitor finds the worktree
    ///     each agent is in.
    static func facts(of repository: ListedRepository, shown: String, model: RepositoryModel?, agents: AgentMonitor?, in list: RepositoryList) -> [WorktreeFacts] {
        repository.worktrees.map { worktree in
            var facts = WorktreeFacts(
                worktree: worktree,
                uncommittedFiles: repository.uncommittedFiles[worktree.path] ?? 0,
                hasConflicts: repository.conflictedWorktrees.contains(worktree.path),
                unfinished: repository.unfinishedWork[worktree.path],
                upstream: worktree.branch.flatMap { repository.upstreams[$0] },
                isDeleting: repository.deletingWorktrees.contains(worktree.path)
            )
            facts.agent = agents?.summary(forWorktree: worktree.path, in: list)
            if worktree.path == shown, let branch = model?.branch {
                facts.unfinished = branch.unfinished
                if let status = branch.status, status.branch == worktree.branch {
                    facts.upstream = status.upstream != nil || status.upstreamIsGone
                        ? UpstreamCounts(ahead: status.ahead, behind: status.behind, isGone: status.upstreamIsGone)
                        : nil
                }
            }
            return facts
        }
    }
}
