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
/// Setup's Hooks screen shows only the repository and its three worktrees,
/// without the lines out to what the marks mean, beside the agents, so that
/// the screen fits above setup's lane (decision 69).
struct MarksPreview: View {
    enum Layout {
        /// The worktrees one over another under their repository, between a
        /// group's label and two more repositories, with what each mark means
        /// beside it, as in Settings › Agents.
        case column
        /// Just the repository and its three worktrees, `width` wide, as on
        /// setup's Hooks screen. Each worktree's second line says what its
        /// agent is doing, which says what its mark means.
        case glimpse
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
    /// How far the glimpse's panel fades in at the top and out at the
    /// bottom, which only touches the room around its rows.
    static let glimpseFade: CGFloat = 12

    var body: some View {
        Group {
            switch layout {
            case .column: column
            case .glimpse: glimpse
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

    /// The repository and its three worktrees on the sidebar's panel, which
    /// fades in just above the repository and out just under the last one.
    private var glimpse: some View {
        VStack(alignment: .leading, spacing: 2) {
            repositoryRow("api", files: 2, isExpanded: true)
            ForEach(Self.samples, id: \.branch) { sample in
                worktreeRow(sample)
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(width: Self.width)
        .background { panel(width: Self.width) }
        .mask { fade(top: Self.glimpseFade, bottom: Self.glimpseFade) }
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

    /// A linked worktree's row, under its repository with a line to it.
    private func worktreeRow(_ sample: Sample) -> some View {
        let indent = WorktreeConnector.textIndent
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
            WorktreeConnector(isLast: sample.isLast)
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

#Preview("Marks glimpse") {
    MarksPreview(layout: .glimpse)
        .padding(30)
        .background(SettingsColors.surface)
}
