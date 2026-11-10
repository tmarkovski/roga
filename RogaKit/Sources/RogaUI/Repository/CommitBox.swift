import AgentEngine
import AppKit
import GitCore
import IconUI
import SwiftUI

/// The message of the next commit, under the worktree's files (decision 30). It's
/// one text box, with the first line in bold, the way the commit panel will show
/// it. It fills the fifth of the panel it's given, and grows past that as it
/// fills.
///
/// Its bottom right corner has the Generate button, which has an agent write the
/// message from what's staged (decision 41). While the agent writes, the box
/// waits with gray bars in place of its text, and the line under it counts the
/// seconds and offers Stop. Then the line says who wrote it and offers Undo, or
/// says why the agent didn't.
struct CommitBox: View {
    @Bindable var composer: CommitComposer
    /// Gives the keyboard back to the list of files.
    let leave: () -> Void
    /// The room the text needs.
    @State private var textHeight = 0.0
    /// Whether the popover for choosing the agent is open.
    @State private var isChoosingAgent = false
    /// The agents, which every window has, though a view that's tested on its
    /// own may not.
    @Environment(AgentProvider.self) private var agents: AgentProvider?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @AppStorage(AgentPreferences.showsGenerateButtonKey) private var showsGenerateButton = true

    /// Three lines, and then about half of an ordinary window's panel.
    private static let shortest = 56.0
    private static let tallest = 240.0
    /// How much more room the box leaves under its text for the Generate button.
    /// The canvas leaves 34 points there, for the button with 6 under it and 4
    /// over it, where the text otherwise has 7. The box's least and greatest
    /// heights stay the same, so the text has that much less.
    private static let generateRoom = GenerateButton<EmptyView>.height + 6 + 4 - 7
    /// How much room the gray bars take while an agent writes.
    private static let barsHeight = 54.0

    private var generator: MessageGenerator { composer.generator }

    private var generateButton: GenerateButtonState {
        GenerateButtonState(
            showsButton: showsGenerateButton,
            agent: agents?.generateAgent,
            // What the box shows, which during a rebase is the message of the
            // commit it stopped on rather than the draft underneath.
            hasText: !composer.shownMessage.allSatisfy(\.isWhitespace),
            isWriting: generator.isWriting,
            readiness: generator.readiness
        )
    }

    /// Whether the box leaves room for the Generate button, which it keeps while
    /// the button gives way to an agent writing, so that the box doesn't jump.
    private var leavesGenerateRoom: Bool {
        showsGenerateButton && agents?.generateAgent != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                heading
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if composer.canAmend {
                    Toggle("Amend", isOn: Binding { composer.isAmending } set: { composer.setAmending($0) })
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .disabled(composer.phase == .committing || generator.isWriting)
                        .help("Replace the commit HEAD is on (\(RepositoryCommands.amendShortcut.symbols))")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .frame(height: 32)

            editor
                .padding(.horizontal, 10)

            generatorStatus

            if let note = composer.note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            if composer.isSlow {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Waiting for hooks or signing…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Stop", action: composer.stop)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.action)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            if case .failed(let output) = composer.phase {
                CommitFailure(output: output)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }

            HStack(spacing: 8) {
                Text(RepositoryCommands.commitShortcut.symbols)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if composer.canSkipHooks {
                    Button("Skip Hooks") { composer.commit(skippingHooks: true) }
                        .buttonStyle(OutlinedButtonStyle(height: 26, horizontalPadding: 10))
                        .help("git commit --no-verify")
                }
                primaryButton
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(height: 44)
        }
        .background(Palette.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
        }
        // A popover whose button has gone, as when the menu started an agent,
        // shouldn't come back with the button.
        .onChange(of: generateButton == .hidden) { _, isHidden in
            if isHidden { isChoosingAgent = false }
        }
    }

    /// The line under the box for what an agent is doing or did.
    @ViewBuilder private var generatorStatus: some View {
        switch generator.phase {
        case .idle:
            EmptyView()
        case .writing(let writing):
            CommitBoxWriting(writing: writing, stop: generator.stop)
        case .written(let written):
            CommitBoxWritten(written: written, undo: generator.undo)
        case .failed(let failure):
            CommitBoxGenerateFailure(
                failure: failure,
                canTryAgain: generator.readiness == .ready && agents?.usableAgents.contains(failure.kind) == true,
                tryAgain: { generator.generate(with: agents?.generation(with: failure.kind)) },
                openSettings: { openSettings(.agent(failure.kind)) }
            )
        }
    }

    private var heading: some View {
        let parts = composer.heading
        return Text("\(Text(parts.lead).foregroundStyle(.secondary)) \(Text(parts.subject).fontWeight(.medium))")
    }

    private var editor: some View {
        let room = leavesGenerateRoom ? Self.generateRoom : 0
        let isWriting = generator.isWriting
        let fitted = min(max(textHeight, Self.shortest - room), Self.tallest - room)
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
        .padding(.horizontal, 9)
        .padding(.top, 7)
        .padding(.bottom, 7 + room)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.separator)
        }
        // The light goes around what the agent is working on (decision 68).
        .overlay {
            if isWriting {
                AgentOutline(shape: .outline(cornerRadius: 8), showsLine: false, isWorking: true)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if case .shown(let agent, let rewrites, let readiness) = generateButton, let agents {
                GenerateButton(agent: agent, rewrites: rewrites, readiness: readiness, isChoosing: $isChoosingAgent) {
                    generator.generate(with: agents.generation())
                } choices: {
                    GeneratePopover(
                        agents: agents,
                        worktree: composer.worktree,
                        hasDraft: composer.hasMessage,
                        canGenerate: generator.readiness == .ready
                    ) { kind in
                        isChoosingAgent = false
                        generator.generate(with: agents.generation(with: kind))
                    } close: {
                        isChoosingAgent = false
                    }
                }
                // 6 points inside the border, as the canvas has it.
                .padding(7)
            }
        }
    }

