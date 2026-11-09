import Foundation
import GitCore
import SwiftUI
import GitRunner

/// Words in a dialog, where a name from git can be set in the font of a command,
/// as in `"This overwrites 2 commits on \(code: upstream)."`.
struct DialogText: Equatable, ExpressibleByStringInterpolation {
    enum Part: Equatable {
        case words(String)
        case code(String)
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var parts: [Part] = []

        init(literalCapacity: Int, interpolationCount: Int) {}

        mutating func appendLiteral(_ literal: String) {
            if !literal.isEmpty { parts.append(.words(literal)) }
        }

        mutating func appendInterpolation(_ words: String) {
            parts.append(.words(words))
        }

        mutating func appendInterpolation(code: String) {
            parts.append(.code(code))
        }

        mutating func appendInterpolation(_ text: DialogText) {
            parts += text.parts
        }
    }

    var parts: [Part]

    init(stringLiteral value: String) {
        parts = [.words(value)]
    }

    init(stringInterpolation: StringInterpolation) {
        parts = stringInterpolation.parts
    }

    private init(parts: [Part]) {
        self.parts = parts
    }

    /// The same words, with what's from git in the font of a command.
    var attributed: AttributedString {
        var attributed = AttributedString()
        for part in parts {
            switch part {
            case .words(let words):
                attributed += AttributedString(words)
            case .code(let name):
                // A word joiner, so that a line doesn't break at a name's hyphen and
                // look like two words. It can still break at a slash.
                var code = AttributedString(name.replacingOccurrences(of: "-", with: "-\u{2060}"))
                code.font = .system(size: 12, design: .monospaced)
                attributed += code
            }
        }
        return attributed
    }

    /// The same words without any styling.
    var plain: String {
        parts.map { part in
            switch part {
            case .words(let text), .code(let text): text
            }
        }.joined()
    }

    /// Says which branches beside the ones a dialog offers are staying, or nil when
    /// there are none. git won't delete them, so they have nothing to choose.
    static func stayingCheckedOut(_ names: [String]) -> DialogText? {
        guard let last = names.last else { return nil }
        var parts: [Part] = []
        for (index, name) in names.dropLast().enumerated() {
            if index > 0 { parts.append(.words(", ")) }
            parts.append(.code(name))
        }
        if names.count > 1 { parts.append(.words(" and ")) }
        parts.append(.code(last))
        parts.append(.words((names.count == 1 ? " stays" : " stay") + ", because git won't delete a branch that's checked out."))
        return DialogText(parts: parts)
    }

    /// Sentences one after the other, or nil when there are none.
    static func sentences(_ sentences: [DialogText]) -> DialogText? {
        guard var parts = sentences.first?.parts else { return nil }
        for sentence in sentences.dropFirst() {
            parts.append(.words(" "))
            parts += sentence.parts
        }
        return DialogText(parts: parts)
    }
}

/// A row in one of a dialog's gray cards.
enum DialogRow: Equatable {
    /// A commit, with its short hash.
    case commit(hash: String, subject: String)
    /// Something and what happens to it, as in `3 uncommitted files`, `go with the folder`.
    case fact(String, String)
    /// A name in the font of a command, such as a file's path.
    case name(String)
    /// How many more there are than the rows show, as in `and 12 more`.
    case more(String)
    /// What becomes of the rows under it, as in `3 commits stay on topic`. It's in
    /// the color for what's lost when they go.
    case heading(String, isLost: Bool)
}

/// A switch in a dialog, for something that's up to the user. It keeps its words
/// while it flips, because a sheet can't change size.
struct DialogSwitch {
    var title: DialogText
    var detail: DialogText
    var isOn: Bool
    /// The letter that flips it. A dialog has nothing to type in, so it needs no
    /// modifier, and the tooltip says which it is.
    var key: Character?
    /// What the tooltip says, beside the key.
    var help: String?
    var flip: () -> Void
}

/// A line in a dialog's terminal block.
enum TerminalLine: Equatable {
    /// A git command that a button will run, by its arguments after `git`.
    case command([String])
    /// A program other than git that a button will run, such as an agent's
    /// command-line tool (decision 41). It shows by its name, the way someone
    /// with it in their `PATH` would type it, unless `showsPath`, for a copy
    /// that the name wouldn't find. Copy copies it whole, with its full path.
    case program(ProgramCommand, showsPath: Bool = false)
    /// A git command that already ran.
    case ran([String])
    /// What git said.
    case output(String)
    /// A remark, as in `# Undo the pull runs`.
    case comment(String)
    /// A small gap between lines.
    case gap
    /// An empty line, for a line that may come. A sheet doesn't change size once it
    /// has opened, so it needs the room from the start.
    case blank
    /// Nothing, as tall as this command would be, for a command that may come. A long
    /// one takes two lines, which a blank line wouldn't leave room for.
    case room([String])
}

/// A button along the bottom of a dialog.
struct DialogButton {
    enum Kind {
        case secondary
        /// What the dialog is for, which Return presses.
        case primary
        /// What can't be brought back. It's red, and Return doesn't press it,
        /// so it takes a click or Command-Return.
        case destructive
        /// Gives up what can't be brought back, but saves part of it. It's outlined
        /// in red rather than filled, and takes a click.
        case partlyDestructive
        /// Has an agent do it. It's a secondary button with the orange line that
        /// marks an agent's command (decision 65).
        case agent
    }

