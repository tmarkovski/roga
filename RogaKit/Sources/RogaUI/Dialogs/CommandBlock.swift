import AppKit
import Foundation
import GitRunner
import IconUI
import SwiftUI
import ThemeUI

/// The dark block along a dialog's bottom edge, which shows the exact commands
/// that will run, or what ran and what git said. It's dark in both appearances, in
/// Monokai's colors, and scrolls rather than growing past a limit.
struct CommandBlock: View {
    let lines: [TerminalLine]
    /// Whether it's the smaller block along the bottom of a popover, such as
    /// Generate's, which the Settings boards draw in a smaller font with less
    /// room around it. Dialogs and Settings use the full size.
    var isCompact = false
    /// A font size of its own, for a block in a column narrow enough that
    /// the commands it usually shows would each wrap by a few letters at the
    /// compact size, as on setup's screens.
    var fontSize: CGFloat?
    /// How tall it always is, for commands that change while a sheet can't. What
    /// doesn't fit scrolls.
    var fixedHeight: CGFloat? = nil
    /// Other lines it may show in place of `lines`, whose room it keeps, hidden,
    /// so that it's as tall as the longest of them. Generate's popover keeps
    /// every agent's command this way, so that it doesn't change size, and
    /// move its rows, when another agent is picked.
    var reserving: [[TerminalLine]] = []
    @State private var isCopied = false
    @State private var clearing: Task<Void, Never>?

    /// How tall it gets before it scrolls, because a hook can say a lot.
    static let maximumHeight: CGFloat = 220
    /// The same for the compact block, which gets taller, because it's the
    /// only place a popover shows its command (decision 29). Codex's long
    /// arguments wrap its command onto about ten lines in Generate's popover,
    /// and with overlay scrollers nothing would say that its end had
    /// scrolled out of sight.
    static let compactMaximumHeight: CGFloat = 320

    private var maximumHeight: CGFloat {
        isCompact ? Self.compactMaximumHeight : Self.maximumHeight
    }

    /// The room between lines, and between the lines that a long command wraps
    /// onto. A block with an agent's command is drawn as the Settings boards draw
    /// one, with lines 1.6 times the font's size apart, since its long arguments
    /// wrap it onto several lines. Git's blocks keep the tighter lines they had.
    private func lineGap(_ lines: [TerminalLine]) -> (between: CGFloat, wrapped: CGFloat) {
        guard lines.contains(where: \.isProgram) else { return (2, 0) }
        let gap = fontSize.map(Self.lineGap(forFontSize:)) ?? (isCompact ? Self.compactLineGap : Self.boardLineGap)
        return (gap, gap)
    }

    /// The room to add between lines so that they're 1.6 times a font's
    /// size apart.
    private static func lineGap(forFontSize size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return max(0, size * 1.6 - NSLayoutManager().defaultLineHeight(for: font))
    }

