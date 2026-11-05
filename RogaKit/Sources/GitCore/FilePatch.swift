/// What a patch changes in a file: its hunks, line by line. The text stays in
/// one buffer, so that a long patch costs an array rather than a string for
/// every line.
public struct FilePatch: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            /// The line that starts a hunk, as in `@@ -1,3 +1,4 @@ func main()`.
            case hunkHeader
            case context
            case added
            case removed
            /// git's remark that the line before it has no newline.
            case noNewline
        }

        public var kind: Kind
        /// The line's number in the file before the change, or nil if it isn't
        /// in that file.
        public var oldNumber: Int?
        /// The line's number in the file after the change, or nil if it isn't
        /// in that file.
        public var newNumber: Int?
        /// Where its text is in `bytes`, without the `+`, `-` or space in front
        /// of it and without the newline.
        public var text: Range<Int>

        public init(kind: Kind, oldNumber: Int? = nil, newNumber: Int? = nil, text: Range<Int>) {
            self.kind = kind
            self.oldNumber = oldNumber
            self.newNumber = newNumber
            self.text = text
        }
    }

    /// What git printed.
    public var bytes: [UInt8]
    /// The lines of every hunk. It's empty when git has no lines to show, as
    /// for a binary file or a file whose mode is all that changed.
    public var lines: [Line]
    /// Whether git said the file is binary rather than comparing its lines.
    public var isBinary: Bool

    public init(bytes: [UInt8], lines: [Line], isBinary: Bool = false) {
        self.bytes = bytes
        self.lines = lines
        self.isBinary = isBinary
    }

    /// The text of a line.
    public func text(of line: Line) -> ArraySlice<UInt8> {
        bytes[line.text]
    }
}

/// One hunk of a file's patch, as a patch of its own. `git apply --reverse` reads it
/// to take the hunk out of the file, and `git apply` to put it back.
///
/// Its header says where the hunk's lines are in the file as it is now, on both sides.
/// git starts looking at one number and takes the first place that matches. In reverse
/// that's the old side's number, which is off by what the hunks above have added. Taken
/// as git printed it, a hunk could take out another one that made the same change.
public struct HunkPatch: Sendable, Hashable {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}

extension FilePatch {
    /// How many hunks the patch has.
    public var hunkCount: Int {
        lines.reduce(0) { $1.kind == .hunkHeader ? $0 + 1 : $0 }
    }

    /// One hunk as a patch of its own, or nil when the line isn't a hunk's header or
    /// the patch isn't about one file on both sides.
    ///
    /// Only the lines that say which file it is go along. A line about the file's
    /// mode would change the mode as well, and the mode isn't part of the hunk.
    ///
    /// - Parameter header: The index in `lines` of the hunk's header.
    public func hunk(at header: Int) -> HunkPatch? {
        guard lines.indices.contains(header), lines[header].kind == .hunkHeader,
              let description = fileDescription,
              let ranges = PatchParser.hunkRanges(of: lines[header].text, in: bytes)
        else { return nil }
        let next = lines[(header + 1)...].firstIndex { $0.kind == .hunkHeader } ?? lines.count
        let end = endOfLine(next - 1)
        let body = bytes[endOfLine(header)..<end]
        // How many lines come before the hunk, which is what a count of zero says
        // rather than where the lines start.
        let before = ranges.newCount == 0 ? ranges.new : ranges.new - 1
        let start = ranges.oldCount == 0 ? before : before + 1
        let placed = Array("@@ -\(start),\(ranges.oldCount) +\(ranges.new),\(ranges.newCount) @@\n".utf8)
        return HunkPatch(bytes: description + placed + body)
    }

    /// The lines that say which file the patch is about, or nil when git printed
    /// something else: a file that became another kind of file has two sections, and
    /// one that's new or gone has nothing on one side.
    private var fileDescription: [UInt8]? {
        guard let first = lines.firstIndex(where: { $0.kind == .hunkHeader }) else { return nil }
        // Anything between one hunk and the next is about another section.
        for index in lines.indices where index > first && lines[index].kind == .hunkHeader {
            guard endOfLine(index - 1) == lines[index].text.lowerBound else { return nil }
        }
        guard endOfLine(lines.count - 1) == bytes.count else { return nil }

        var kept: [UInt8] = []
        for line in bytes[..<lines[first].text.lowerBound].split(separator: 0x0A) {
            if line.starts(with: "--- /dev/null".utf8) || line.starts(with: "+++ /dev/null".utf8) { return nil }
            if line.starts(with: "diff --git ".utf8) || line.starts(with: "--- ".utf8) || line.starts(with: "+++ ".utf8) {
                kept += line
                kept.append(0x0A)
            }
        }
        return kept.isEmpty ? nil : kept
    }

    /// Where the next line starts, after a line's text and its newline.
    private func endOfLine(_ index: Int) -> Int {
        min(lines[index].text.upperBound + 1, bytes.count)
    }
}
