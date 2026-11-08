import AgentEngine
import AppKit
import GitRunner
import SwiftUI

extension GitFixModel {
    /// The most of an agent's explanation to show. It's asked for three sentences,
    /// and the buttons come after it, so that much more shouldn't push them away.
    static let explanationLimit = 1_200

    /// What to say now, if anything, at each step of asking an agent (decision 63).
    var dialog: DialogContent? {
        switch phase {
        case nil:
            nil
        case .asking(let kind, let program, let showsPath):
            asking(kind, program: program, showsPath: showsPath)
        case .answered(let kind, let fix):
            answer(from: kind, fix, isRunning: false)
        case .running(let kind, let fix):
            answer(from: kind, fix, isRunning: true)
        case .finished(let lines, let count, let refused):
            finished(lines, count: count, refused: refused)
        case .failed(let kind, let message, let output):
            failure(kind, message: message, output: output)
        }
    }

    private func asking(_ kind: AgentKind, program: ProgramCommand, showsPath: Bool) -> DialogContent {
        DialogContent(
            id: "gitFix-asking",
            title: "Asking \(kind.name)…",
            message: "Roga is sending it what git said and what read-only commands show about this worktree. It has no tools, so it can only answer, and nothing runs until you say so.",
            terminal: [.program(program, showsPath: showsPath)],
            buttons: [DialogButton(title: "Stop", kind: .secondary) { [weak self] in self?.dismiss() }],
            dismiss: { [weak self] in self?.dismiss() }
        )
    }

    private func answer(from kind: AgentKind, _ fix: AgentGitFix, isRunning: Bool) -> DialogContent {
        let close = { [weak self] in self?.dismiss(); return () }
        let said = fix.explanation.isEmpty ? nil : DialogText(stringLiteral: String(fix.explanation.prefix(Self.explanationLimit)))
        guard !fix.commands.isEmpty else {
            return DialogContent(
                id: "gitFix-answer",
                title: "\(kind.shortName) has no fix to suggest",
                message: said ?? "\(kind.name) didn't suggest any commands.",
                buttons: [DialogButton(title: "OK", kind: .primary, action: close)],
                dismiss: close
            )
        }
        let terminal = fix.commands.map { TerminalLine.command($0.arguments) }
        guard fix.canRun else {
            return DialogContent(
                id: "gitFix-answer",
                title: "What \(kind.shortName) suggests",
                message: said,
                note: Self.refusalNote(fix),
                terminal: terminal,
                buttons: [DialogButton(title: "OK", kind: .primary, action: close)],
                dismiss: close
            )
        }
        return DialogContent(
            id: "gitFix-answer",
            title: "What \(kind.shortName) suggests",
            message: said,
            note: fix.keepsEverything ? "Nothing has run yet." : "Nothing has run yet. These commands can lose work that git can't bring back, so read them first.",
            terminal: terminal,
            buttons: [
                DialogButton(title: "Cancel", kind: .secondary, isEnabled: !isRunning, action: close),
                // A person has to choose this, so Return never presses it.
                DialogButton(
                    title: isRunning ? "Running…" : "Run",
                    kind: fix.keepsEverything ? .primary : .destructive,
                    isEnabled: !isRunning,
                    pressesWithReturn: false
                ) { [weak self] in
                    self?.run()
                },
            ],
            dismiss: close
        )
    }

    /// Says why Roga won't run what was suggested, naming the first command it won't.
    private static func refusalNote(_ fix: AgentGitFix) -> DialogText? {
        guard let command = fix.commands.first(where: { $0.refusal != nil }), let reason = command.refusal else { return nil }
        let copy: DialogText = fix.commands.count == 1 ? "You can copy it and run it yourself." : "None of these will run from here, but you can copy them and run them yourself."
        return .sentences(["Roga won't run \(code: ShellCommand.text(command.arguments)), because \(reason).", copy])
    }

    private func finished(_ lines: [TerminalLine], count: Int, refused: RefusedCommand?) -> DialogContent {
        let close = { [weak self] in self?.dismiss(); return () }
        let ok = DialogButton(title: "OK", kind: .primary, action: close)
        guard let refused else {
            return DialogContent(
                id: "gitFix-finished",
                title: count == 1 ? "The command ran" : "The commands ran",
                message: "You can try what failed again.",
                terminal: lines,
                buttons: [ok],
                dismiss: close
            )
        }
        var sentences: [DialogText] = ["git refused \(code: ShellCommand.text(refused.command))."]
        if refused.skipped > 0 {
            sentences.append(refused.skipped == 1 ? "The command after it didn't run." : "The \(refused.skipped.formatted()) commands after it didn't run.")
        }
        sentences.append("What git said is below.")
        // The agent often gets it right once it has seen what git said.
        let askAgain = askAgainTitle.map { title in
            DialogButton(title: title, kind: .secondary) { [weak self] in self?.askAgain() }
        }
        return DialogContent(
            id: "gitFix-finished",
            title: count == 1 ? "git refused the command" : "The commands stopped partway",
            message: .sentences(sentences),
            terminal: lines,
            buttons: [askAgain, ok].compactMap(\.self),
            dismiss: close
        )
    }

    private func failure(_ kind: AgentKind, message: String, output: String?) -> DialogContent {
        let close = { [weak self] in self?.dismiss(); return () }
        return DialogContent(
            id: "gitFix-failed",
            title: "\(kind.name) couldn't suggest a fix",
            message: DialogText(stringLiteral: message),
            terminal: output.map { [.output($0)] } ?? [],
            buttons: [DialogButton(title: "OK", kind: .primary, action: close)],
            dismiss: close
        )
    }
}

/// Reads its dialog in its own body, so that Run is disabled while the commands
/// run, since a sheet's item doesn't update what it shows while its `id` stays
/// the same.
///
/// SwiftUI keeps the sheet that's open when one dialog follows another, at the
/// size it opened with, and what an agent says can be any length. So this one
/// changes its window's height to fit each step, which no other dialog needs.
struct GitFixSheet: View {
    let model: GitFixModel
    /// The dialog as it was shown, for while the sheet closes and it's gone.
    let shown: DialogContent
    @State private var height: CGFloat = 0

    var body: some View {
        DialogSheet(content: model.dialog ?? shown)
            // As tall as it needs, whatever height the window has at the moment.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .background(SheetHeight(height: height))
            // Stays put at the top while the window's edge moves.
            .frame(maxHeight: .infinity, alignment: .top)
            .background(DialogColors.surface)
    }
}

/// Animates the window it's in to a height for its content, keeping the top edge
/// where it is.
private struct SheetHeight: NSViewRepresentable {
    let height: CGFloat

    /// How long the window takes to get there.
    private static let duration = 0.2
    /// Room to leave when a dialog is as tall as the screen.
    private static let screenMargin: CGFloat = 80

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        // Not during a layout pass, and the view may not be in its window yet.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window, height > 0 else { return }
            Self.resize(window, toContentHeight: height)
        }
    }

    private static func resize(_ window: NSWindow, toContentHeight height: CGFloat) {
        let limit = (window.screen?.visibleFrame.height ?? .greatestFiniteMagnitude) - screenMargin
        let current = window.contentRect(forFrameRect: window.frame).height
        let change = min(height.rounded(.up), limit) - current
        guard abs(change) >= 1 else { return }
        var frame = window.frame
        frame.origin.y -= change
        frame.size.height += change
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
            window.animator().setFrame(frame, display: true)
        }
    }
}
