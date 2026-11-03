/// A commit's author or committer, and when they wrote or committed it.
public struct Signature: Sendable, Hashable {
    public var name: String
    public var email: String
    /// Seconds since 1970.
    public var time: Int64
    /// The offset from UTC of the time zone the time was recorded in, in
    /// seconds, so +0100 is 3600.
    public var timeZoneOffset: Int

    public init(name: String, email: String, time: Int64, timeZoneOffset: Int) {
        self.name = name
        self.email = email
        self.time = time
        self.timeZoneOffset = timeZoneOffset
    }
}

/// What a commit object says: its tree, parents, author, committer and
/// message.
public struct CommitInfo: Sendable, Hashable {
    public var id: ObjectID
    public var tree: ObjectID
    public var parents: [ObjectID]
    public var author: Signature
    public var committer: Signature
    /// The whole message, converted to UTF-8 when the commit says it uses
    /// another encoding.
    public var message: String

    public init(
        id: ObjectID,
        tree: ObjectID,
        parents: [ObjectID],
        author: Signature,
        committer: Signature,
        message: String
    ) {
        self.id = id
        self.tree = tree
        self.parents = parents
        self.author = author
        self.committer = committer
        self.message = message
    }

    /// The first paragraph of the message on one line, the way
    /// `git log --format=%s` shows it: blank lines at the start are skipped,
    /// and the lines up to the next blank one are joined with spaces.
    public var subject: String {
        var lines: [Substring] = []
        for line in message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingSuffix(while: \.isWhitespace)
            if trimmed.isEmpty {
                if lines.isEmpty { continue }
                break
            }
            lines.append(trimmed)
        }
        return lines.joined(separator: " ")
    }

    /// What follows the subject, the way `git log --format=%b` shows it,
    /// without the blank lines at its end.
    public var body: String {
        let lines = message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let isBlank = { (line: Substring) in line.allSatisfy(\.isWhitespace) }
        guard let subject = lines.firstIndex(where: { !isBlank($0) }),
              let gap = lines[subject...].firstIndex(where: isBlank),
              let first = lines[gap...].firstIndex(where: { !isBlank($0) }),
              let last = lines.lastIndex(where: { !isBlank($0) })
        else { return "" }
        return lines[first...last].joined(separator: "\n")
    }

    /// The body on one line, for showing after the subject in a list: its lines
    /// joined with spaces, without the trailers at its end, such as
    /// `Signed-off-by`. It stops after about as much as a window could show, so
    /// that a long message doesn't cost anything to keep or to draw.
    public var bodyLine: String {
        var lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let lastParagraph = lines.lastIndex { $0.allSatisfy(\.isWhitespace) }.map { $0 + 1 } ?? 0
        if Self.areTrailers(lines[lastParagraph...]) { lines.removeSubrange(lastParagraph...) }

        var result = ""
        for line in lines {
            let text = line.trimmingPrefix(while: \.isWhitespace).trimmingSuffix(while: \.isWhitespace)
            guard !text.isEmpty else { continue }
            if !result.isEmpty { result += " " }
            result += text
            if result.utf8.count >= Self.bodyLineLimit { return String(result.prefix(Self.bodyLineLimit)) }
        }
        return result
    }

    private static let bodyLineLimit = 200

    /// Whether a paragraph is only trailers, as `git interpret-trailers` would
    /// read it: each line is `Token: value`, or carries on the one before it
    /// with an indent.
    private static func areTrailers(_ paragraph: ArraySlice<Substring>) -> Bool {
        guard let first = paragraph.first, isTrailer(first) else { return false }
        return paragraph.allSatisfy { $0.first?.isWhitespace == true || isTrailer($0) }
    }

    private static func isTrailer(_ line: Substring) -> Bool {
        guard let colon = line.firstIndex(of: ":"), colon > line.startIndex else { return false }
        return line[..<colon].allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            && line[line.index(after: colon)...].first == " "
    }
}

extension Substring {
    fileprivate func trimmingSuffix(while predicate: (Character) -> Bool) -> Substring {
        var end = endIndex
        while end > startIndex, predicate(self[index(before: end)]) {
            end = index(before: end)
        }
        return self[..<end]
    }
}
