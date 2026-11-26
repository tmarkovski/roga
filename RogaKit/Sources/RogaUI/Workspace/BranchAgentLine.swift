import AgentHooks
import AppKit
import IconUI
import SwiftUI

/// What the agent in the worktree on screen is doing, after the counts in the
/// branch row (decision 100), as in `Run the test suite · 6 min`. It's the
/// sidebar's second line, in gray, with a light in Roga's orange running
/// through its words while an agent works. Otherwise a mark comes first, and
/// the words are in amber while an agent waits for you. When the row is short
/// of room, the words are cut at their end and the mark and how long stay.
///
/// It's a button: it fills with gray under the pointer, as the counts do,
/// and a click opens a popover with a section for each session. It redraws as
/// an agent reaches another minute, and with each new line.
struct BranchAgentLine: View {
    let line: AgentLine
    let monitor: AgentMonitor
    let model: RepositoryModel
    @State private var isHovering = false
    @State private var showsDetail = false

    /// The words' font, as AppKit has it, which the light draws them in again
    /// to light them up.
    private static let font = NSFont.systemFont(ofSize: 13)

    var body: some View {
        TimelineView(WholeMinutes(of: [line.summary])) { context in
            let parts = line.parts(now: context.date)
            let help = line.help(now: context.date)
            Button {
                showsDetail.toggle()
            } label: {
                HStack(spacing: 6) {
                    if let mark = line.mark {
                        AgentLineMark(mark: mark)
                    }
                    HStack(spacing: 0) {
                        Text(parts.words)
                            .truncationMode(.tail)
                            .overlay {
                                if line.shimmers {
                                    TextShimmer(text: parts.words, font: Self.font)
                                }
                            }
                        if let time = parts.time {
                            Text(" · \(time)")
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(line.isWaiting ? AnyShapeStyle(AgentColors.warn) : AnyShapeStyle(.secondary))
                }
                .font(.system(size: 13))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovering || showsDetail ? Palette.buttonHover : .clear)
                }
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
            }
            .buttonStyle(.plain)
            .opensOnPress($showsDetail)
            .help(help)
            .accessibilityLabel(help)
            .accessibilityHint("Shows what each agent in this worktree is doing")
            .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
                AgentLinePopover(line: line, monitor: monitor, model: model) {
                    showsDetail = false
                }
            }
        }
    }
}

/// The mark at the start of the agent's line and of each section of its
/// popover, in a 14-point box as in the sidebar.
struct AgentLineMark: View {
    let mark: AgentLine.Mark
    var size: CGFloat = 14

    var body: some View {
        switch mark {
        case .agent(let state):
            AgentMark(state: state, size: size)
        case .finished:
            circle(.circleCheck)
                .foregroundStyle(.secondary)
        case .failed:
            circle(.circleX)
                .foregroundStyle(Palette.red)
        }
    }

    private func circle(_ icon: Icon) -> some View {
        icon.image
            .font(AgentMark.circleFont(size: size))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// What a click on the agent's line opens: a section for each session in the
/// worktree, most urgent first, with its mark, its agent, what it's doing in
/// a word or two and for how long, then its whole line and how many subagents
/// it has running. At its foot, **Review 3 Files** selects history's row for
/// uncommitted changes, while there are any.
struct AgentLinePopover: View {
    let line: AgentLine
    let monitor: AgentMonitor
    let model: RepositoryModel
    let close: () -> Void

    static let width: CGFloat = 340
    /// How far a section's lines stand in from its mark, to line up with its
    /// agent's name.
    private static let indent: CGFloat = 21

    var body: some View {
        TimelineView(line.minutes) { context in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(line.agents.enumerated()), id: \.element.id) { index, agent in
                    if index > 0 { Divider() }
                    section(agent, now: context.date)
                }
                if model.uncommittedFiles > 0 {
                    Divider()
                    Button(review) {
                        model.selectRow(0)
                        close()
                    }
                    .buttonStyle(OutlinedButtonStyle(height: 28, isOutlined: false))
                    .padding(6)
                }
            }
            .frame(width: Self.width, alignment: .leading)
        }
    }

    private var review: String {
        let files = model.uncommittedFiles
        return files == 1 ? "Review 1 File" : "Review \(files.formatted()) Files"
    }

    private func section(_ agent: WorktreeAgent, now: Date) -> some View {
        let isWaiting = agent.phase.isWaitingForYou
        let subagents = monitor.subagents(of: agent.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                AgentLineMark(mark: AgentLine.mark(of: agent.phase))
                Text(agent.host.name)
                    .fontWeight(.semibold)
                    .fixedSize()
                Text(AgentLine.state(of: agent.phase))
                    .foregroundStyle(isWaiting ? AnyShapeStyle(AgentColors.warn) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let time = AgentLine.time(of: agent, now: now) {
                    Text(time)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .frame(height: 18)
            if let detail = AgentLine.detail(of: agent) {
                Text(detail)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.indent)
            }
            if subagents > 0 {
                Text(subagents == 1 ? "1 subagent running" : "\(subagents.formatted()) subagents running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, Self.indent)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

private extension AgentPhase {
    var isWaitingForYou: Bool {
        if case .waiting = self { true } else { false }
    }
}
