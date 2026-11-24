import AgentEngine
import AppKit
import GitCore
import IconUI
import SwiftUI

/// The message of the next commit, under the worktree's files (decision 30). It's
/// one text box, with the first line in bold, the way the commit panel will show
/// it, and a row of buttons under the text, the way a chat box has them
/// (decision 98): Generate at the left, and Commit at the right, whose chevron
/// has Commit and Push and Amend. The line over it is the box's only edge, since
/// the panel's sides and bottom already close it in. It fills the fifth of the
/// panel it's given, and grows past that as it fills.
///
/// Whatever's running shows where it was started, with Stop in that button's
/// place. While an agent writes (decision 41), Generate turns into Stop and the
/// box waits with gray bars in place of its text, and while hooks or signing take
/// a while, Commit turns into Stop. Whatever's worth knowing about the commit,
/// such as an amend, a merge, a warning or a failure, shows at the top of the
/// box with its own fix beside it, so that the row of buttons stays put. So does
/// who the commit goes out as, while that's someone other than the global
/// identity or a commit would go wrong (decision 103).
struct CommitBox: View {
    @Bindable var composer: CommitComposer
    /// Gives the keyboard back to the list of files.
    let leave: () -> Void
    /// The room the text needs.
    @State private var textHeight = 0.0
    /// Whether the popover for choosing the agent is open.
    @State private var isChoosingAgent = false
    /// How wide the row of buttons is, which decides how much their words say.
    @State private var rowWidth = 0.0
    /// The agents, which every window has, though a view that's tested on its
    /// own may not.
    @Environment(AgentProvider.self) private var agents: AgentProvider?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    /// The repository and the list, for who the commit goes out as
    /// (decision 103), which a view that's tested on its own may not have.
    @Environment(ListedRepository.self) private var repository: ListedRepository?
    @Environment(RepositoryList.self) private var list: RepositoryList?
    @AppStorage(AgentPreferences.showsGenerateButtonKey) private var showsGenerateButton = true

    /// Three lines, and then about half of an ordinary window's panel.
    private static let shortest = 48.0
    private static let tallest = 240.0
    /// How much room the gray bars take while an agent writes.
    private static let barsHeight = 48.0
    /// How tall the row of buttons under the text is.
    private static let rowHeight = 38.0
    /// How far the text is from the panel's sides, which lines it up with the
    /// names of the files above it.
    private static let textInset = 14.0

    private var generator: MessageGenerator { composer.generator }

    private var generateButton: GenerateButtonState {
        GenerateButtonState(
            showsButton: showsGenerateButton,
            agent: agents?.defaultAgent.flatMap { agents?.named($0) },
            // What the box shows, which during a rebase is the message of the
            // commit it stopped on rather than the draft underneath.
            hasText: !composer.shownMessage.allSatisfy(\.isWhitespace),
            isWriting: generator.isWriting,
            readiness: generator.readiness
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            editor
            row
        }
        .background(Palette.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
        }
        // The light goes along the box's edge while an agent writes in it
        // (decision 68), which is the line over it.
        .overlay {
            if generator.isWriting {
                AgentOutline(shape: .topLine, showsLine: false, isWorking: true)
            }
        }
        // A popover whose button has gone, as when the menu started an agent,
        // shouldn't come back with the button.
        .onChange(of: generateButton == .hidden) { _, isHidden in
            if isHidden { isChoosingAgent = false }
        }
    }

    // MARK: The top of the box

    /// What the top of the box says about who the commit goes out as.
    private var identity: IdentityException? {
        IdentityException(repository?.identity, defaultIdentity: list?.defaultIdentity)
    }

    /// Whether anything shows above the text.
    private var hasTop: Bool {
        if composer.chip != nil || composer.note != nil || identity != nil { return true }
        if case .failed = composer.phase { return true }
        switch generator.phase {
        case .failed: return true
        case .written(let written): return written.stagedFilesChanged
        case .idle, .writing: return false
        }
    }

