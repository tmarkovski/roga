/// A file in a worktree with git's conflict markers in it, as a merge, a rebase, a
/// revert, a cherry-pick or a stash pop leaves it (decision 60). Each conflict has
/// the side git calls ours, which is `HEAD`, then what both started from when the
/// repository writes it, then the side git calls theirs:
///
/// ```text
/// <<<<<<< HEAD
/// ours
/// ||||||| 18f3a41
/// what both started from
/// =======
/// theirs
/// >>>>>>> origin/main
/// ```
///
/// The text stays in the file's own bytes, and everything here is ranges into them.
public struct ConflictedFile: Sendable, Hashable {
    /// One conflict, from the start of its first marker's line to the end of its
    /// last marker's line.
    public struct Conflict: Sendable, Hashable {
        /// The whole conflict, markers included, with the last marker's newline.
        public var range: Range<Int>
        /// The lines git calls ours, with their newlines.
        public var ours: Range<Int>
        /// What both sides started from, when the repository's
        /// `merge.conflictStyle` is `diff3` or `zdiff3`.
        public var base: Range<Int>?
        /// The lines git calls theirs, with their newlines.
        public var theirs: Range<Int>
        /// What follows each marker, such as `HEAD`, `origin/main`, or
        /// `parent of 86b3386 (Show the error)`.
        public var oursLabel: String
        public var baseLabel: String?
        public var theirsLabel: String
        /// The number of the line its first marker is on, from 1.
        public var line: Int
    }

    /// How a conflict is resolved.
    public enum Choice: Sendable, Hashable {
        /// The lines git calls ours.
        case ours
        /// The lines git calls theirs.
        case theirs
        /// Ours, then theirs.
        case both
        /// Lines written by hand, which end with a newline unless there are none.
        case lines([UInt8])
    }

    /// The file as it was read.
    public var bytes: [UInt8]
    /// The conflicts, in order.
    public var conflicts: [Conflict]

    public init(bytes: [UInt8], conflicts: [Conflict]) {
        self.bytes = bytes
        self.conflicts = conflicts
    }

    /// How many characters a marker has, unless a file's `conflict-marker-size`
    /// attribute says otherwise.
    public static let markerSize = 7

    /// Finds the conflicts in a file. Markers that don't make a whole conflict in
    /// order, such as a stray `=======` in a Markdown heading, are left as text.
    public static func parse(_ bytes: [UInt8]) -> ConflictedFile {
        var conflicts: [Conflict] = []
        var start = 0
        var lineNumber = 1
        // The conflict being read: where it and each part start, and their labels.
        var open: (start: Int, line: Int, size: Int, oursLabel: String, oursStart: Int)?
        var baseStart: (marker: Int, text: Int, label: String)?
        var separator: (marker: Int, text: Int)?

        while start < bytes.count {
            let newline = bytes[start...].firstIndex(of: 0x0A)
            let end = newline.map { $0 + 1 } ?? bytes.count
            let line = bytes[start..<(newline ?? bytes.count)]

            if let current = open {
                if separator == nil, baseStart == nil, let label = marker(line, of: 0x7C, size: current.size) {
                    baseStart = (start, end, label)
                } else if separator == nil, isSeparator(line, size: current.size) {
                    separator = (start, end)
                } else if let middle = separator, let label = marker(line, of: 0x3E, size: current.size) {
                    let oursEnd = baseStart?.marker ?? middle.marker
                    conflicts.append(Conflict(
                        range: current.start..<end,
                        ours: current.oursStart..<oursEnd,
                        base: baseStart.map { $0.text..<middle.marker },
                        theirs: middle.text..<start,
                        oursLabel: current.oursLabel,
                        baseLabel: baseStart?.label,
                        theirsLabel: label,
                        line: current.line
                    ))
                    open = nil
                    baseStart = nil
                    separator = nil
                } else if let size = openingSize(line), let label = marker(line, of: 0x3C, size: size) {
                    // A new conflict before this one ended means this one wasn't
                    // one, so start again from here.
                    open = (start, lineNumber, size, label, end)
                    baseStart = nil
                    separator = nil
                }
            } else if let size = openingSize(line), let label = marker(line, of: 0x3C, size: size) {
                open = (start, lineNumber, size, label, end)
            }
            start = end
            lineNumber += 1
        }
        return ConflictedFile(bytes: bytes, conflicts: conflicts)
    }

    /// How many `<` start a line, if it's enough for a marker.
    private static func openingSize(_ line: ArraySlice<UInt8>) -> Int? {
        let size = line.prefix { $0 == 0x3C }.count
        return size >= markerSize ? size : nil
    }

    /// The label of a marker made of `size` of a character, then a space or the
    /// line's end, or nil if the line isn't one. A carriage return before the
    /// newline isn't part of the label.
    private static func marker(_ line: ArraySlice<UInt8>, of character: UInt8, size: Int) -> String? {
        guard line.count >= size, line.prefix(size).allSatisfy({ $0 == character }) else { return nil }
        var rest = line.dropFirst(size)
        if rest.last == 0x0D { rest = rest.dropLast() }
        if rest.isEmpty { return "" }
        guard rest.first == 0x20 else { return nil }
        return String(decoding: rest.dropFirst(), as: UTF8.self)
    }

    private static func isSeparator(_ line: ArraySlice<UInt8>, size: Int) -> Bool {
        var line = line
        if line.last == 0x0D { line = line.dropLast() }
        return line.count == size && line.allSatisfy { $0 == 0x3D }
    }

    /// Whether the file has any conflicts left.
    public var hasConflicts: Bool { !conflicts.isEmpty }

    /// The lines a choice keeps for a conflict.
    public func lines(_ choice: Choice, for conflict: Conflict) -> [UInt8] {
        switch choice {
        case .ours: Array(bytes[conflict.ours])
        case .theirs: Array(bytes[conflict.theirs])
        case .both: Array(bytes[conflict.ours]) + Array(bytes[conflict.theirs])
        case .lines(let lines): lines
        }
    }

    /// The file with some of its conflicts resolved, by their index, and the rest
    /// left as they are.
    public func resolving(_ choices: [Int: Choice]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var position = 0
        for (index, conflict) in conflicts.enumerated() {
            guard let choice = choices[index] else { continue }
            result += bytes[position..<conflict.range.lowerBound]
            result += lines(choice, for: conflict)
            position = conflict.range.upperBound
        }
        result += bytes[position...]
        return result
    }

    /// Lines typed by hand, ending with a newline as every line between markers
    /// does, unless there are none.
    public static func lines(typed text: String) -> [UInt8] {
        var bytes = Array(text.utf8)
        if let last = bytes.last, last != 0x0A { bytes.append(0x0A) }
        return bytes
    }
}
