import AppKit
import GitCore
import ThemeUI

/// How diffs look, whatever font they're in. What depends on the font, such as
/// how tall a row is, is in `DiffMetrics`.
nonisolated enum DiffStyle {
    /// How many columns a tab reaches, as in a terminal.
    static let tabWidth = 8

    /// The space before and after the text, which is inside the text's lines,
    /// so that their backgrounds cover it.
    static let textPadding: CGFloat = 6

    // A changed line's tints are the color theme's (decision 71). They follow
    // the theme as they're drawn, so a document built in one theme shows in another.
    private static let addedBackground = ColorTheme.following(alpha: 0.14, \.diffAdded)
    private static let removedBackground = ColorTheme.following(alpha: 0.14, \.diffRemoved)
    private static let addedWordBackground = ColorTheme.following(alpha: 0.28, \.diffAdded)
    private static let removedWordBackground = ColorTheme.following(alpha: 0.28, \.diffRemoved)
    /// The bar beside an added line.
    static let addedBar = ColorTheme.following(\.diffAdded)
    /// The stripes beside a removed line.
    static let removedBar = ColorTheme.following(\.diffRemoved)

    static func background(_ kind: FilePatch.Line.Kind) -> NSColor? {
        switch kind {
        case .added: addedBackground
        case .removed: removedBackground
        case .hunkHeader: NSColor.systemBlue.withAlphaComponent(0.09)
        case .context, .noNewline: nil
        }
    }

    /// The fill behind the parts of a changed line that differ, over the line's
    /// background.
    static func changedWordBackground(_ kind: FilePatch.Line.Kind) -> NSColor? {
        switch kind {
        case .added: addedWordBackground
        case .removed: removedWordBackground
        case .hunkHeader, .context, .noNewline: nil
        }
    }

    static let changedWordCornerRadius: CGFloat = 3

    /// The fill behind the text being searched for.
    static var matchBackground: NSColor { NSColor.systemYellow.withAlphaComponent(0.3) }
    /// The fill behind the match that the search is at.
    static var currentMatchBackground: NSColor { NSColor.systemOrange.withAlphaComponent(0.65) }
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
    /// Whether this shows a patch's hunks or the whole file (decision 74).
    public let layout: DiffLayout
    /// The first row that's a changed line, which is where a whole file
    /// starts out, or nil when it has none.
    let firstChangedRow: Int?
    /// For a file with conflicts, what its rows are beyond lines of the file
    /// (decision 60), or nil for a patch.
    let conflicts: ConflictLayout?
    /// The conflicts' bands, in order.
    let conflictBands: [ConflictBand]
    /// Which rows each unresolved conflict takes up, from its band to its last side.
    let unresolvedConflictRows: [Range<Int>]
    /// The measures of the font the text is in, which is how tall its rows are
    /// and how wide its columns.
    let metrics: DiffMetrics

    /// The code font the document was built in. When another is chosen, the
    /// document is built again rather than changed (decision 73).
    public var font: CodeFont { metrics.codeFont }

    init(
        text: NSAttributedString,
        lines: [FilePatch.Line],
        lineStarts: [Int],
        columns: Int,
        changedWords: [NSRange],
        layout: DiffLayout = .hunks,
        conflicts: ConflictLayout? = nil,
        metrics: DiffMetrics
    ) {
        self.metrics = metrics
        self.layout = layout
        firstChangedRow = lines.firstIndex { $0.kind == .added || $0.kind == .removed }
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

    /// The first row at or after one that's a line of the file, rather than a
    /// hunk's header or git's remark, or else the last one before it.
    func fileRow(atOrAfter row: Int) -> Int? {
        func isOfFile(_ line: FilePatch.Line) -> Bool { line.kind != .hunkHeader && line.kind != .noNewline }
        let start = min(max(row, 0), lines.count)
        return lines[start...].firstIndex(where: isOfFile) ?? lines[..<start].lastIndex(where: isOfFile)
    }

    /// Where a line of the same diff in the other layout is in this one, for
    /// staying at the same place when the layout changes (decision 74). Every
    /// changed line is in both. A line that hunks leave out gives the header
    /// of the hunk that comes next, or of the last one.
    ///
    /// It goes through the rows, which takes about a millisecond for a
    /// million of them, and it only runs when someone changes the layout.
    func row(showing line: FilePatch.Line) -> (row: Int, isExact: Bool) {
        // A removed line is only in the old file, so it goes by that number.
        let number = line.newNumber ?? line.oldNumber ?? 0
        for (row, other) in lines.enumerated() where other.kind != .hunkHeader && other.kind != .noNewline {
            if other.kind == line.kind, other.oldNumber == line.oldNumber, other.newNumber == line.newNumber {
                return (row, true)
            }
            if let otherNumber = line.newNumber == nil ? other.oldNumber : other.newNumber, otherNumber > number {
                return (hunkHeader(atRow: row) ?? row, false)
            }
        }
        return (hunkHeaders.last ?? max(lines.count - 1, 0), false)
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

    /// - Parameters:
    ///   - layout: How to lay the patch out. For `inline`, the patch should
    ///     have every line of the file.
    ///   - font: The code font to build it in, which is the one in use unless
    ///     something else is asked for.
    @concurrent
    public static func document(for patch: FilePatch, layout: DiffLayout = .hunks, in font: CodeFont = .current) async -> DiffDocument {
        build(patch, layout: layout, metrics: .of(font))
    }

    /// Builds a patch of a few lines where it's called, such as the sample of a
    /// diff in Settings, which isn't worth a task and shouldn't show empty first.
    public static func document(forShort patch: FilePatch, in font: CodeFont = .current) -> DiffDocument {
        build(patch, metrics: .of(font))
    }

    /// Only hunk headers and git's remarks differ from the text's attributes,
    /// and the layout manager draws the lines' backgrounds and the changed
    /// words, so most of a long patch costs no attributes.
    static func build(
        _ patch: FilePatch,
        layout: DiffLayout = .hunks,
        conflicts: ConflictLayout? = nil,
        metrics: DiffMetrics = .current
    ) -> DiffDocument {
        // A whole file comes as one hunk, whose header would only say that it
        // starts at line 1 (decision 74). A file that became another kind of
        // file comes as two, the old file and then the new one.
        let lines = layout == .inline ? patch.lines.filter { $0.kind != .hunkHeader } : patch.lines
        var utf8: [UInt8] = []
        utf8.reserveCapacity(patch.bytes.count)
        var lineStarts: [Int] = []
        lineStarts.reserveCapacity(lines.count)
        var length = 0
        var columns = 0
        var secondary: [NSRange] = []

        for line in lines {
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
            .font: metrics.font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: metrics.paragraph,
        ])
        for range in secondary {
            text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        }
        if let conflicts {
            let bold = metrics.boldFont
            for (index, row) in conflicts.rows.enumerated() {
                guard let row, let color = ConflictLayout.textColor(row) else { continue }
                let end = index + 1 < lineStarts.count ? lineStarts[index + 1] - 1 : length - 1
                let range = NSRange(location: lineStarts[index], length: end - lineStarts[index])
                text.addAttribute(.foregroundColor, value: color, range: range)
                switch row {
                case .label(.ours), .label(.theirs): text.addAttribute(.font, value: bold, range: range)
                default: break
                }
            }
        }
        // A conflicted file's sides aren't a change from one to the other.
        let changedWords = conflicts == nil && lines.count <= wholeLayoutLimit
            ? ChangedWords.ranges(in: Array(string.utf16), lines: lines, lineStarts: lineStarts)
            : []
        let document = DiffDocument(
            text: text, lines: lines, lineStarts: lineStarts, columns: columns, changedWords: changedWords,
            layout: layout, conflicts: conflicts, metrics: metrics
        )
        if lines.count <= wholeLayoutLimit {
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
