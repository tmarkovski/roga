/// Reads the refs that `git for-each-ref` lists with `format`.
public enum RefListParser {
    /// The format to pass to `git for-each-ref --format`. Each ref is a line,
    /// and its fields are separated by NUL bytes: the name, the object, the
    /// object's type, the commit or other object an annotated tag leads to and
    /// its type, `*` for the branch `HEAD` points to, and the target of a
    /// symbolic ref. Ref names can't contain line breaks or NUL bytes.
    public static let format = "%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)%00%(HEAD)%00%(symref)"

    public struct Result: Sendable, Hashable {
        public var refs: [Ref]
        /// The full name of the branch `HEAD` points to, if git marked one.
        public var currentBranch: String?
    }

    public static func parse(_ output: [UInt8]) throws(ParseError) -> Result {
        var result = Result(refs: [], currentBranch: nil)
        for line in output.split(separator: UInt8(ascii: "\n")) {
            let fields = line.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 7 else {
                throw ParseError("git for-each-ref printed a line with \(fields.count) fields instead of 7.")
            }
            let name = String(decoding: fields[0], as: UTF8.self)
            guard let target = ObjectID(hexDigits: fields[1]) else {
                throw ParseError("git for-each-ref printed \(name) without an object ID.")
            }
            let isCommit = fields[2].elementsEqual("commit".utf8)
            let leadsToCommit = fields[4].elementsEqual("commit".utf8)
            let commit = isCommit ? target : leadsToCommit ? ObjectID(hexDigits: fields[3]) : nil
            let symbolicTarget = fields[6].isEmpty ? nil : String(decoding: fields[6], as: UTF8.self)
            result.refs.append(Ref(name: name, target: target, commit: commit, symbolicTarget: symbolicTarget))
            if fields[5].elementsEqual("*".utf8) {
                result.currentBranch = name
            }
        }
        return result
    }
}