    private var primaryButton: some View {
        let action = composer.action
        return Button(action.title) { composer.commit() }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(action.isEnabled ? Color.white : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(action.isEnabled ? Palette.actionFill : Palette.selection)
            }
            .contentShape(Rectangle())
            .disabled(!action.isEnabled)
    }
}

/// The line under the box while an agent writes: the sidebar's ring, the agent
/// and the seconds so far, and Stop, which gives the box back as it was.
private struct CommitBoxWriting: View {
    let writing: MessageGenerator.Writing
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            AgentMark(state: .working)
                // Centered on the first line's letters, as it is on a line of its own.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            // In a narrow panel the words go onto a second line rather than
            // losing the seconds, which are what keeps changing.
            TimelineView(.periodic(from: writing.since, by: 1)) { context in
                Text(MessageGenerator.writingWords(writing.kind, since: writing.since, now: context.date))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Stop", action: stop)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.action)
                .fixedSize()
                .help("Stop \(writing.kind.name), and leave the message as it was")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 8)
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
        .frame(height: 54, alignment: .top)
        .accessibilityElement()
        .accessibilityLabel("The message is being written")
    }

    private func bar(_ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(DialogColors.card)
            .frame(width: width, height: 8)
    }
}

/// The line under the box once an agent has written the message: the sidebar's
/// dot for what finished, who wrote it and how fast, and Undo, which puts back
/// what was there.
private struct CommitBoxWritten: View {
    let written: MessageGenerator.Written
    let undo: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            AgentMark(state: .finished)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(MessageGenerator.writtenWords(written))
                .fixedSize(horizontal: false, vertical: true)
            Button("Undo", action: undo)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.action)
                .help("Put back what was in the box before")
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

/// Why an agent didn't write a message, in a red outline like a commit that
/// didn't go through. The message stays as it was. What the agent printed is
/// folded away, since the sentence above it usually says enough.
private struct CommitBoxGenerateFailure: View {
    let failure: MessageGenerator.Failure
    let canTryAgain: Bool
    let tryAgain: () -> Void
    let openSettings: () -> Void
    @State private var showsOutput = false

    var body: some View {
        // Each line wraps in a narrow panel rather than losing its end.
        VStack(alignment: .leading, spacing: 4) {
            Text(MessageGenerator.failureTitle(failure.kind))
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
                        Text("What \(failure.kind.name) printed")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityLabel(showsOutput ? "Hide what \(failure.kind.name) printed" : "Show what \(failure.kind.name) printed")
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
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Palette.red)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    @ViewBuilder private var actions: some View {
        Button("Try Again", action: tryAgain)
            .disabled(!canTryAgain)
        Button("Agent Settings…", action: openSettings)
    }
}

/// What git or a hook printed when a commit didn't go through. A failing hook is
/// routine, so it says so here rather than in an alert, and the message stays.
private struct CommitFailure: View {
    let output: String

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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Palette.red)
        }
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
