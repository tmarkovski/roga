import Foundation

/// Reads what `git diff-tree -p` prints. It keeps the hunks and skips the lines
/// that describe the file, which the caller knows from `RawDiffParser`. Those
/// lines are the only ones that depend on what git calls the two sides.
public enum PatchParser {
    public static let arguments = ["-p", "--no-color", "--no-ext-diff"]

    /// A file can have more than one section, because git shows a file that
    /// became another kind of file as one file deleted and another added.
    public static func parse(_ output: [UInt8]) throws(ParseError) -> FilePatch {
        var lines: [FilePatch.Line] = []
        var oldNumber = 0
        var newNumber = 0
        // How many of the current hunk's lines are still to come. Inside a
        // hunk, these say what a line is, because its text can look like
        // anything, such as a header.
        var oldLeft = 0
        var newLeft = 0

        try output.withUnsafeBufferPointer { (bytes: UnsafeBufferPointer<UInt8>) throws(ParseError) in
            guard let base = bytes.baseAddress else { return }
            var start = 0
            while start < bytes.count {
                let end = memchr(base + start, 0x0A, bytes.count - start).map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) - base } ?? bytes.count
                defer { start = end + 1 }
                let first = start < end ? bytes[start] : nil

                if first == UInt8(ascii: "\\") {
                    // It comes after the last line of a hunk too, so it's
                    // looked for before whether the hunk has ended. The text
                    // starts after the backslash and a space.
                    lines.append(.init(kind: .noNewline, text: min(start + 2, end)..<end))
                } else if oldLeft > 0 || newLeft > 0 {
                    switch first {
                    case UInt8(ascii: "+"):
                        guard newLeft > 0 else { throw tooManyLines(bytes, start..<end) }
                        lines.append(.init(kind: .added, newNumber: newNumber, text: start + 1..<end))
                        newNumber += 1
                        newLeft -= 1
                    case UInt8(ascii: "-"):
                        guard oldLeft > 0 else { throw tooManyLines(bytes, start..<end) }
                        lines.append(.init(kind: .removed, oldNumber: oldNumber, text: start + 1..<end))
                        oldNumber += 1
                        oldLeft -= 1
                    // With diff.suppressBlankEmpty, a blank line of context
                    // has no space in front of it.
                    case UInt8(ascii: " "), nil:
                        guard oldLeft > 0, newLeft > 0 else { throw tooManyLines(bytes, start..<end) }
                        lines.append(.init(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: min(start + 1, end)..<end))
                        oldNumber += 1
                        newNumber += 1
                        oldLeft -= 1
                        newLeft -= 1
                    default:
                        throw ParseError("git diff-tree printed a line yaga can't read in a hunk: \(text(bytes, start..<end).debugDescription)")
                    }
                } else if first == UInt8(ascii: "@") {
                    guard let hunk = hunk(bytes, start..<end) else {
                        throw ParseError("git diff-tree printed a hunk header yaga can't read: \(text(bytes, start..<end).debugDescription)")
                    }
                    (oldNumber, oldLeft, newNumber, newLeft) = hunk
                    lines.append(.init(kind: .hunkHeader, text: start..<end))
                }
            }
        }
        guard oldLeft == 0, newLeft == 0 else {
            throw ParseError("git diff-tree stopped in the middle of a hunk.")
        }
        return FilePatch(bytes: output, lines: lines)
    }

    /// Reads `@@ -12,5 +12,6 @@`, where a count of 1 can be left out.
    private static func hunk(_ bytes: UnsafeBufferPointer<UInt8>, _ line: Range<Int>) -> (old: Int, oldCount: Int, new: Int, newCount: Int)? {
        var position = line.lowerBound

        func skip(_ expected: String) -> Bool {
            for byte in expected.utf8 {
                guard position < line.upperBound, bytes[position] == byte else { return false }
                position += 1
            }
            return true
        }
        func number() -> Int? {
            let start = position
            var value = 0
            while position < line.upperBound, case let digit = bytes[position], digit >= 0x30, digit <= 0x39 {
                let (scaled, overflowed) = value.multipliedReportingOverflow(by: 10)
                guard !overflowed else { return nil }
                value = scaled + Int(digit - 0x30)
                position += 1
            }
            return position > start ? value : nil
        }
        func range() -> (start: Int, count: Int)? {
            guard let start = number() else { return nil }
            guard skip(",") else { return (start, 1) }
            return number().map { (start, $0) }
        }

        guard skip("@@ -"), let old = range(), skip(" +"), let new = range(), skip(" @@") else { return nil }
        return (old.start, old.count, new.start, new.count)
    }

    private static func tooManyLines(_ bytes: UnsafeBufferPointer<UInt8>, _ line: Range<Int>) -> ParseError {
        ParseError("git diff-tree printed more lines than a hunk's header said: \(text(bytes, line).debugDescription)")
    }

    private static func text(_ bytes: UnsafeBufferPointer<UInt8>, _ line: Range<Int>) -> String {
        String(decoding: bytes[line], as: UTF8.self)
    }
}
