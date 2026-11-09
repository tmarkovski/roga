/// Reads what `git diff-tree --stdin --numstat` prints for a list of commits,
/// a line at a time, and adds up the lines each commit added and removed.
///
/// Each commit git has something to say about starts with a line holding its
/// ID. After it comes a line for each file the commit changed: the lines
/// added, a tab, the lines removed, a tab and the path, with `-` for both
/// counts of a binary file. git prints nothing at all for a merge, unless it's
/// asked to, or for a commit that changed nothing.
public struct CommitLineCountsParser: Sendable {
    public static let arguments = ["--numstat"]

    /// The lines each commit added and removed, with all of its files
    /// together. A binary file adds no lines.
    public private(set) var counts: [ObjectID: DiffFile.LineCounts] = [:]
    private var commit: ObjectID?

    public init() {}

    /// Reads one line, without the newline that ends it. Without `-z`, git
    /// quotes a path that holds a newline, so a line never ends early.
    public mutating func read(_ line: ArraySlice<UInt8>) throws(ParseError) {
        guard !line.isEmpty else { return }
        guard let firstTab = line.firstIndex(of: UInt8(ascii: "\t")) else {
            guard let id = ObjectID(hexDigits: line) else { throw Self.unreadable(line) }
            commit = id
            counts[id] = DiffFile.LineCounts(added: 0, removed: 0)
            return
        }
        let rest = line[(firstTab + 1)...]
        guard let commit,
              let secondTab = rest.firstIndex(of: UInt8(ascii: "\t")),
              let added = Self.count(line[..<firstTab]),
              let removed = Self.count(rest[..<secondTab])
        else { throw Self.unreadable(line) }
        counts[commit, default: DiffFile.LineCounts(added: 0, removed: 0)].added += added
        counts[commit, default: DiffFile.LineCounts(added: 0, removed: 0)].removed += removed
    }

    /// A count of lines, which is 0 for a binary file's `-`.
    private static func count(_ digits: ArraySlice<UInt8>) -> Int? {
        if digits.elementsEqual([UInt8(ascii: "-")]) { return 0 }
        guard !digits.isEmpty, digits.count <= 18 else { return nil }
        var value = 0
        for digit in digits {
            guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(digit - UInt8(ascii: "0"))
        }
        return value
    }

    private static func unreadable(_ line: ArraySlice<UInt8>) -> ParseError {
        ParseError("git printed line counts Roga can't read: \(String(decoding: line, as: UTF8.self).debugDescription)")
    }
}
