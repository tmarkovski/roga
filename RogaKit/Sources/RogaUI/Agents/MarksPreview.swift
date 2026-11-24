import AgentHooks
import Foundation
import SwiftUI

/// A piece of the sidebar where agents are at work in three of a repository's
/// worktrees, one working, one waiting for you and one finished, each with a
/// line out from its mark to what the mark means. Settings › Agents and
/// setup's Hooks screen show it to say what the sidebar's marks are
/// (decision 41).
///
/// The sidebar's own views draw it: `SidebarRow`, the group's label, the line
/// from a repository down to its worktrees, and the counts. So it looks like
/// the sidebar whatever changes there. A group's label above the three and two
/// repositories below them fade out, and the sidebar's panel fades with them,
/// so that it reads as a glimpse of the window rather than a list of its own.
///
/// It's a picture: nothing in it takes a click or shows a tooltip, and how
/// long each agent has been at it stands still, though the working ring turns
/// as it does in the sidebar.
///
/// Setup's Hooks screen lays the three worktrees out across instead, each in
/// a glimpse of the sidebar of its own with what its mark means under it, so
/// that the screen fits above setup's lane (decision 69).
struct MarksPreview: View {
    enum Layout {
        /// The worktrees one over another under their repository, with what
        /// each mark means beside it, as in Settings › Agents.
        case column
        /// The worktrees side by side, `acrossWidth` wide, each with what its
        /// mark means under it.
        case across
    }

    var layout = Layout.column

    /// A worktree in the picture, its agent, and what its mark means.
    struct Sample {
        var branch: String
        var files: Int
        var summary: AgentSummary
        var isSelected = false
        var isLast = false
        var title: String
        var meaning: String
    }

    /// The moment the picture stands at. Any would do, since its times are
    /// counted from it.
    static let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A worktree for each of the marks.
    static let samples = [
        Sample(
            branch: "agent/fix-login",
            files: 3,
            summary: AgentSummary(state: .working, since: date - 150, hosts: [.claude], sessions: 1, activity: "Editing LoginView.swift"),
            isSelected: true,
            title: "Working",
            meaning: "Agent active in this worktree."
        ),
        Sample(
            branch: "agent/payments",
            files: 1,
            summary: AgentSummary(state: .waiting(.permission), since: date - 75, hosts: [.codex], sessions: 1, activity: "git push"),
            title: "Waiting",
            meaning: "Approval or response required."
        ),
        Sample(
            branch: "agent/search-index",
            files: 7,
            summary: AgentSummary(state: .finished, since: date - 240, hosts: [.claude], sessions: 1),
            isLast: true,
            title: "Finished",
            meaning: "Session finished, changes not yet reviewed."
        ),
    ]

    /// How wide the sidebar is, with the room on either side of its rows: a
    /// little narrower than it opens, so that what the marks mean fits
    /// beside it in setup's column.
    static let width: CGFloat = 280
    /// The room on either side of the sidebar's rows.
    static let inset: CGFloat = 8
    /// How far the panel fades in at the top, which covers the group's label,
    /// and out at the bottom, which covers the last repository and some of
    /// the one before it. The three worktrees stay whole.
    static let fadeTop: CGFloat = 34
    static let fadeBottom: CGFloat = 52
    /// How far back into the sidebar the line out to a meaning starts, which
    /// is just past the mark's right edge, 17 points in from the panel's.
    static let leaderOverlap: CGFloat = 14
    /// The sidebar's panel, a shade darker than the page it's on, as the
    /// window's sidebar is beside its panels.
    static let panelColor = Palette.gray(light: 0.937, dark: 0.137)
    /// How wide the picture is across: wider than setup's column, so that
    /// each worktree's line has room for Approval required: git push and how
    /// long it's been waiting.
    static let acrossWidth: CGFloat = 800
    /// The room between the worktrees across.
    static let acrossGap: CGFloat = 16

