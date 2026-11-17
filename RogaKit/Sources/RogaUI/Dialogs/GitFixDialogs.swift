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
        dialog(fixingWith: nil)
    }

    /// What to say now, where asking again asks `setup`'s agent, the default
    /// that the buttons' chevrons pick (decision 91), or else the agent asked
    /// last.
    func dialog(fixingWith setup: GenerationSetup?) -> DialogContent? {
        let again = setup ?? askedAgent
        return switch phase {
        case nil:
            nil
        case .asking(let kind, let program, let showsPath):
            asking(kind, program: program, showsPath: showsPath)
        case .answered(let kind, let fix):
            answer(from: kind, fix, isRunning: false)
        case .running(let kind, let fix):
            answer(from: kind, fix, isRunning: true)
        case .finished(let lines, let count, let refused):
            finished(lines, count: count, refused: refused, again: again)
        case .failed(let kind, let message, let output):
            failure(kind, message: message, output: output, again: again)
        }
    }

    /// A button that asks `setup`'s agent again, with the chevron that picks
    /// another agent first.
    private func askAgainButton(_ title: String, with setup: GenerationSetup) -> DialogButton {
        DialogButton(title: title, kind: .agent, agentChoice: AgentChoice(job: .fix, worktree: worktree)) { [weak self] in
            self?.askAgain(with: setup)
        }
    }

    private func asking(_ kind: NamedAgent, program: ProgramCommand, showsPath: Bool) -> DialogContent {
        DialogContent(
            id: "gitFix-asking",
            title: "Asking \(kind.name)…",
            // A custom agent's command is someone's own, so Roga can't say
            // what it turns off (decision 89).
            message: "Sending Git output and worktree diagnostics to \(kind.name).\(kind.id.kind == nil ? "" : " Agent tools are disabled.") Review and approve any suggested commands before running them.",
            terminal: [.program(program, showsPath: showsPath)],
            isWaitingForAgent: true,
            buttons: [DialogButton(title: "Stop", kind: .secondary) { [weak self] in self?.dismiss() }],
            dismiss: { [weak self] in self?.dismiss() }
        )
    }

    private func answer(from kind: NamedAgent, _ fix: AgentGitFix, isRunning: Bool) -> DialogContent {
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
                title: "Suggested fix from \(kind.shortName)",
                message: said,
                note: Self.refusalNote(fix),
                terminal: terminal,
                buttons: [DialogButton(title: "OK", kind: .primary, action: close)],
                dismiss: close
            )
        }
        return DialogContent(
            id: "gitFix-answer",
            title: "Suggested fix from \(kind.shortName)",
            message: said,
            note: fix.keepsEverything ? "Commands have not run yet." : "Commands have not run yet. Review them carefully: they may discard work that Git cannot recover.",
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
        return .sentences(["\(code: ShellCommand.text(command.arguments)) won't run from here, because \(reason).", copy])
    }

    private func finished(_ lines: [TerminalLine], count: Int, refused: RefusedCommand?, again: GenerationSetup?) -> DialogContent {
        let close = { [weak self] in self?.dismiss(); return () }
        let ok = DialogButton(title: "OK", kind: .primary, action: close)
        guard let refused else {
            return DialogContent(
                id: "gitFix-finished",
                title: count == 1 ? "Command completed" : "Commands completed",
                message: "Retry the original operation.",
                terminal: lines,
                buttons: [ok],
                dismiss: close
            )
        }
        var sentences: [DialogText] = ["git refused \(code: ShellCommand.text(refused.command))."]
        if refused.skipped > 0 {
            sentences.append(refused.skipped == 1 ? "The command after it didn't run." : "The \(refused.skipped.formatted()) commands after it didn't run.")
        }
        sentences.append("Git output is shown below.")
        // The agent often gets it right once it has seen what git said, and
        // another agent might.
        let askAgain = again.map { askAgainButton("Fix with \($0.agent.shortName)", with: $0) }
        return DialogContent(
            id: "gitFix-finished",
            title: count == 1 ? "git refused the command" : "The commands stopped partway",
            message: .sentences(sentences),
            terminal: lines,
            buttons: [askAgain, ok].compactMap(\.self),
            dismiss: close
        )
    }

    private func failure(_ kind: NamedAgent, message: String, output: String?, again: GenerationSetup?) -> DialogContent {
        let close = { [weak self] in self?.dismiss(); return () }
        // Another agent, or a bigger model, is often what an agent that
        // couldn't answer needs, and its chevron picks one.
        let tryAgain = again.map { askAgainButton("Try Again", with: $0) }
        return DialogContent(
            id: "gitFix-failed",
            title: "\(kind.name) couldn't suggest a fix",
            message: DialogText(stringLiteral: message),
            terminal: output.map { [.output($0)] } ?? [],
            buttons: [tryAgain, DialogButton(title: "OK", kind: .primary, action: close)].compactMap(\.self),
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
    /// Whose agent asking again asks, which a chevron can change while the
    /// sheet shows.
    let agents: AgentProvider?
    /// The dialog as it was shown, for while the sheet closes and it's gone.
    let shown: DialogContent
    @State private var height: CGFloat = 0

    var body: some View {
        DialogSheet(content: model.dialog(fixingWith: agents?.generation()) ?? shown)
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
