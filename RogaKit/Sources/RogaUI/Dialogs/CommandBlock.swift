import AppKit
import IconUI
import SwiftUI

/// The dark block along a dialog's bottom edge, which shows the exact commands
/// that will run, or what ran and what git said. It's dark in both appearances, in
/// Monokai's colors, and scrolls rather than growing past a limit.
struct CommandBlock: View {
    let lines: [TerminalLine]
    @State private var isCopied = false
    @State private var clearing: Task<Void, Never>?

    /// How tall it gets before it scrolls, because a hook can say a lot.
    private static let maximumHeight: CGFloat = 220

    var body: some View {
        ClampedHeight(maximum: Self.maximumHeight) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        row(line)
                    }
                }
                .padding(EdgeInsets(top: 11, leading: 18, bottom: 13, trailing: 44))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .font(.system(size: 12, design: .monospaced))
        .overlay(alignment: .topTrailing) {
            Button(action: copy) {
                (isCopied ? Icon.check : Icon.copy).image
                    .font(.system(size: 13))
            }
            .buttonStyle(.icon(size: 24))
            .foregroundStyle(Self.promptColor)
            .help("Copy")
            .accessibilityLabel(isCopied ? "Copied" : "Copy the Command")
            .padding(EdgeInsets(top: 7, leading: 0, bottom: 0, trailing: 10))
        }
        .background(DialogColors.terminal)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func row(_ line: TerminalLine) -> some View {
        switch line {
        case .command(let arguments), .ran(let arguments):
            command(arguments)
        case .room(let arguments):
            command(arguments)
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

    private func command(_ arguments: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(verbatim: "$")
                .foregroundStyle(Self.promptColor)
                .accessibilityHidden(true)
            Text(Self.attributed(arguments))
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
    static func copied(_ lines: [TerminalLine]) -> String {
        let commands = lines.compactMap { line -> String? in
            if case .command(let arguments) = line { return ShellCommand.text(arguments) }
            return nil
        }
        if !commands.isEmpty { return commands.joined(separator: "\n") }
        return lines.map { line in
            switch line {
            case .command(let arguments), .ran(let arguments): "$ " + ShellCommand.text(arguments)
            case .output(let text): text
            case .comment(let text): "# " + text
            case .gap, .blank, .room: ""
            }
        }.joined(separator: "\n")
    }

    private static func attributed(_ arguments: [String]) -> AttributedString {
        var text = AttributedString()
        for (index, token) in ShellCommand.tokens(arguments).enumerated() {
            if index > 0 { text += AttributedString(" ") }
            var part = AttributedString(token.text)
            part.foregroundColor = color(of: token.kind)
            text += part
        }
        return text
    }

    private static func color(of kind: ShellCommand.Token.Kind) -> Color {
        switch kind {
        case .command: .init(hex: 0xF8F8F2)
        case .option: .init(hex: 0xE6DB74)
        case .dangerousOption: .init(hex: 0xFC5884)
        case .value: .init(hex: 0x66D9EF)
        }
    }

    private static let promptColor = Color(hex: 0xA59F85)
    private static let outputColor = Color(hex: 0xCFCFC2)
}

/// A git command as someone would type it, in parts that the terminal block colors.
enum ShellCommand {
    struct Token: Equatable {
        enum Kind: Equatable {
            /// `git` and its subcommand.
            case command
            case option
            /// An option that makes the command able to lose something, which
            /// stands out as the part worth reading.
            case dangerousOption
            /// A branch, a remote or a path.
            case value
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

extension Color {
    /// A fixed color from its hex value, for what doesn't follow the appearance.
    fileprivate init(hex: Int) {
        self.init(
            .sRGB,
            red: Double(hex >> 16 & 0xFF) / 255,
            green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
