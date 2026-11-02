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

    public init(bytes: [UInt8], lines: [Line]) {
        self.bytes = bytes
        self.lines = lines
    }

    /// The text of a line.
    public func text(of line: Line) -> ArraySlice<UInt8> {
        bytes[line.text]
    }
}
