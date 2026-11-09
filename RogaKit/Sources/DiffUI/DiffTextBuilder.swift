import AppKit
import GitCore

/// How diffs look. Every line has the same height, whatever fonts its
/// characters fall back on, and lines don't wrap, so each line of a patch is
/// one row.
nonisolated enum DiffStyle {
    // Fonts and paragraph styles can't change once they exist, and the builder
    // reads these away from the main actor.
    nonisolated(unsafe) static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let lineHeight: CGFloat = 17
    /// How far below the top of a row its text stands. TextKit puts the extra
    /// height of a row above the text.
    static var baseline: CGFloat { lineHeight + font.descender }
    /// How many columns a tab reaches, as in a terminal.
    static let tabWidth = 8

    /// The space before and after the text, which is inside the text's lines,
    /// so that their backgrounds cover it.
    static let textPadding: CGFloat = 6

    /// The width of one column of text.
    static let columnWidth = ("M" as NSString).size(withAttributes: [.font: font]).width

    static func background(_ kind: FilePatch.Line.Kind) -> NSColor? {
        switch kind {
        case .added: NSColor.systemGreen.withAlphaComponent(0.14)
        case .removed: NSColor.systemRed.withAlphaComponent(0.14)
        case .hunkHeader: NSColor.systemBlue.withAlphaComponent(0.09)
        case .context, .noNewline: nil
        }
    }

    /// The fill behind the parts of a changed line that differ, over the line's
    /// background.
    static func changedWordBackground(_ kind: FilePatch.Line.Kind) -> NSColor? {
        switch kind {
        case .added: NSColor.systemGreen.withAlphaComponent(0.28)
        case .removed: NSColor.systemRed.withAlphaComponent(0.28)
        case .hunkHeader, .context, .noNewline: nil
        }
    }

    static let changedWordCornerRadius: CGFloat = 3

    /// The fill behind the text being searched for.
    static var matchBackground: NSColor { NSColor.systemYellow.withAlphaComponent(0.3) }
    /// The fill behind the match that the search is at.
    static var currentMatchBackground: NSColor { NSColor.systemOrange.withAlphaComponent(0.65) }

    nonisolated(unsafe) static let paragraph: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.defaultTabInterval = columnWidth * CGFloat(tabWidth)
        paragraph.tabStops = []
        return paragraph
    }()
}