    /// What's worth knowing about the commit, above the text: what kind of
    /// commit it is, a sentence about it, and why a commit or an agent didn't
    /// get through, each with its own way on.
    @ViewBuilder private var top: some View {
        if hasTop {
            VStack(alignment: .leading, spacing: 6) {
                if let chip = composer.chip {
                    CommitBoxChip(chip: chip, isEnabled: composer.phase != .committing && !generator.isWriting) {
                        composer.setAmending(false)
                    }
                }
                if let note = composer.note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 3)
                }
                if let identity, let repository, let list {
                    switch identity {
                    case .problem(let problem):
                        CommitBoxIdentityWarning(problem: problem, repository: repository, list: list)
                    case .someoneElse(let someone):
                        CommitBoxIdentityLine(identity: someone, repository: repository, list: list)
                    }
                }
                if case .failed(let output) = composer.phase {
                    CommitFailure(output: output, canSkipHooks: composer.canSkipHooks) {
                        composer.commit(skippingHooks: true)
                    }
                }
                switch generator.phase {
                case .failed(let failure):
                    CommitBoxGenerateFailure(
                        failure: failure,
                        canTryAgain: generator.readiness == .ready && agents?.generation(with: failure.agent.id) != nil,
                        tryAgain: { generator.generate(with: agents?.generation(with: failure.agent.id)) },
                        openSettings: { openSettings(.page(.agents)) }
                    )
                case .written(let written) where written.stagedFilesChanged:
                    Text("Staged changes were modified during generation.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 3)
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.rowInset)
            .padding(.top, 8)
        }
    }

    // MARK: The text

    private var editor: some View {
        let isWriting = generator.isWriting
        let fitted = min(max(textHeight, Self.shortest), Self.tallest)
        let least = isWriting ? max(fitted, Self.barsHeight) : fitted
        return ZStack(alignment: .topLeading) {
            // The text view stays while an agent writes, so that its undo and the
            // keyboard's place in it are still there afterward. It's hidden from
            // VoiceOver too, which would otherwise read the text from before
            // under bars that say the message is being written.
            MessageEditor(
                text: Binding { composer.shownMessage } set: { composer.message = $0 },
                isEditable: !composer.isMessageReadOnly,
                focusRequests: composer.focusRequests,
                textHeight: $textHeight,
                leave: leave,
                isCovered: isWriting,
                replacedTextMotion: reducesMotion ? nil : ChangesSplit.motion
            )
            .opacity(isWriting ? 0 : 1)
            .accessibilityHidden(isWriting)
            if isWriting {
                CommitBoxBars()
            } else {
                if composer.shownMessage.isEmpty {
                    Text("Message")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                if composer.subjectLength > 0 {
                    let isLong = composer.subjectLength > CommitComposer.subjectLimit
                    Text(composer.subjectLength, format: .number)
                        .font(.system(size: 11, weight: isLong ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isLong ? Palette.red : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .allowsHitTesting(false)
                        .accessibilityLabel("The first line has \(composer.subjectLength) characters")
                }
            }
        }
        // As tall as the text needs, or more when the panel gives the box more
        // room than that (`ChangesSplit`).
        .frame(minHeight: least, idealHeight: least, maxHeight: .infinity)
        .padding(.horizontal, Self.textInset)
        .padding(.top, hasTop ? 7 : 10)
        .padding(.bottom, 2)
    }

    // MARK: The row of buttons

    /// Generate, or what's running, at the left, and Commit at the right. Their
    /// words get shorter, a step at a time, when the row is short of room, and
    /// in the narrowest panels Commit goes onto a line of its own.
    private var row: some View {
        let fit = rowFit
        return Group {
            if fit.isStacked {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) { leading(fit) }
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        trailing(fit)
                    }
                }
                .padding(.vertical, 6)
            } else {
                HStack(spacing: 6) {
                    leading(fit)
                    Spacer(minLength: Self.rowGap)
                    trailing(fit)
                }
                .frame(height: Self.rowHeight)
            }
        }
        .padding(.horizontal, Self.rowInset)
        // As wide as the box, whatever its buttons would like, so that the
        // width measured is the room there is, and too much never widens it.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { rowWidth = $0 }
        // The row centers its buttons, 6 points from its bottom, and these 2
        // make that as far as they are from the panel's sides.
        .padding(.bottom, 2)
    }

