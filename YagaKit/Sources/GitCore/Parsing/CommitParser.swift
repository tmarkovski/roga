import CoreFoundation
import Foundation

/// Reads commit objects, as `git cat-file` prints their contents.
public enum CommitParser {
    /// Parses the contents of the commit `id`. Names, emails and the message
    /// are converted to UTF-8 when the commit has an `encoding` header, as
    /// `git log` does.
    ///
    /// git accepts commits with damaged author lines, and so does this: a
    /// part it can't read is left empty or zero. A commit without a tree is
    /// an error, because it isn't a commit.
    public static func parse(_ contents: [UInt8], id: ObjectID) throws(ParseError) -> CommitInfo {
        var tree: ObjectID?
        var parents: [ObjectID] = []
        var author: ArraySlice<UInt8> = []
        var committer: ArraySlice<UInt8> = []
        var encoding: String.Encoding?

        // Headers end at the first empty line. A line that starts with a
        // space continues the header before it, as in a signature, and those
        // are skipped.
        var position = 0
        while position < contents.count {
            let end = contents[position...].firstIndex(of: newline) ?? contents.count
            let line = contents[position..<end]
            position = end + 1
            if line.isEmpty { break }
            guard let space = line.firstIndex(of: UInt8(ascii: " ")) else { continue }
            let value = line[(space + 1)...]
            switch String(decoding: line[..<space], as: UTF8.self) {
            case "tree":
                tree = ObjectID(hexDigits: value)
            case "parent":
                guard let parent = ObjectID(hexDigits: value) else {
                    throw ParseError("Commit \(id) has a parent line that isn't an object ID.")
                }
                parents.append(parent)
            case "author":
                author = value
            case "committer":
                committer = value
            case "encoding":
                encoding = Self.encoding(named: String(decoding: value, as: UTF8.self))
            default:
                break
            }
        }
        guard let tree else { throw ParseError("Object \(id) has no tree, so it isn't a commit.") }

        let message = position < contents.count ? contents[position...] : []
        return CommitInfo(
            id: id,
            tree: tree,
            parents: parents,
            author: signature(author, encoding: encoding),
            committer: signature(committer, encoding: encoding),
            message: decode(message, encoding: encoding)
        )
    }

    private static let newline = UInt8(ascii: "\n")

    /// Reads `Name <email> 1767225600 +0100`, the way git splits an ident:
    /// the email is between the first `<` and the `>` after it, and the time
    /// and its time zone follow.
    static func signature(_ line: ArraySlice<UInt8>, encoding: String.Encoding?) -> Signature {
        guard let open = line.firstIndex(of: UInt8(ascii: "<")),
              let close = line[open...].firstIndex(of: UInt8(ascii: ">"))
        else {
            return Signature(name: decode(line, encoding: encoding), email: "", time: 0, timeZoneOffset: 0)
        }
        let name = line[..<open].trimmingSpaces()
        let email = line[(open + 1)..<close]
        let date = line[(close + 1)...].split(separator: UInt8(ascii: " "))
        let time = date.first.flatMap { Int64(String(decoding: $0, as: UTF8.self)) } ?? 0
        let offset = date.dropFirst().first.map(timeZoneOffset) ?? 0
        return Signature(
            name: decode(name, encoding: encoding),
            email: decode(email, encoding: encoding),
            time: time,
            timeZoneOffset: offset
        )
    }

    /// Converts `+0130` to 5400 seconds, and anything else to 0.
    static func timeZoneOffset(_ text: ArraySlice<UInt8>) -> Int {
        guard text.count == 5, let sign = text.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-"),
              let digits = Int(String(decoding: text.dropFirst(), as: UTF8.self))
        else { return 0 }
        let seconds = (digits / 100) * 3600 + (digits % 100) * 60
        return sign == UInt8(ascii: "-") ? -seconds : seconds
    }

    /// The encoding an `encoding` header names, or nil for UTF-8 or a name
    /// macOS doesn't know.
    static func encoding(named name: String) -> String.Encoding? {
        let lowercased = name.lowercased()
        guard lowercased != "utf-8", lowercased != "utf8" else { return nil }
        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    /// Decodes text in `encoding`, or as UTF-8 when there's none or the bytes
    /// don't fit it, replacing anything that isn't valid UTF-8.
    static func decode(_ bytes: ArraySlice<UInt8>, encoding: String.Encoding?) -> String {
        if let encoding, let text = String(bytes: bytes, encoding: encoding) { return text }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension ArraySlice<UInt8> {
    fileprivate func trimmingSpaces() -> ArraySlice<UInt8> {
        var slice = self
        while slice.last == UInt8(ascii: " ") { slice.removeLast() }
        while slice.first == UInt8(ascii: " ") { slice.removeFirst() }
        return slice
    }
}
