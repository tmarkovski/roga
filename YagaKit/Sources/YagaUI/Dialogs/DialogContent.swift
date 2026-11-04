import Foundation
import GitCore
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

    /// The same words without any styling.
    var plain: String {
        parts.map { part in
            switch part {
            case .words(let text), .code(let text): text
            }
        }.joined()
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
}

/// A line in a dialog's terminal block.
enum TerminalLine: Equatable {
    /// A git command that a button will run, by its arguments after `git`.
    case command([String])
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
    }

    var title: String
    var kind: Kind
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
    /// Gray cards, one after the other, between the message and the note.
    var cards: [[DialogRow]] = []
    /// A smaller gray line after the cards.
    var note: DialogText?
    var terminal: [TerminalLine] = []
    var buttons: [DialogButton]
    /// What Escape, the × and clicking outside of a button mean.
    var dismiss: () -> Void
}

extension DialogContent {
    /// Says that git refused, or that something else went wrong, with an OK button.
    /// With a command to show, what git said goes under it in the terminal block.
    /// Otherwise it's only words, and they go with the message.
    static func refusal(
        id: String,
        title: String,
        summary: DialogText? = nil,
        command: [String]?,
        said: String,
        note: DialogText? = nil,
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
            buttons: [ok],
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