    private static let boardLineGap: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return max(0, 12 * 1.6 - NSLayoutManager().defaultLineHeight(for: font))
    }()

    /// The same for the compact block's smaller font.
    private static let compactLineGap: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: compactFontSize, weight: .regular)
        return max(0, compactFontSize * 1.6 - NSLayoutManager().defaultLineHeight(for: font))
    }()

    private static let compactFontSize: CGFloat = 11.5

    /// The room around the lines, with more on the right for Copy.
    private var padding: EdgeInsets {
        isCompact
            ? EdgeInsets(top: 9, leading: 14, bottom: 10, trailing: 38)
            : EdgeInsets(top: 11, leading: 18, bottom: 13, trailing: 44)
    }

    var body: some View {
        ClampedHeight(maximum: fixedHeight ?? maximumHeight) {
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(reserving.enumerated()), id: \.offset) { _, lines in
                        rows(lines)
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    rows(lines)
                }
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(height: fixedHeight, alignment: .top)
        .font(.system(size: fontSize ?? (isCompact ? Self.compactFontSize : 12), design: .monospaced))
        .overlay(alignment: .topTrailing) {
            Button(action: copy) {
                (isCopied ? Icon.check : Icon.copy).image
                    .font(.system(size: 13))
            }
            .buttonStyle(.icon(size: 24))
            .foregroundStyle(Self.promptColor)
            .help("Copy")
            .accessibilityLabel(isCopied ? "Copied" : "Copy the Command")
            .padding(isCompact ? EdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 6) : EdgeInsets(top: 7, leading: 0, bottom: 0, trailing: 10))
        }
        .background(DialogColors.terminal)
        .environment(\.colorScheme, .dark)
    }

    private func rows(_ lines: [TerminalLine]) -> some View {
        let gap = lineGap(lines)
        return VStack(alignment: .leading, spacing: gap.between) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .lineSpacing(gap.wrapped)
    }

    @ViewBuilder private func row(_ line: TerminalLine) -> some View {
        switch line {
        case .command(let arguments), .ran(let arguments):
            command(ShellCommand.tokens(arguments))
        case .program(let program, let showsPath):
            command(ShellCommand.tokens(program, showsPath: showsPath))
        case .room(let arguments):
            command(ShellCommand.tokens(arguments))
                .hidden()
        case .output(let text):
            Text(verbatim: text)
                .foregroundStyle(Self.outputColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .comment(let text):
            Text(verbatim: "# " + text)
                .foregroundStyle(Self.promptColor)
                .fixedSize(horizontal: false, vertical: true)
        case .gap:
            Color.clear.frame(height: 6)
        case .blank:
            Text(verbatim: " ")
                .accessibilityHidden(true)
        }
    }

    private func command(_ tokens: [ShellCommand.Token]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(verbatim: "$")
                .foregroundStyle(Self.promptColor)
                .accessibilityHidden(true)
            Text(Self.attributed(tokens))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.copied(lines), forType: .string)
        isCopied = true
        clearing?.cancel()
        clearing = Task {
            guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            isCopied = false
        }
    }

    // MARK: What it says

    /// What Copy puts on the pasteboard. Commands that will run can be pasted and
    /// run, so it's only those. Otherwise it's what happened, as it reads here.
    /// A program's command is copied whole, with its full path and none of its
    /// arguments shortened, because the block only shortens them to fit.
    static func copied(_ lines: [TerminalLine]) -> String {
        let commands = lines.compactMap { line -> String? in
            switch line {
            case .command(let arguments): ShellCommand.text(arguments)
            case .program(let program, _): program.description
            default: nil
            }
        }
        if !commands.isEmpty { return commands.joined(separator: "\n") }
        return lines.map { line in
            switch line {
            case .command(let arguments), .ran(let arguments): "$ " + ShellCommand.text(arguments)
            case .program(let program, _): "$ " + program.description
            case .output(let text): text
            case .comment(let text): "# " + text
            case .gap, .blank, .room: ""
            }
        }.joined(separator: "\n")
    }

    private static func attributed(_ tokens: [ShellCommand.Token]) -> AttributedString {
        var text = AttributedString()
        for (index, token) in tokens.enumerated() {
            if index > 0 { text += AttributedString(" ") }
            var part = AttributedString(token.text)
            part.foregroundColor = color(of: token.kind)
            text += part
        }
        return text
    }

    /// The color theme's color for a part of a command (decision 71).
    private static func color(of kind: ShellCommand.Token.Kind) -> Color {
        let colors = ColorTheme.observed.colors.command
        return switch kind {
        case .command: Color(nsColor: colors.program)
        case .option: Color(nsColor: colors.option)
        case .dangerousOption: Color(nsColor: colors.dangerousOption)
        case .value: Color(nsColor: colors.value)
        case .text: Color(nsColor: colors.text)
        }
    }

    private static var promptColor: Color { Color(nsColor: ColorTheme.observed.colors.command.prompt) }
    private static var outputColor: Color { Color(nsColor: ColorTheme.observed.colors.command.output) }
}

/// A command as someone would type it, in parts that the terminal block colors:
/// git's, or another program's.
enum ShellCommand {
    struct Token: Equatable {
        enum Kind: Equatable {
            /// `git` and its subcommand, or a program and its subcommands.
            case command
            case option
            /// An option that makes the command able to lose something, which
            /// stands out as the part worth reading.
            case dangerousOption
            /// A branch, a remote, a path, or a value such as a model's name.
            case value
            /// Words for a person or a model to read, such as an agent's
            /// prompt, which is in purple, like a string in Monokai.
            case text
        }

        var text: String
        var kind: Kind
    }

    private static let dangerousOptions: Set<String> = [
        "-D", "--force", "--force-with-lease", "--force-if-includes", "--delete", "--abort", "--hard", "--worktree",
    ]
    /// Subcommands whose next word is part of the command, as in `git worktree remove`.
    private static let subcommandsWithVerbs: Set<String> = ["worktree", "remote", "stash"]

