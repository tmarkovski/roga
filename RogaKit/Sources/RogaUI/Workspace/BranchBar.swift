import GitCore
import SwiftUI

/// The row under the tabs, at the top of the middle column, which says where the
/// worktree's branch stands and acts on it (decision 95). It holds what the
/// title row held before the tabs took that row: the branch, over how far it is
/// from the main branch on the remote (decision 120), with its counts, which
/// pull and push (decision 19), then at the right end Fetch and New Branch, a
/// thin line, and the order of history. It's as tall as a panel's header and
/// lines up with the refs panel's. Who the commits go out as isn't here, since
/// it's the whole repository's, and the title row has it (decision 105).
///
/// After the counts, it says what the worktree's agent is doing, in two lines
/// (decisions 100 and 119), except while Roga says what it's doing or just did,
/// whose words come first.
///
/// Every control in it is 36 points tall, as its two-line blocks need, so that
/// the gray that fills one under the pointer is the same height from one end of
/// the row to the other. When the row is short of room, the agent's words are
/// cut short first, and its first line gives way to its name, which stays
/// whole, then the line under the branch's name is cut short, and then the
/// name. The counts, Fetch and New Branch stay.
struct BranchBar: View {
    let model: RepositoryModel
    let worktree: Worktree
    let monitor: AgentMonitor
    let list: RepositoryList
    /// The repository's name, for the branch's popover.
    let repositoryName: String
    /// Goes to the refs panel's filter, or nil when the refs panel doesn't fit.
    let switchBranch: (() -> Void)?
    /// Takes the worktree's lock off, from the branch's popover.
    let unlock: () -> Void
    /// Shows one of the repository's worktrees in the window.
    let showWorktree: (String, ObjectID?) -> Void
    /// Whether the row shows what agents are doing. It follows the sidebar's
    /// marks, so that turning agents off hides it too.
    var marks = AgentMarksSetting()

    /// The space between the branch's buttons and the line after them, and
    /// after the line, so that it has about 14 points on each side between New
    /// Branch's icon and the number of commits.
    private static let lineGap = 6.0
    /// How tall the line after the branch's buttons is, about as tall as their
    /// icons.
    private static let lineHeight = 18.0
    /// How tall every control in the row is, which leaves 4 points above and
    /// below each in the row's 44.
    static let controlHeight: CGFloat = 36

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
                BranchControl(branch: model.branch, worktree: worktree, repositoryName: repositoryName, switchBranch: switchBranch, unlock: unlock)
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
                    BranchButtons(branch: model.branch, worktree: worktree, showWorktree: showWorktree)
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
                    HistoryCommands(model: model, controlHeight: Self.controlHeight)
                }
            }
        }
        .lineLimit(1)
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(height: PanelSplitLayout.headerHeight)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: showsLine)
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