    @ViewBuilder private func leading(_ fit: RowFit) -> some View {
        if case .writing(let writing) = generator.phase {
            CommitBoxStopWriting(writing: writing, stop: generator.stop)
        } else if composer.isSlow {
            Text("Waiting for hooks or signing…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 4)
        } else {
            if case .shown(let agent, let rewrites, let readiness) = generateButton, let agents {
                GenerateButton(agent: agent, rewrites: rewrites, isCompact: fit.isGenerateCompact, readiness: readiness, isChoosing: $isChoosingAgent) {
                    // A click on it while the popover is open runs what was
                    // just picked there, and closes it.
                    isChoosingAgent = false
                    generator.generate(with: agents.generation())
                } choices: {
                    AgentPopover(
                        agents: agents,
                        job: .generate(hasDraft: composer.hasMessage),
                        worktree: composer.worktree,
                        openAgentSettings: { id in
                            isChoosingAgent = false
                            openSettings(.agent(id))
                        }
                    ) {
                        isChoosingAgent = false
                    }
                }
            }
            if case .written(let written) = generator.phase {
                CommitBoxUndo(written: written, isIcon: fit.isUndoIcon, undo: generator.undo)
            }
        }
    }

    @ViewBuilder private func trailing(_ fit: RowFit) -> some View {
        if composer.isSlow {
            CommitBoxStopCommitting(stop: composer.stop)
        } else {
            CommitButton(composer: composer, isShort: fit.isCommitShort)
        }
    }

    /// How far the row's buttons, and the chip over the text, are from the
    /// panel's sides, and the buttons from its bottom.
    private static let rowInset = 8.0
    /// The least room between the row's two ends.
    private static let rowGap = 6.0

    /// How much the row's words say: everything, then Generate without the
    /// agent's name, then Undo as an arrow, then Commit without its count, and
    /// last Commit on a line of its own.
    private struct RowFit: Equatable {
        var isGenerateCompact = false
        var isUndoIcon = false
        var isCommitShort = false
        var isStacked = false

        static let widestFirst = [
            RowFit(),
            RowFit(isGenerateCompact: true),
            RowFit(isGenerateCompact: true, isUndoIcon: true),
            RowFit(isGenerateCompact: true, isUndoIcon: true, isCommitShort: true),
            RowFit(isGenerateCompact: true, isUndoIcon: true, isStacked: true),
            RowFit(isGenerateCompact: true, isUndoIcon: true, isCommitShort: true, isStacked: true),
        ]
    }

    /// The widest way of saying the row that fits, or the narrowest when none
    /// does, which then cuts the words short.
    private var rowFit: RowFit {
        let room = rowWidth - 2 * Self.rowInset
        guard room > 0 else { return RowFit() }
        return RowFit.widestFirst.first { fits($0, in: room) } ?? RowFit.widestFirst[RowFit.widestFirst.count - 1]
    }

    /// Whether the row fits in `room`, said that way: both ends side by side
    /// with the least room between them, or each on its own line when stacked.
    private func fits(_ fit: RowFit, in room: Double) -> Bool {
        let action = composer.action
        let trailing = composer.isSlow
            ? CommitBoxStopCommitting.width
            : CommitButton.width(title: fit.isCommitShort ? action.shortTitle : action.title, hasMenu: composer.hasMoreWaysToCommit)
        var leading = 0.0
        if case .writing = generator.phase {
            leading = CommitBoxStopWriting.width
        } else if !composer.isSlow {
            if case .shown(let agent, let rewrites, _) = generateButton {
                leading += GenerateButton<EmptyView>.width(agent: agent, rewrites: rewrites, isCompact: fit.isGenerateCompact)
            }
            if case .written = generator.phase {
                leading += 6 + (fit.isUndoIcon ? CommitBoxUndo.iconWidth : CommitBoxUndo.wordWidth)
            }
        }
        return fit.isStacked ? max(leading, trailing) <= room : leading + Self.rowGap + trailing <= room
    }
}

/// How wide words are in the system font, for deciding what the message box's
/// row has room for. SwiftUI draws `.system(size:weight:)` in the same font.
enum RowWords {
    static func width(_ words: String, size: CGFloat, weight: NSFont.Weight = .medium) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return (words as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
}

/// Commit at the right of the box's row, filled with the brand's orange while
/// a click would run, and cut by a thin line from a chevron with the Changes
/// menu's own group: Commit, Commit and Push, and Amend (decision 98). The
/// chevron stays while the button can't be pressed, since Amend is how an
/// empty box gets a message to change. It's gray then only when its menu has
/// nothing to choose either, and otherwise in ink, the way Generate's words
/// are while they can be pressed, so that it doesn't look as dead as Commit's
/// words beside it.
private struct CommitButton: View {
    @Bindable var composer: CommitComposer
    /// Whether it says only its verb, for a row that's short of room.
    let isShort: Bool
    /// Whether the pointer is over the chevron.
    @State private var isHoveringMenu = false

