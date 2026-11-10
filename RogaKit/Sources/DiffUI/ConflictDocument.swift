import AppKit
import GitCore
import ThemeUI

/// What a conflict's two sides are called, which the side's rows and the buttons
/// on each conflict's band say (decision 60). Roga names them by where they came
/// from, rather than by git's ours and theirs, which swap places in a rebase and a
/// stash pop.
public struct ConflictSides: Sendable, Hashable {
    public struct Side: Sendable, Hashable {
        /// What it is, such as `main`, `origin/main`, `a17f9d3` or `the revert`.
        public var name: String
        /// More about it, such as a commit's short hash and subject.
        public var detail: String
        /// The button that keeps it, such as `Keep main's`.
        public var keepTitle: String
        /// What a conflict says once it's kept, such as `Kept main's`.
        public var keptTitle: String

        public init(name: String, detail: String, keepTitle: String, keptTitle: String) {
            self.name = name
            self.detail = detail
            self.keepTitle = keepTitle
            self.keptTitle = keptTitle
        }
    }

    /// The side git calls ours.
    public var ours: Side
    /// The side git calls theirs.
    public var theirs: Side

    public init(ours: Side, theirs: Side) {
        self.ours = ours
        self.theirs = theirs
    }
}

/// The colors of a file's conflicts, from the canvas's Resolving conflicts page.
/// The sides, and what's unresolved or kept, are the color theme's (decision 71).
nonisolated enum ConflictColors {
    static let ours = ColorTheme.following(\.ours)
    static let theirs = ColorTheme.following(\.theirs)
    static let unresolved = ColorTheme.following(\.removed)
    static let kept = ColorTheme.following(\.added)
    static let action = color(light: 0xC94402, dark: 0xF0813F)
    static let band = color(light: 0xF4F4F2, dark: 0x2A2A29)
    static let line = color(light: 0xE2E2E2, dark: 0x393939)
    static let text = color(light: 0x1F1F1E, dark: 0xECECEA)
    static let secondaryText = color(light: 0x67675F, dark: 0xB3B3AE)
    static let button = color(light: 0xFFFFFF, dark: 0x222222)
    static let buttonHover = color(light: 0xECECEC, dark: 0x333333)
    static let buttonPressed = color(light: 0xE3E3E3, dark: 0x3A3A3A)

    private static func color(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        }
    }
}

/// What a row of a conflicted file is, beyond a line of the file.
nonisolated enum ConflictRow: Sendable, Hashable {
    enum Part: Sendable, Hashable {
        case ours
        case base
        case theirs
        /// What a resolved conflict kept.
        case kept
    }

    /// The band that starts a conflict, by its index, which has the buttons, and
    /// what a resolved one says it kept.
    case band(Int, isResolved: Bool, showsSides: Bool = false, kept: String? = nil)
    /// The rest of a band, which is taller than a row of text.
    case bandRest
    /// The row that names a side.
    case label(Part)
    /// One of a side's lines.
    case line(Part)
    /// What a side with no lines shows.
    case empty(Part)

    var background: NSColor? {
        switch self {
        case .band, .bandRest: ConflictColors.band
        case .label(.ours): NSColor.systemBlue.withAlphaComponent(0.18)
        case .label(.theirs): NSColor.systemPurple.withAlphaComponent(0.18)
        case .label(.base): NSColor.secondaryLabelColor.withAlphaComponent(0.06)
        case .line(.ours), .empty(.ours): NSColor.systemBlue.withAlphaComponent(0.08)
        case .line(.theirs), .empty(.theirs): NSColor.systemPurple.withAlphaComponent(0.08)
        case .label(.kept), .line(.base), .empty(.base), .line(.kept), .empty(.kept): nil
        }
    }

    /// The color of the bar beside it in the gutter.
    var bar: NSColor? {
        switch self {
        case .line(.ours), .empty(.ours): ConflictColors.ours
        case .line(.theirs), .empty(.theirs): ConflictColors.theirs
        case .line(.kept), .empty(.kept): DiffStyle.addedBar
        case .band, .bandRest, .label, .line(.base), .empty(.base): nil
        }
    }
}