    var title: String
    var kind: Kind
    var isEnabled = true
    /// Whether Return presses it, when it's the primary button. It doesn't when
    /// what's being asked is probably a slip, so that it takes a click.
    var pressesWithReturn = true
    /// What the terminal block shows while the pointer is on this button, when that
    /// isn't what it usually shows. It needs as many lines, because a sheet can't
    /// change size.
    var terminal: [TerminalLine]? = nil
    var action: () -> Void

    /// What every question offers beside what it's asking about.
    static func cancel(_ dismiss: @escaping () -> Void) -> DialogButton {
        DialogButton(title: "Cancel", kind: .secondary, action: dismiss)
    }
}

/// What a dialog says and offers, whatever it's about. `DialogSheet` draws this.
///
/// A dialog says what will happen at the top, and the exact command in a terminal
/// block along its bottom edge (decision 29).
struct DialogContent: Identifiable {
    /// Stays the same for as long as the same question is being asked.
    var id: String
    var title: String
    var message: DialogText?
    /// Gray cards, one after the other, after the message.
    var cards: [[DialogRow]] = []
    /// What's up to the user, in one card after those.
    var switches: [DialogSwitch] = []
    /// Gray cards about what the switches lead to, after them.
    var cardsAfterSwitches: [[DialogRow]] = []
    /// A smaller gray line after the cards.
    var note: DialogText?
    var terminal: [TerminalLine] = []
    /// Whether the terminal block shows an agent that hasn't answered yet, which a
    /// light moving along its top says (decision 65).
    var isWaitingForAgent = false
    var buttons: [DialogButton]
    /// What Escape, the × and clicking outside of a button mean.
    var dismiss: () -> Void
}

extension DialogContent {
    /// What the terminal block shows while the pointer is on a button, if it's on one.
    func terminal(pointingAt button: Int?) -> [TerminalLine] {
        guard let button, buttons.indices.contains(button) else { return terminal }
        return buttons[button].terminal ?? terminal
    }

    /// Says that git refused, or that something else went wrong, with an OK button.
    /// With a command to show, what git said goes under it in the terminal block.
    /// Otherwise it's only words, and they go with the message. `fix` goes beside
    /// OK, for asking an agent what to do about it (decision 63).
    static func refusal(
        id: String,
        title: String,
        summary: DialogText? = nil,
        command: [String]?,
        said: String,
        note: DialogText? = nil,
        fix: DialogButton? = nil,
        dismiss: @escaping () -> Void
    ) -> DialogContent {
        let ok = DialogButton(title: "OK", kind: .primary, action: dismiss)
        guard let command else {
            return DialogContent(
                id: id,
                title: title,
                message: .sentences([summary, DialogText(stringLiteral: said)].compactMap(\.self)),
                note: note,
                buttons: [ok],
                dismiss: dismiss
            )
        }
        return DialogContent(
            id: id,
            title: title,
            message: summary,
            note: note,
            terminal: [.ran(command), .output(said)],
            buttons: [fix, ok].compactMap(\.self),
            dismiss: dismiss
        )
    }

    /// The most rows to list before saying how many more there are.
    static let listLimit = 5

    /// Rows for commits, and how many more there are than it lists.
    static func commitRows(_ commits: [ListedCommit], total: Int) -> [DialogRow] {
        var rows = commits.map { DialogRow.commit(hash: $0.hash, subject: $0.subject) }
        if total > commits.count { rows.append(.more("and \((total - commits.count).formatted()) more")) }
        return rows
    }

    /// Rows for the commits that a dialog's switches could lose, under words that say
    /// what the switches do to them now. The rows don't come and go, because a sheet
    /// can't change size, so it's only the words that change.
    ///
    /// - Parameters:
    ///   - commits: The newest of the commits that going as far as possible loses.
    ///   - total: How many of those there are.
    ///   - losing: How many of them go with the switches as they are.
    ///   - place: What keeps them when none go.
    static func commitRows(_ commits: [ListedCommit], total: Int, losing: Int, stayingOn place: String?) -> [DialogRow] {
        guard total > 0 else { return [] }
        let heading: DialogRow
        if losing == 0 {
            heading = .heading((total == 1 ? "1 commit stays on " : "\(total.formatted()) commits stay on ") + (place ?? ""), isLost: false)
        } else if losing < total {
            heading = .heading("\(losing.formatted()) of these \(total.formatted()) commits can't be brought back", isLost: true)
        } else {
            heading = .heading(total == 1 ? "This commit can't be brought back" : "These \(total.formatted()) commits can't be brought back", isLost: true)
        }
        return [heading] + commitRows(commits, total: total)
    }
}

/// A commit that a dialog names.
struct ListedCommit: Equatable {
    var hash: String
    var subject: String

    init(hash: String, subject: String) {
        self.hash = hash
        self.subject = subject
    }

    /// With its hash as short as history shows it.
    init(_ commit: CommitInfo) {
        self.init(hash: String(commit.id.hex.prefix(8)), subject: commit.subject)
    }
}

/// What to show for an error: the command that failed, if any, and what git said.
extension Error {
    /// What ran, by its arguments after `git`, when git is what failed.
    var gitArguments: [String]? {
        (self as? GitError)?.command?.arguments
    }

    /// What to tell someone: what git said, or a description of the error.
    var dialogMessage: String {
        (self as? GitError)?.message ?? String(describing: self)
    }
}
