import GitCore
import SwiftUI

/// The row under the tabs, at the top of the middle column, which says where the
/// worktree's branch stands and acts on it (decision 95). It holds what the
/// title row held before the tabs took that row: the branch's chip with its
/// counts, which pull and push (decision 19), then at the right end Fetch and
/// New Branch, a thin line, and history's number of commits and commands. It's
/// as tall as a panel's header and lines up with the refs panel's. Before Fetch
/// are the initials of who the worktree's commits go out as (decision 103).
///
/// After the counts, it says what the worktree's agent is doing (decision 100),
/// except while Roga says what it's doing or just did, whose words come first.
///
/// When the row is short of room, the agent's words are cut short first, then
/// the number of commits goes, then the branch's name is cut short. The counts,
/// Fetch and New Branch stay. In a narrow column, the number of commits goes as
/// soon as an agent has something to say.
struct BranchBar: View {
    let model: RepositoryModel
    let worktree: Worktree
    let monitor: AgentMonitor
    let list: RepositoryList
    /// Goes to the refs panel's filter, or nil when the refs panel doesn't fit.
    let switchBranch: (() -> Void)?
    /// Shows one of the repository's worktrees in the window.
    let showWorktree: (String, ObjectID?) -> Void
    /// Whether the row shows what agents are doing. It follows the sidebar's
    /// marks, so that turning agents off hides it too.
    var marks = AgentMarksSetting()
    /// The repository the window shows, whose identity goes before Fetch.
    @Environment(ListedRepository.self) private var repository: ListedRepository?
    @State private var width: CGFloat = 0

    /// The space between the branch's buttons and the line after them, and
    /// after the line, so that it has about 14 points on each side between New
    /// Branch's icon and the number of commits.
    private static let lineGap = 6.0
    /// How tall the line after the branch's buttons is, about as tall as their
    /// icons.
    private static let lineHeight = 18.0
    /// How wide the row can be and still have room for the agent's words
    /// beside history's number of commits. Under it, the number goes while an
    /// agent has something to say.
    static let widthForCommitCount: CGFloat = 600

    var body: some View {
        let line = agentLine
        let showsLine = line != nil && !rogaIsSpeaking
        HStack(spacing: 0) {
            if worktree.isBare {
                Text(worktree.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 5)
            } else {
                BranchControl(branch: model.branch, worktree: worktree, switchBranch: switchBranch, showWorktree: showWorktree)
                    .layoutPriority(1)
            }
            if showsLine, let line {
                BranchAgentLine(line: line, monitor: monitor, model: model)
                    .padding(.leading, 6)
                    // Its words are the first to be cut short, and the space
                    // after them takes what's left.
                    .layoutPriority(-1)
                    .transition(.opacity)
            }
            Spacer(minLength: 12)
                .layoutPriority(-2)
            HStack(spacing: Self.lineGap) {
                if model.phase.isReady {
                    CheckoutNote(model: model)
                        .padding(.trailing, 6)
                }
                if !worktree.isBare {
                    // Before Fetch, so that it's as far from the counts as
                    // the row allows (decision 103).
                    HStack(spacing: 2) {
                        if let repository {
                            IdentityButton(repository: repository, list: list)
                        }
                        BranchButtons(branch: model.branch, worktree: worktree, showWorktree: showWorktree)
                    }
                    .animation(.easeOut(duration: 0.2), value: repository?.identity == nil)
                }
                // A line between them and history's commands, which they don't
                // act on, once history has loaded and they show.
                if model.phase.isReady {
                    if !worktree.isBare {
                        Rectangle()
                            .fill(Palette.separator)
                            .frame(width: 1, height: Self.lineHeight)
                            .padding(.horizontal, Self.lineGap)
                            .accessibilityHidden(true)
                    }
                    HistoryCommands(model: model, showsCommitCount: line == nil || width >= Self.widthForCommitCount)
                }
            }
        }
        .lineLimit(1)
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(height: PanelSplitLayout.headerHeight)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: showsLine)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // History's row for uncommitted changes shimmers while an agent works.
        .onChange(of: line?.isWorking == true, initial: true) { _, isWorking in
            model.agentIsWorking = isWorking
        }
        .background(Palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
        }
    }

    /// What the agents in this worktree are doing, or nil when none is
    /// working, waiting or finished, or agents are turned off.
    private var agentLine: AgentLine? {
        guard !worktree.isBare, let monitor = marks.monitor(monitor) else { return nil }
        return AgentLine(monitor.worktreeAgents(worktree.path, in: list))
    }

    /// Whether Roga says what git is doing or just did after the counts, as in
    /// `Committed 9f2c1ab` with Undo, or beside the house while it pulls or
    /// pushes. A fetch says nothing there.
    private var rogaIsSpeaking: Bool {
        let branch = model.branch
        if let action = branch.action, action != .fetching { return true }
        return branch.finished != nil
    }
}
