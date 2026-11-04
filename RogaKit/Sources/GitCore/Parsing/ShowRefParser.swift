/// Reads what `git show-ref --head --tags -d` prints: the commit `HEAD`
/// points to, every tag, and what each annotated tag leads to.
///
/// git records what annotated tags lead to when it packs refs, and
/// `show-ref -d` uses that rather than reading the tags, which `for-each-ref`
/// does. For Linux's 952 tags, that's the difference between reading no
/// objects and reading 48 MB of the pack from a cold disk cache.
public enum ShowRefParser {
    public static let arguments = ["show-ref", "--head", "--tags", "-d"]

    public struct Result: Sendable, Hashable {
        /// The commit `HEAD` points to, or nil when there's none yet.
        public var head: ObjectID?
        /// What each annotated tag leads to, by the tag's full name.
        public var peeled: [String: ObjectID]
    }

    /// Each line is an object ID, a space and a name. Ref names can't contain
    /// spaces or line breaks. A name that ends in `^{}` is what the tag before
    /// it leads to.
    public static func parse(_ output: [UInt8]) throws(ParseError) -> Result {
        var result = Result(head: nil, peeled: [:])
        for line in output.split(separator: UInt8(ascii: "\n")) {
            guard let space = line.firstIndex(of: UInt8(ascii: " ")),
                  let id = ObjectID(hexDigits: line[..<space])
            else {
                throw ParseError("git show-ref printed a line that doesn't start with an object ID.")
            }
            let name = String(decoding: line[(space + 1)...], as: UTF8.self)
            if name == "HEAD" {
                result.head = id
            } else if name.hasSuffix("^{}") {
                result.peeled[String(name.dropLast(3))] = id
            }
        }
        return result
    }
}