/// A conflict's band, and which conflict it starts.
nonisolated struct ConflictBand: Sendable, Hashable {
    /// How many rows of text a band takes up. Every row of a diff is the same
    /// height, which is how a position in the view becomes a row.
    static let rowCount = 2

    /// The band's first row.
    var row: Int
    /// The conflict's index in the file.
    var conflict: Int
    var isResolved: Bool
    /// Whether a resolved conflict shows its sides under what it kept.
    var showsSides = false
    /// What a resolved conflict says it kept, such as `Kept main's`.
    var kept: String?
}

/// How Roga shows a file with conflicts: its lines, and for each conflict a band
/// that says which it is, then each side, named and in a color of its own. A
/// resolved conflict shows what it kept instead.
nonisolated extension DiffTextBuilder {
    /// - Parameters:
    ///   - writtenBy: Who wrote what some resolved conflicts kept, such as an
    ///     agent, which their bands say.
    ///   - shownSides: The resolved conflicts that show their sides under what
    ///     they kept, for comparing.
    @concurrent
    public static func document(
        for file: ConflictedFile,
        choices: [Int: ConflictedFile.Choice],
        sides: ConflictSides,
        writtenBy: [Int: String] = [:],
        shownSides: Set<Int> = []
    ) async -> DiffDocument {
        build(file, choices: choices, sides: sides, writtenBy: writtenBy, shownSides: shownSides)
    }

    static func build(
        _ file: ConflictedFile,
        choices: [Int: ConflictedFile.Choice],
        sides: ConflictSides,
        writtenBy: [Int: String] = [:],
        shownSides: Set<Int> = []
    ) -> DiffDocument {
        var bytes: [UInt8] = []
        var lines: [FilePatch.Line] = []
        var rows: [ConflictRow?] = []
        var edits: [Int: String] = [:]

        func add(_ text: some Collection<UInt8>, _ row: ConflictRow?, number: Int?) {
            let start = bytes.count
            bytes.append(contentsOf: text)
            lines.append(FilePatch.Line(kind: .context, newNumber: number, text: start..<bytes.count))
            bytes.append(0x0A)
            rows.append(row)
        }
        // Adds each line of some text, numbered from a line, and says where the
        // numbering got to.
        func addLines(_ text: ArraySlice<UInt8>, _ row: ConflictRow?, from number: Int, numbered: Bool = true) -> Int {
            var number = number
            var start = text.startIndex
            while start < text.endIndex {
                let newline = text[start...].firstIndex(of: 0x0A)
                add(text[start..<(newline ?? text.endIndex)], row, number: numbered ? number : nil)
                number += 1
                start = newline.map { $0 + 1 } ?? text.endIndex
            }
            return number
        }

        // Its rows are empty, because `ConflictBar` says what it is.
        func addBand(_ band: ConflictRow) {
            add([], band, number: nil)
            for _ in 1..<ConflictBand.rowCount { add([], .bandRest, number: nil) }
        }

        func addSide(_ part: ConflictRow.Part, _ label: String, _ text: ArraySlice<UInt8>, from number: Int, numbered: Bool = true) -> Int {
            add(Array(label.utf8), .label(part), number: nil)
            if text.isEmpty {
                add(Array("No lines".utf8), .empty(part), number: nil)
                return number
            }
            return addLines(text, .line(part), from: number, numbered: numbered)
        }

        var position = 0
        var number = 1
        for (index, conflict) in file.conflicts.enumerated() {
            number = addLines(file.bytes[position..<conflict.range.lowerBound], nil, from: number)
            position = conflict.range.upperBound
            if let choice = choices[index] {
                let kept = switch choice {
                case .ours: sides.ours.keptTitle
                case .theirs: sides.theirs.keptTitle
                case .both: "Kept both"
                case .lines: writtenBy[index].map { "\($0) wrote this" } ?? "Kept what you wrote"
                }
                let showsSides = shownSides.contains(index)
                addBand(.band(index, isResolved: true, showsSides: showsSides, kept: kept))
                let keptLines = file.lines(choice, for: conflict)
                if keptLines.isEmpty {
                    add(Array("No lines".utf8), .empty(.kept), number: nil)
                } else {
                    number = addLines(keptLines[...], .line(.kept), from: number)
                }
                // The sides aren't in the file any more, so their lines have no numbers.
                if showsSides {
                    _ = addSide(.ours, sides.ours.name + " · " + sides.ours.detail, file.bytes[conflict.ours], from: 0, numbered: false)
                    if let base = conflict.base {
                        _ = addSide(.base, conflict.baseLabel.map { "What both started from, \($0)" } ?? "What both started from", file.bytes[base], from: 0, numbered: false)
                    }
                    _ = addSide(.theirs, sides.theirs.name + " · " + sides.theirs.detail, file.bytes[conflict.theirs], from: 0, numbered: false)
                }
                continue
            }
            var startingText = Array(file.bytes[conflict.ours]) + Array(file.bytes[conflict.theirs])
            if startingText.last == 0x0A { startingText.removeLast() }
            edits[index] = String(decoding: startingText, as: UTF8.self)

            addBand(.band(index, isResolved: false))
            // Each marker is a line of the file, which the numbers count.
            number += 1
            number = addSide(.ours, sides.ours.name + " · " + sides.ours.detail, file.bytes[conflict.ours], from: number)
            if let base = conflict.base {
                number += 1
                let label = conflict.baseLabel.map { "What both started from, \($0)" } ?? "What both started from"
                number = addSide(.base, label, file.bytes[base], from: number)
            }
            number += 1
            number = addSide(.theirs, sides.theirs.name + " · " + sides.theirs.detail, file.bytes[conflict.theirs], from: number)
            number += 1
        }
        _ = addLines(file.bytes[position...], nil, from: number)

        let patch = FilePatch(bytes: bytes, lines: lines)
        return build(patch, conflicts: ConflictLayout(rows: rows, edits: edits, sides: sides))
    }
}

