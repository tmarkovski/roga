import AgentHooks
import AppKit
import IconUI
import SwiftUI

/// What the agent in the worktree on screen is doing, after the counts in the
/// branch row (decision 100), in two lines (decision 120): who and what state
/// they're in, with how long, over what they're doing, as in `Claude Code is
/// working · 6 min` over `Run the test suite`. While an agent works, a light in
/// Roga's orange runs through the second line, since the worktree's tab plays
/// the windows at work a few points above. Otherwise the first line starts with a mark, and
/// it's amber while an agent waits for you and red when its turn ended with an
/// error. When the row is short of room, the second line is cut at its end, and
/// the first gives way to the agent's name alone.
///
/// It's a button, 36 points tall like everything else in the row: it fills
/// with gray under the pointer, as the counts do, and a click opens a popover
/// with a section for each session. It redraws as an agent reaches another
/// minute, and with each new line.
struct BranchAgentLine: View {
    let line: AgentLine
    let monitor: AgentMonitor
    let model: RepositoryModel
    @State private var isHovering = false
    @State private var showsDetail = false

    /// The second line's font, as AppKit has it, which the light draws the
    /// words in again to light them up.
    private static let wordsFont = NSFont.systemFont(ofSize: 11)

    var body: some View {
        TimelineView(WholeMinutes(of: [line.summary])) { context in
            let lines = line.lines(now: context.date)
            let help = line.help(now: context.date)
            Button {
                showsDetail.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 0) {
                        if let mark = line.mark {
                            AgentLineMark(mark: mark, size: 13)
                                .padding(.trailing, 6)
                        }
                        // The name alone stays whole, so that in a narrow
                        // column the line under the branch's name is cut
                        // short before it.
                        ViewThatFits(in: .horizontal) {
                            Text(lines.state)
                            Text(lines.short)
                                .fixedSize()
                        }
                        if let time = lines.time {
                            Text(" · \(time)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(tone)
                    if let words = lines.words {
                        Text(words)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .truncationMode(.tail)
                            .overlay {
                                if line.shimmers {
                                    TextShimmer(text: words, font: Self.wordsFont)
                                }
                            }
                    }
                }
                .lineLimit(1)
                .padding(.leading, 7)
                .padding(.trailing, 9)
                .frame(height: BranchBar.controlHeight)
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

    /// The first line's color: amber while an agent waits for you, red when a
    /// turn ended with an error, and the text's own otherwise.
    private var tone: AnyShapeStyle {
        if line.isWaiting { return AnyShapeStyle(AgentColors.warn) }
        if line.hasFailed { return AnyShapeStyle(Palette.red) }
        return AnyShapeStyle(.primary)
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