    var body: some View {
        Group {
            switch layout {
            case .column: column
            case .across: across
            }
        }
        .environment(\.sidebarPictureDate, Self.date)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        // One picture to VoiceOver, since what's in it is made up.
        .accessibilityLabel("Worktree status indicators. Ring: working. Amber circle: waiting for approval or a response. Blue dot: finished, unread.")
        .accessibilityAddTraits(.isImage)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 2) {
            line {
                GroupLabel(title: "acme", isCollapsed: false, agents: nil) {}
            }
            line {
                repositoryRow("api", files: 2, isExpanded: true)
            }
            ForEach(Self.samples, id: \.branch) { sample in
                line {
                    worktreeRow(sample)
                } callout: {
                    callout(sample)
                }
            }
            line {
                repositoryRow("web", isExpanded: false)
            }
            line {
                repositoryRow("website")
            }
        }
        .background(alignment: .leading) {
            panel(width: Self.width)
        }
        .mask {
            fade(top: Self.fadeTop, bottom: Self.fadeBottom)
        }
    }

    /// The three side by side, each a worktree's row on a piece of the
    /// sidebar's panel that fades out above and below it, with what its mark
    /// means centered under it.
    private var across: some View {
        let each = (Self.acrossWidth - 2 * Self.acrossGap) / 3
        return HStack(alignment: .top, spacing: Self.acrossGap) {
            ForEach(Self.samples, id: \.branch) { sample in
                VStack(spacing: 8) {
                    worktreeRow(sample, connected: false)
                        .padding(.horizontal, Self.inset)
                        .padding(.vertical, 10)
                        .background { panel(width: each) }
                        .mask { fade(top: 10, bottom: 10) }
                    VStack(spacing: 4) {
                        Text(sample.title)
                            .fontWeight(.semibold)
                        Text(sample.meaning)
                            .font(.system(size: 12.5))
                            .foregroundStyle(SettingsColors.note)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 6)
                }
                .frame(width: each)
            }
        }
        .frame(width: Self.acrossWidth)
    }

    /// A row of the sidebar, as wide as the sidebar's rows are, with what its
    /// mark means beside it.
    private func line<Row: View, Callout: View>(@ViewBuilder _ row: () -> Row, @ViewBuilder callout: () -> Callout) -> some View {
        HStack(alignment: .top, spacing: 0) {
            row()
                .padding(.horizontal, Self.inset)
                .frame(width: Self.width)
            callout()
                .padding(.leading, -Self.leaderOverlap)
        }
    }

    private func line<Row: View>(@ViewBuilder _ row: () -> Row) -> some View {
        line(row) { EmptyView() }
    }

    /// A repository's row, as the sidebar draws one: its name, the chevron
    /// when it has linked worktrees, and how many files are uncommitted.
    private func repositoryRow(_ name: String, files: Int = 0, isExpanded: Bool? = nil) -> some View {
        SidebarRow(agent: nil, action: {}) {
            HStack(spacing: 3) {
                FadingText(name)
                    .font(.system(size: 13))
                    .layoutPriority(1)
                if let isExpanded {
                    // The sidebar's chevron is a button this size.
                    Chevron(pointsDown: isExpanded)
                        .frame(width: 18, height: 18)
                }
            }
        } trailing: {
            if files > 0 {
                UncommittedCount(count: files, hasConflicts: false)
            }
        } commands: {
            EmptyView()
        }
    }

    /// A linked worktree's row, under its repository with a line to it, or
    /// on its own when the picture is across.
    private func worktreeRow(_ sample: Sample, connected: Bool = true) -> some View {
        let indent = connected ? WorktreeConnector.textIndent : 0
        return SidebarRow(isSelected: sample.isSelected, agent: sample.summary, lineIndent: indent, action: {}) {
            FadingText(sample.branch)
                .font(.system(size: 13))
                .padding(.leading, indent)
        } trailing: {
            UncommittedCount(count: sample.files, hasConflicts: false)
        } commands: {
            EmptyView()
        }
        .overlay {
            if connected { WorktreeConnector(isLast: sample.isLast) }
        }
    }

    /// A line from the mark, whose middle is 16 points down its row, out to
    /// what the mark means.
    private func callout(_ sample: Sample) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(SettingsColors.note.opacity(0.45))
                .frame(width: 30, height: 1)
                .padding(.top, 15)
            VStack(alignment: .leading, spacing: 0) {
                Text(sample.title)
                    .fontWeight(.semibold)
                    .frame(height: 20)
                Text(sample.meaning)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsColors.note)
            }
            .padding(.top, 6)
        }
        .font(.system(size: 13))
        .fixedSize()
    }

    /// The sidebar's panel behind the rows, with a hairline down each side,
    /// where the sidebar meets the page around it.
    private func panel(width: CGFloat) -> some View {
        Rectangle()
            .fill(Self.panelColor)
            .overlay {
                Rectangle()
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .frame(width: width)
    }

    /// Clear at the top and bottom and solid between, so that the rows and
    /// the panel fade out together. The edges of the panel's hairline at the
    /// top and bottom are where it's clear, so they never show.
    private func fade(top: CGFloat, bottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: top)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: bottom)
        }
    }
}

#Preview("Marks") {
    MarksPreview()
        .padding(30)
        .frame(width: 640)
        .background(SettingsColors.surface)
}

#Preview("Marks across") {
    MarksPreview(layout: .across)
        .padding(30)
        .background(SettingsColors.surface)
}