/// What a document of a conflicted file knows beyond its lines.
nonisolated struct ConflictLayout: Sendable {
    /// What each row is, or nil for a line of the file.
    var rows: [ConflictRow?]
    /// The text each unresolved conflict's editor starts with: both sides.
    var edits: [Int: String]
    var sides: ConflictSides

    /// Which rows each unresolved conflict takes up: its band, and everything up to
    /// the next line of the file or the next conflict's band.
    var unresolvedRows: [Range<Int>] {
        var blocks: [Range<Int>] = []
        var row = 0
        while row < rows.count {
            guard case .band(_, isResolved: false, _, _) = rows[row] else {
                row += 1
                continue
            }
            var end = row + 1
            while end < rows.count, let next = rows[end] {
                if case .band = next { break }
                end += 1
            }
            blocks.append(row..<end)
            row = end
        }
        return blocks
    }

    /// The bands, in order.
    var bands: [ConflictBand] {
        rows.indices.compactMap { row in
            if case .band(let conflict, let isResolved, let showsSides, let kept) = rows[row] {
                ConflictBand(row: row, conflict: conflict, isResolved: isResolved, showsSides: showsSides, kept: kept)
            } else {
                nil
            }
        }
    }

    /// The color a row's text takes, when it isn't a line of the file.
    static func textColor(_ row: ConflictRow) -> NSColor? {
        switch row {
        case .band, .bandRest: nil
        case .label(.ours): ConflictColors.ours
        case .label(.theirs): ConflictColors.theirs
        case .label: .secondaryLabelColor
        case .empty: .secondaryLabelColor
        case .line: nil
        }
    }
}
