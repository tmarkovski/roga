import GitCore
import SwiftUI

/// The row under the tabs, at the top of the middle column, which says where the
/// worktree's branch stands and acts on it (decision 95). It holds what the
/// title row held before the tabs took that row: the branch's chip with its
/// counts, which pull and push (decision 19), then at the right end Fetch and
/// New Branch, a thin line, and history's number of commits and commands. It's
/// as tall as a panel's header and lines up with the refs panel's.
///
/// When the row is short of room, the number of commits goes first, then the
/// branch's name is cut short. The counts, Fetch and New Branch stay.
struct BranchBar: View {
    let model: RepositoryModel
    let worktree: Worktree
    /// Goes to the refs panel's filter, or nil when the refs panel doesn't fit.
    let switchBranch: (() -> Void)?
    /// Shows one of the repository's worktrees in the window.
    let showWorktree: (String, ObjectID?) -> Void

    /// The space between the branch's buttons and the line after them, and
    /// after the line, so that it has about 14 points on each side between New
    /// Branch's icon and the number of commits.
    private static let lineGap = 6.0
    /// How tall the line after the branch's buttons is, about as tall as their
    /// icons.
    private static let lineHeight = 18.0

    var body: some View {
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
            Spacer(minLength: 12)
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
                    HistoryCommands(model: model)
                }
            }
        }
        .lineLimit(1)
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(height: PanelSplitLayout.headerHeight)
        .frame(maxWidth: .infinity)
        .background(Palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
        }
    }
}