/// A patch made ready for the text view: what it shows, and which line of the
/// patch each part of the text belongs to. Nothing changes it once it's built,
/// so it can leave the task that built it.
nonisolated public final class DiffDocument: @unchecked Sendable {
    let storage: NSTextStorage
    let layoutManager: DiffLayoutManager
    let container: NSTextContainer
    /// The patch's lines, which the text has one row for each of.
    let lines: [FilePatch.Line]
    /// Where each line starts in `text`, in UTF-16 code units.
    let lineStarts: [Int]
    /// About how many columns the longest line takes, or more, which sets how
    /// far the text scrolls sideways. Non-contiguous layout means the text view
    /// doesn't measure every line, so it can't find this out itself.
    let columns: Int
    /// The parts of changed lines that differ from the other side, in order.
    let changedWords: [NSRange]
    /// Which lines are hunks' headers, in order.
    let hunkHeaders: [Int]
    /// For a file with conflicts, what its rows are beyond lines of the file
    /// (decision 60), or nil for a patch.
    let conflicts: ConflictLayout?
    /// The conflicts' bands, in order.
    let conflictBands: [ConflictBand]
    /// Which rows each unresolved conflict takes up, from its band to its last side.
    let unresolvedConflictRows: [Range<Int>]

    init(text: NSAttributedString, lines: [FilePatch.Line], lineStarts: [Int], columns: Int, changedWords: [NSRange], conflicts: ConflictLayout? = nil) {
        storage = NSTextStorage(attributedString: text)
        layoutManager = DiffLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        // The size TextKit's documentation suggests for text that doesn't wrap.
        // Much more than this and it loses precision.
        container = NSTextContainer(size: NSSize(width: 1e7, height: 1e7))
        container.widthTracksTextView = false
        container.lineFragmentPadding = DiffStyle.textPadding
        layoutManager.addTextContainer(container)
        self.lines = lines
        self.lineStarts = lineStarts
        self.columns = columns
        self.changedWords = changedWords
        hunkHeaders = lines.indices.filter { lines[$0].kind == .hunkHeader }
        self.conflicts = conflicts
        conflictBands = conflicts?.bands ?? []
        unresolvedConflictRows = conflicts?.unresolvedRows ?? []
        layoutManager.document = self
    }

    /// The background of a row, by what it is.
    func background(ofRow row: Int) -> NSColor? {
        if let conflicts {
            return conflicts.rows[row]?.background
        }
        return DiffStyle.background(lines[row].kind)
    }

    /// Whether this shows a file's conflicts rather than a patch.
    public var hasConflicts: Bool { conflicts != nil }

    /// The header of the hunk that a row belongs to, or nil for a row past the end.
    func hunkHeader(atRow row: Int) -> Int? {
        guard lines.indices.contains(row) else { return nil }
        var low = 0
        var high = hunkHeaders.count
        while low < high {
            let middle = (low + high) / 2
            if hunkHeaders[middle] <= row { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? hunkHeaders[low - 1] : nil
    }

    /// The index of the line that a position in the text belongs to.
    func lineIndex(atCharacter character: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while high - low > 1 {
            let middle = (low + high) / 2
            if lineStarts[middle] <= character { low = middle } else { high = middle }
        }
        return low
    }

    /// The number of digits in the largest line number.
    var numberDigits: Int {
        let largest = lines.reduce(0) { max($0, $1.oldNumber ?? 0, $1.newNumber ?? 0) }
        return String(largest).count
    }

    /// Where some text shows, ignoring case, away from the main actor, since a
    /// very long patch takes a while.
    @concurrent public func matches(of query: String) async -> [NSRange] {
        ranges(of: query)
    }

    /// Where some text shows, in order and without overlapping, in UTF-16 code
    /// units, stopping if the task is cancelled.
    func ranges(of query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let text = storage.string as NSString
        var ranges: [NSRange] = []
        var start = 0
        while !Task.isCancelled {
            let found = text.range(of: query, options: .caseInsensitive, range: NSRange(location: start, length: text.length - start))
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            start = found.upperBound
        }
        return ranges
    }
}

/// Builds what the text view shows from a patch, away from the main actor,
/// since a very long patch takes a while (decision 9). That includes laying out
/// the text, which nothing else is using yet, so the text view has only to draw
/// it. It also means the text view knows how tall the text is, where it would
/// otherwise estimate from the lines it had seen, and be 30% short on a long
/// patch, so that the scroller would move as the estimate changed.
nonisolated public enum DiffTextBuilder {
    /// The most lines to lay out ahead of time. It takes about 15 microseconds
    /// a line, so this many take about 0.8 seconds. It's more than the longest
    /// patch of a file in a release of Linux, which has 40,325 lines. A longer
    /// patch shows at once, and lays out as it's looked at, with an estimated
    /// height.
    static let wholeLayoutLimit = 50_000

    /// The most UTF-8 bytes to show of a line. Drawing a line takes time for
    /// all of it, even the part out of view, so a window of lines as long as
    /// minified code has took up to a second to draw each time the text moved.
    static let lineLimit = 10_000

    /// How many characters to lay out between checks for cancellation.
    private static let layoutStep = 1 << 18

    @concurrent
    public static func document(for patch: FilePatch) async -> DiffDocument {
        build(patch)
    }

    /// Only hunk headers and git's remarks differ from the text's attributes,
    /// and the layout manager draws the lines' backgrounds and the changed
    /// words, so most of a long patch costs no attributes.
    static func build(_ patch: FilePatch, conflicts: ConflictLayout? = nil) -> DiffDocument {
        var utf8: [UInt8] = []
        utf8.reserveCapacity(patch.bytes.count)
        var lineStarts: [Int] = []
        lineStarts.reserveCapacity(patch.lines.count)
        var length = 0
        var columns = 0
        var secondary: [NSRange] = []

        for line in patch.lines {
            lineStarts.append(length)
            let start = length
            let (bytes, isCut) = shownBytes(of: patch.bytes[line.text])
            if let plainColumns = plainColumns(of: bytes) {
                utf8.append(contentsOf: bytes)
                length += bytes.count
                columns = max(columns, plainColumns)
            } else {
                let shown = shownText(of: bytes)
                utf8.append(contentsOf: shown.utf8)
                length += shown.utf16.count
                columns = max(columns, estimatedColumns(of: shown))
            }
            if line.kind == .hunkHeader || line.kind == .noNewline {
                secondary.append(NSRange(location: start, length: length - start))
            }
            if isCut {
                let shownLength = length
                utf8.append(contentsOf: cutLineNote.utf8)
                length += cutLineNote.utf16.count
                columns = max(columns, length - start)
                secondary.append(NSRange(location: shownLength, length: length - shownLength))
            }
            utf8.append(0x0A)
            length += 1
        }

        let string = String(decoding: utf8, as: UTF8.self)
        let text = NSMutableAttributedString(string: string, attributes: [
            .font: DiffStyle.font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: DiffStyle.paragraph,
        ])
        for range in secondary {
            text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        }
        if let conflicts {
            let bold = NSFont.monospacedSystemFont(ofSize: DiffStyle.font.pointSize, weight: .semibold)
            for (index, row) in conflicts.rows.enumerated() {
                guard let row, let color = ConflictLayout.textColor(row) else { continue }
                let end = index + 1 < lineStarts.count ? lineStarts[index + 1] - 1 : length - 1
                let range = NSRange(location: lineStarts[index], length: end - lineStarts[index])
                text.addAttribute(.foregroundColor, value: color, range: range)
                switch row {
                case .band(_, false, _), .label(.ours), .label(.theirs): text.addAttribute(.font, value: bold, range: range)
                default: break
                }
            }
        }
        // A conflicted file's sides aren't a change from one to the other.
        let changedWords = conflicts == nil && patch.lines.count <= wholeLayoutLimit
            ? ChangedWords.ranges(in: Array(string.utf16), lines: patch.lines, lineStarts: lineStarts)
            : []
        let document = DiffDocument(text: text, lines: patch.lines, lineStarts: lineStarts, columns: columns, changedWords: changedWords, conflicts: conflicts)
        if patch.lines.count <= wholeLayoutLimit {
            var laidOut = 0
            while laidOut < length, !Task.isCancelled {
                laidOut = min(laidOut + layoutStep, length)
                document.layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: laidOut))
            }
        }
        return document
    }

    private static let cutLineNote = " … This line is too long to show the rest."

    /// The part of a line to show, which is all of it unless it's very long.
    private static func shownBytes(of bytes: ArraySlice<UInt8>) -> (bytes: ArraySlice<UInt8>, isCut: Bool) {
        guard bytes.count > lineLimit else { return (bytes, false) }
        var end = bytes.startIndex + lineLimit
        // Don't stop in the middle of a character, if it's in UTF-8.
        while end > bytes.startIndex, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return (bytes[..<end], true)
    }

    /// How many columns a line of printable ASCII and tabs takes, or nil if it
    /// has anything else, which takes more care to show. Nearly every line of
    /// code is this kind.
    private static func plainColumns(of bytes: ArraySlice<UInt8>) -> Int? {
        var columns = 0
        for byte in bytes {
            if byte == 0x09 {
                columns += DiffStyle.tabWidth - columns % DiffStyle.tabWidth
            } else if byte >= 0x20, byte < 0x7F {
                columns += 1
            } else {
                return nil
            }
        }
        return columns
    }

    /// The text to show for a line that isn't plain ASCII.
    ///
    /// A file that isn't UTF-8 is probably in Latin-1, which any bytes are
    /// valid in. Control characters, and the ones that end a line, would break
    /// the rule of one row per line, so they show as symbols. A form feed, which
    /// old C code has, would even end the text container. A carriage return at
    /// the end of a line stays, because with the newline after it, it ends the
    /// row like a newline does, and it's still there when the text is copied.
    private static func shownText(of bytes: ArraySlice<UInt8>) -> String {
        let text = String(validating: bytes, as: UTF8.self)
            ?? String(bytes: bytes, encoding: .isoLatin1)
            ?? String(decoding: bytes, as: UTF8.self)
        var scalars = String.UnicodeScalarView()
        let last = text.unicodeScalars.indices.last
        for index in text.unicodeScalars.indices {
            let scalar = text.unicodeScalars[index]
            switch scalar.value {
            case 0x09:
                scalars.append(scalar)
            case 0x0D where index == last:
                scalars.append(scalar)
            case 0..<0x20:
                scalars.append(Unicode.Scalar(0x2400 + scalar.value)!)
            case 0x7F:
                scalars.append("\u{2421}")
            case 0x85, 0x2028, 0x2029:
                scalars.append("\u{2424}")
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Counts a character outside ASCII as two columns, which is the most that
    /// fonts usually take, so that the end of a long line isn't cut off.
    private static func estimatedColumns(of text: String) -> Int {
        var columns = 0
        for scalar in text.unicodeScalars {
            if scalar == "\t" {
                columns += DiffStyle.tabWidth - columns % DiffStyle.tabWidth
            } else {
                columns += scalar.isASCII ? 1 : 2
            }
        }
        return columns
    }
}
