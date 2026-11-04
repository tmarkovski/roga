import AppKit
import GitCore
import IconUI
import SwiftUI

/// The message of the next commit, under the worktree's files (decision 30). It's
/// one text box, with the first line in bold, the way the commit panel will show
/// it, and it grows as it fills.
struct CommitBox: View {
    @Bindable var composer: CommitComposer
    /// Gives the keyboard back to the list of files.
    let leave: () -> Void
    /// The room the text needs.
    @State private var textHeight = 0.0

    /// Three lines, and then about half of an ordinary window's panel.
    private static let shortest = 56.0
    private static let tallest = 240.0

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
                        .disabled(composer.phase == .committing)
                        .help("Replace the commit HEAD is on (\(RepositoryCommands.amendShortcut.symbols))")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .frame(height: 32)

            editor
                .padding(.horizontal, 10)

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
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Palette.separator)
                        }
                        .contentShape(Rectangle())
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
    }

    private var heading: some View {
        let parts = composer.heading
        return Text("\(Text(parts.lead).foregroundStyle(.secondary)) \(Text(parts.subject).fontWeight(.medium))")
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            MessageEditor(
                text: Binding { composer.shownMessage } set: { composer.message = $0 },
                isEditable: !composer.isMessageReadOnly,
                focusRequests: composer.focusRequests,
                textHeight: $textHeight,
                leave: leave
            )
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
        .frame(height: min(max(textHeight, Self.shortest), Self.tallest))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.separator)
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
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
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
        context.coordinator.textView = textView
        textView.string = text
        context.coordinator.styleText()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            coordinator.styleText()
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
            textView.textColor = isEditable ? .labelColor : .secondaryLabelColor
        }
        if focusRequests != coordinator.focusRequests {
            coordinator.focusRequests = focusRequests
            textView.window?.makeFirstResponder(textView)
        }
        // A new width can change how many lines there are.
        coordinator.measure()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageEditor
        weak var textView: NSTextView?
        var focusRequests: Int

        init(_ parent: MessageEditor) {
            self.parent = parent
            focusRequests = parent.focusRequests
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            styleText()
            measure()
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
        func measure() {
            guard let textView, let manager = textView.layoutManager, let container = textView.textContainer else { return }
            manager.ensureLayout(for: container)
            let height = Double(manager.usedRect(for: container).height)
            guard abs(height - parent.textHeight) > 0.5 else { return }
            Task { @MainActor [parent] in parent.textHeight = height }
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