    private static let height = 26.0
    private static let cornerRadius = 7.0

    /// How wide it is with those words: the words and their padding, and the
    /// thin line and the chevron with its own.
    static func width(title: String, hasMenu: Bool) -> CGFloat {
        RowWords.width(title, size: 12) + 18 + (hasMenu ? 1 + 19 : 0)
    }

    var body: some View {
        let action = composer.action
        let canChoose = composer.canChooseMoreWaysToCommit
        HStack(spacing: 0) {
            Button {
                composer.commit()
            } label: {
                Text(isShort ? action.shortTitle : action.title)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .disabled(!action.isEnabled)
            .help("\(action.title) (\(RepositoryCommands.commitShortcut.symbols))")
            .accessibilityLabel(action.title)
            if composer.hasMoreWaysToCommit {
                Rectangle()
                    .fill(action.isEnabled ? Color.white.opacity(0.32) : SettingsColors.line)
                    .frame(width: 1)
                Menu {
                    CommitMenuItems(composer: composer)
                } label: {
                    Icon.dropdown.image
                        .font(.system(size: 11 / 1.128, weight: .medium))
                        .foregroundStyle(action.isEnabled ? Color.white : (canChoose ? Color.primary : Color.secondary))
                        .padding(.horizontal, 4)
                        .frame(height: Self.height)
                        // On gray, the pointer over it fills it the way it
                        // fills any button, which the orange doesn't need.
                        .background(isHoveringMenu && canChoose && !action.isEnabled ? Palette.buttonHover : Color.clear)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .disabled(!canChoose)
                .onHover { isHoveringMenu = $0 }
                .help("Commit and Push, or Amend")
                .accessibilityLabel("More Ways to Commit")
            }
        }
        .buttonStyle(CommitButtonPartStyle())
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(action.isEnabled ? Color.white : Color.secondary)
        .frame(height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(action.isEnabled ? Palette.actionFill : Palette.selection)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .fixedSize()
    }
}

/// Either part of Commit, which dims a little while pressed. Its colors already
/// say when it can't be pressed, so unlike the plain style it doesn't dim then.
private struct CommitButtonPartStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// The items behind Commit's chevron, which are the Changes menu's own group for
/// making the commit, with the same keys, in the sentence case of a menu in the
/// window.
struct CommitMenuItems: View {
    let composer: CommitComposer

    var body: some View {
        let action = composer.action
        Button(action.menuTitle) { composer.commit() }
            .keyboardShortcut(RepositoryCommands.commitShortcut)
            .disabled(!action.isEnabled)
        Button("Commit and push") { composer.commitAndPush() }
            .keyboardShortcut(RepositoryCommands.commitAndPushShortcut)
            .disabled(!action.isEnabled || composer.stoppedWork != nil)
        Divider()
        Toggle("Amend", isOn: Binding { composer.isAmending } set: { composer.setAmending($0) })
            .keyboardShortcut(RepositoryCommands.amendShortcut)
            .disabled(!composer.canToggleAmend)
    }
}

/// What kind of commit this is, when it isn't an ordinary one to the current
/// branch, in a chip at the top of the box. Amending's is filled with ink, the
/// way what's chosen is, and its ✕ puts the draft back.
private struct CommitBoxChip: View {
    let chip: CommitComposer.Chip
    /// Whether its ✕ can be pressed, which it can't while committing or while
    /// an agent writes.
    let isEnabled: Bool
    let stopAmending: () -> Void

    private var isAmend: Bool { chip.kind == .amend }

    var body: some View {
        HStack(spacing: 5) {
            icon.image
                .font(.system(size: 12 / 1.128, weight: .medium))
                .accessibilityHidden(true)
            words
                .lineLimit(1)
                .truncationMode(.middle)
            if isAmend {
                Button(action: stopAmending) {
                    Icon.x.image
                        .font(.system(size: 10 / 1.128, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isEnabled ? 0.8 : 0.4)
                .disabled(!isEnabled)
                .help("Stop Amending (\(RepositoryCommands.amendShortcut.symbols))")
                .accessibilityLabel("Stop Amending")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(isAmend ? Palette.onInk : Color.primary)
        .padding(.leading, 7)
        .padding(.trailing, isAmend ? 2 : 8)
        .frame(height: 22)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isAmend ? Palette.ink : DialogColors.card)
        }
        .accessibilityElement(children: .contain)
    }

    private var words: Text {
        chip.subject.isEmpty
            ? Text(chip.lead)
            : Text("\(Text(chip.lead)) \(Text(chip.subject).fontWeight(.semibold))")
    }

    private var icon: Icon {
        switch chip.kind {
        case .amend, .firstCommit, .detached: .commit
        case .merge: .merge
        case .revert: .revert
        case .cherryPick: .cherryPick
        case .rebase: .branch
        }
    }
}

/// What Generate turns into while an agent writes: the sidebar's ring and Stop,
/// with the agent's line around it lit, and the seconds so far beside it. Stop
/// gives the box back as it was.
private struct CommitBoxStopWriting: View {
    let writing: MessageGenerator.Writing
    let stop: () -> Void

    /// About as wide as it is, with a few seconds counted.
    static let width = 104.0

    var body: some View {
        HStack(spacing: 7) {
            Button(action: stop) {
                HStack(spacing: 6) {
                    AgentMark(state: .working)
                    Text("Stop")
                }
                .padding(.leading, 7)
                .padding(.trailing, 10)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(DialogColors.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                AgentOutline(shape: .outline(cornerRadius: 7), isLit: true)
            }
            .help("Stop generation and restore the previous message")
            .accessibilityLabel("Stop Generating")
            TimelineView(.periodic(from: writing.since, by: 1)) { context in
                Text(Self.seconds(since: writing.since, now: context.date))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(MessageGenerator.writingWords(writing.agent, since: writing.since, now: context.date))
                    .accessibilityLabel(MessageGenerator.writingWords(writing.agent, since: writing.since, now: context.date))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .fixedSize()
    }

    /// The seconds so far, from the first whole one, as the line under the box
    /// used to count them.
    static func seconds(since: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(since))
        return seconds >= 1 ? "\(seconds) s" : ""
    }
}

/// What Commit turns into while hooks or signing take a while: a spinner and
/// Stop, which stops the commit as it would a hook that's hung.
private struct CommitBoxStopCommitting: View {
    let stop: () -> Void

    static let width = 72.0

    var body: some View {
        Button(action: stop) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Stop")
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .background(DialogColors.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("Stop the Commit")
        .accessibilityLabel("Stop the Commit")
        .fixedSize()
    }
}

/// Undo beside Rewrite, once an agent has written the message: the sidebar's dot
/// for what finished and the word, or an arrow where the row is short of room.
/// Its tooltip says who wrote the message and how fast.
private struct CommitBoxUndo: View {
    let written: MessageGenerator.Written
    let isIcon: Bool
    let undo: () -> Void

    static let iconWidth = 26.0
    static var wordWidth: Double { 6 + 6 + 5 + RowWords.width("Undo", size: 12) + 6 }

    var body: some View {
        Button(action: undo) {
            Group {
                if isIcon {
                    Icon.undo2.image
                        .font(.system(size: 13 / 1.128, weight: .medium))
                        .frame(width: Self.iconWidth, height: 26)
                        .overlay(alignment: .topTrailing) {
                            AgentMark(state: .finished, size: 10)
                                .padding(1)
                        }
                } else {
                    HStack(spacing: 5) {
                        AgentMark(state: .finished, size: 12)
                        Text("Undo")
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Palette.action)
        .help("\(MessageGenerator.writtenWords(written)) Restore the previous commit message.")
        .accessibilityLabel("Undo")
        .accessibilityHint(MessageGenerator.writtenWords(written))
        .fixedSize()
    }
}

/// Where the text goes while an agent writes it: three gray bars, as long as
/// lines of a message might be.
private struct CommitBoxBars: View {
    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                bar(proxy.size.width * 0.78)
                    .padding(.top, 6)
                bar(proxy.size.width * 0.92)
                    .padding(.top, 12)
                bar(proxy.size.width * 0.6)
                    .padding(.top, 6)
            }
        }
        .frame(height: 48, alignment: .top)
        .accessibilityElement()
        .accessibilityLabel("Generating commit message")
    }

    private func bar(_ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(DialogColors.card)
            .frame(width: width, height: 8)
    }
}

/// The fill behind a failure at the top of the box: the red of a failure, faint
/// enough to read gray words on.
private let failureFill = Palette.red.opacity(0.09)

/// Why an agent didn't write a message, at the top of the box. The message stays
/// as it was. What the agent printed is folded away, since the sentence above it
/// usually says enough.
private struct CommitBoxGenerateFailure: View {
    let failure: MessageGenerator.Failure
    let canTryAgain: Bool
    let tryAgain: () -> Void
    let openSettings: () -> Void
    @State private var showsOutput = false

    var body: some View {
        // Each line wraps in a narrow panel rather than losing its end.
        VStack(alignment: .leading, spacing: 4) {
            Text(MessageGenerator.failureTitle(failure.agent))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.red)
                .fixedSize(horizontal: false, vertical: true)
            Text(failure.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let output = failure.output {
                Button {
                    showsOutput.toggle()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Chevron(pointsDown: showsOutput)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        Text("\(failure.agent.name) output")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityLabel(showsOutput ? "Hide \(failure.agent.name) output" : "Show \(failure.agent.name) output")
                if showsOutput {
                    ScrollView {
                        Text(output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 96)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Side by side when they fit, and one over the other when they don't.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions }
                VStack(alignment: .leading, spacing: 4) { actions }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.action)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(failureFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder private var actions: some View {
        Button("Try Again", action: tryAgain)
            .disabled(!canTryAgain)
        Button("Agent Settings…", action: openSettings)
    }
}

/// What git or a hook printed when a commit didn't go through, at the top of the
/// box, with Skip Hooks under it when a hook could have been why. A failing hook
/// is routine, so it says so here rather than in an alert, and the message stays.
private struct CommitFailure: View {
    let output: String
    let canSkipHooks: Bool
    let skipHooks: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The commit didn't go through")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.red)
            ScrollView {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            .fixedSize(horizontal: false, vertical: true)
            if canSkipHooks {
                Button("Skip Hooks", action: skipHooks)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.action)
                    .help("git commit --no-verify")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(failureFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// The text view for a commit's message. It's AppKit's rather than SwiftUI's, to
/// put the first line in bold as it's typed, and to leave Tab for moving on.
struct MessageEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let focusRequests: Int
    @Binding var textHeight: Double
    let leave: () -> Void
    /// Whether something else is drawn in its place, as the gray bars are
    /// while an agent writes. VoiceOver then skips the text view, which still
    /// has the text from before, since AppKit doesn't skip a view for being
    /// see-through.
    var isCovered = false
    /// How the height changes for text that comes from elsewhere, such as the
    /// message Amend brings in. Typing changes it at once, to keep up with the text.
    var replacedTextMotion: Animation?

    private static let subjectAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
    ]
    private static let bodyAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor.labelColor,
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        update(scrollView, coordinator: context.coordinator)
    }

    /// What `makeNSView` makes, which tests call without SwiftUI's context.
    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.delegate = coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // A commit's message is plain text that other tools read.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.setAccessibilityLabel("Commit Message")

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        coordinator.textView = textView
        textView.string = text
        coordinator.styleText()
        return scrollView
    }

    /// What `updateNSView` does, which tests call without SwiftUI's context.
    func update(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
            textView.textColor = isEditable ? .labelColor : .secondaryLabelColor
        }
        if textView.isAccessibilityElement() == isCovered {
            textView.setAccessibilityElement(!isCovered)
            scrollView.setAccessibilityElement(!isCovered)
        }
        let isNewText = textView.string != text
        if isNewText {
            coordinator.replaceText(with: text)
        }
        if focusRequests != coordinator.focusRequests {
            coordinator.focusRequests = focusRequests
            textView.window?.makeFirstResponder(textView)
        }
        // A new width can change how many lines there are. New text has been
        // measured already, on its way to a height that glides.
        if !isNewText {
            coordinator.measure()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageEditor
        weak var textView: NSTextView?
        var focusRequests: Int
        /// Whether the text view is taking text from the binding, which it
        /// then doesn't need to give back.
        private var isReplacing = false

        init(_ parent: MessageEditor) {
            self.parent = parent
            focusRequests = parent.focusRequests
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !isReplacing else { return }
            parent.text = textView.string
            styleText()
            measure()
        }

        /// Puts in text that comes from elsewhere, such as an agent's message,
        /// the message of the commit Amend replaces, or nothing once a commit
        /// is made, as one edit that Command-Z takes back, the way the note's
        /// Undo does.
        ///
        /// Setting the text view's string instead would leave its undo steps
        /// for the text that was there, and undoing those on other text mixes
        /// the two up, or throws when the old text was longer.
        func replaceText(with text: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let whole = NSRange(location: 0, length: storage.length)
            // A text view that can't be edited refuses every change, so it
            // can be edited for this one, as when a rebase's message shows.
            let isEditable = textView.isEditable
            textView.isEditable = true
            isReplacing = true
            // Typing before and after it are steps of their own.
            textView.breakUndoCoalescing()
            if textView.shouldChangeText(in: whole, replacementString: text) {
                storage.replaceCharacters(in: whole, with: text)
                textView.didChangeText()
            } else {
                // The text view registers its undo steps with its storage,
                // and none of them fit the new text.
                textView.string = text
                textView.undoManager?.removeAllActions(withTarget: storage)
            }
            textView.breakUndoCoalescing()
            isReplacing = false
            textView.isEditable = isEditable
            styleText()
            measure(motion: parent.replacedTextMotion)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateTypingAttributes()
        }

        /// Puts the first line in bold.
        func styleText() {
            guard let textView, let storage = textView.textStorage else { return }
            let text = storage.string as NSString
            let subject = text.lineRange(for: NSRange(location: 0, length: 0))
            storage.beginEditing()
            storage.setAttributes(MessageEditor.bodyAttributes, range: NSRange(location: 0, length: text.length))
            storage.setAttributes(MessageEditor.subjectAttributes, range: subject)
            storage.endEditing()
            updateTypingAttributes()
        }

        private func updateTypingAttributes() {
            guard let textView else { return }
            let text = textView.string as NSString
            let subject = text.lineRange(for: NSRange(location: 0, length: 0))
            let location = textView.selectedRange().location
            let isOnSubject = location < subject.upperBound || (location == subject.upperBound && !text.substring(with: subject).hasSuffix("\n"))
            textView.typingAttributes = isOnSubject ? MessageEditor.subjectAttributes : MessageEditor.bodyAttributes
        }

        /// Says how much room the text needs, once SwiftUI has finished updating.
        func measure(motion: Animation? = nil) {
            guard let textView, let manager = textView.layoutManager, let container = textView.textContainer else { return }
            manager.ensureLayout(for: container)
            let height = Double(manager.usedRect(for: container).height)
            guard abs(height - parent.textHeight) > 0.5 else { return }
            Task { @MainActor [parent] in
                withAnimation(motion) { parent.textHeight = height }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // git's habit is a blank line after the subject, so the first Return
                // leaves one, and the body starts right there.
                let text = textView.string as NSString
                let selection = textView.selectedRange()
                guard selection.length == 0, selection.location == text.length,
                      !text.contains("\n"), text.length > 0 else { return false }
                textView.insertText("\n\n", replacementRange: selection)
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.leave()
                return true
            default:
                return false
            }
        }
    }
}
