/// Reads the refs that `git for-each-ref` lists with `format`.
public enum RefListParser {
    /// The format to pass to `git for-each-ref --format`. Each ref is a line,
    /// and its fields are separated by NUL bytes: the name, the object, `*`
    /// for the branch `HEAD` points to, and the target of a symbolic ref. Ref
    /// names can't contain line breaks or NUL bytes.
    ///
    /// It leaves out what annotated tags lead to, because asking for that
    /// makes git read every ref's object from the pack. `ShowRefParser` reads
    /// it from `git show-ref -d` instead, which uses what git recorded when it
    /// packed the refs.
    public static let format = "%(refname)%00%(objectname)%00%(HEAD)%00%(symref)"

    public struct Result: Sendable, Hashable {
        /// The refs, which lead to their targets until what annotated tags
        /// lead to is filled in.
        public var refs: [Ref]
        /// The full name of the branch `HEAD` points to, if git marked one.
        public var currentBranch: String?
    }

    public static func parse(_ output: [UInt8]) throws(ParseError) -> Result {
        var result = Result(refs: [], currentBranch: nil)
        for line in output.split(separator: UInt8(ascii: "\n")) {
            let fields = line.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 4 else {
                throw ParseError("git for-each-ref printed a line with \(fields.count) fields instead of 4.")
            }
            let name = String(decoding: fields[0], as: UTF8.self)
            guard let target = ObjectID(hexDigits: fields[1]) else {
                throw ParseError("git for-each-ref printed \(name) without an object ID.")
            }
            let symbolicTarget = fields[3].isEmpty ? nil : String(decoding: fields[3], as: UTF8.self)
            result.refs.append(Ref(name: name, target: target, symbolicTarget: symbolicTarget))
            if fields[2].elementsEqual("*".utf8) {
                result.currentBranch = name
            }
        }
        return result
    }
}