    /// The command with `git` in front, quoted so that it can be pasted and run.
    static func text(_ arguments: [String]) -> String {
        tokens(arguments).map(\.text).joined(separator: " ")
    }

    static func tokens(_ arguments: [String]) -> [Token] {
        var tokens = [Token(text: "git", kind: .command)]
        for (index, argument) in arguments.enumerated() {
            let kind: Token.Kind
            if index == 0 || (index == 1 && subcommandsWithVerbs.contains(arguments[0])) {
                kind = .command
            } else if argument.hasPrefix("-") {
                kind = dangerousOptions.contains(argument) ? .dangerousOption : .option
            } else {
                kind = .value
            }
            tokens.append(Token(text: quoted(argument), kind: kind))
        }
        return tokens
    }

    /// An argument as a shell would need it, which is usually as it is. A folder
    /// can have a space in its name.
    static func quoted(_ argument: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@%+,"))
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Programs other than git

    /// How many characters an argument can have before the block shortens it,
    /// and how many of them it shows then. Claude Code's system prompt is a
    /// paragraph, which would push the rest of its command out of sight.
    static let longArgument = 48
    static let shortenedArgument = 40

    /// The words that are a program's subcommands when they come first, as in
    /// `codex exec` and `claude plugin marketplace add`. After the first word
    /// that isn't one, the rest are options and values.
    private static let programSubcommands: Set<String> = [
        "exec", "plugin", "marketplace", "add", "remove", "install", "uninstall", "update", "list", "agents",
    ]

    /// A program's command as the block shows it, which is for reading rather
    /// than pasting: long arguments are shortened, and paths in the home folder
    /// start with `~`. Copy uses the command's own `description`.
    static func text(_ command: ProgramCommand, showsPath: Bool = false) -> String {
        tokens(command, showsPath: showsPath).map(\.text).joined(separator: " ")
    }

    /// A program's command in parts: the program by its name, or by its path
    /// when the name wouldn't find it, then its subcommands, options and
    /// values. Words for the agent to read, such as a prompt, are text.
    static func tokens(_ command: ProgramCommand, showsPath: Bool = false) -> [Token] {
        var tokens = [Token(text: showsPath ? shownPath(command.executable) : ShellQuoting.quoted(command.name), kind: .command)]
        var isLeading = true
        for argument in command.arguments {
            let kind: Token.Kind
            if isLeading, programSubcommands.contains(argument) {
                kind = .command
            } else {
                isLeading = false
                if argument.hasPrefix("-") {
                    kind = .option
                } else if isPath(argument) {
                    kind = .value
                } else if argument.count > longArgument || argument.contains(where: \.isWhitespace) {
                    kind = .text
                } else {
                    kind = .value
                }
            }
            tokens.append(Token(text: shown(argument), kind: kind))
        }
        return tokens
    }

    /// An argument as the block shows it: quoted as a shell would need it, and
    /// shortened to its first words and an ellipsis when it's long. A path is
    /// never shortened, since which folder it is matters.
    private static func shown(_ argument: String) -> String {
        if isPath(argument) { return shownPath(argument) }
        guard argument.count > longArgument else { return ShellQuoting.quoted(argument) }
        let start = argument.prefix(shortenedArgument)
            .map { $0.isNewline ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return ShellQuoting.quoted(start + "…")
    }

    /// A path, with the home folder as `~`, which a shell expands as long as it
    /// isn't quoted. Spaces after it are escaped instead, as in
    /// `~/Library/Application\ Support`.
    private static func shownPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return ShellQuoting.quoted(path) }
        let rest = String(path.dropFirst(home.count + 1))
        if rest.isEmpty { return "~" }
        if ShellQuoting.quoted(rest.replacingOccurrences(of: " ", with: "")) == rest.replacingOccurrences(of: " ", with: "") {
            return "~/" + rest.replacingOccurrences(of: " ", with: "\\ ")
        }
        return "~/" + ShellQuoting.quoted(rest)
    }

    private static func isPath(_ argument: String) -> Bool {
        argument.hasPrefix("/") && !argument.contains("\n")
    }
}

extension TerminalLine {
    /// Whether it's a program other than git.
    fileprivate var isProgram: Bool {
        if case .program = self { true } else { false }
    }
}

/// Takes up the height of what's in it, up to a limit. A `ScrollView` says how tall
/// its content is when it's asked with no height in mind.
struct ClampedHeight: Layout {
    var maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let size = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: min(size.height, maximum))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
