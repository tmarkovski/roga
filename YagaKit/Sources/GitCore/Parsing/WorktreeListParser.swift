/// Reads what `git worktree list --porcelain -z` prints: the main worktree,
/// then each linked one.
public enum WorktreeListParser {
    public static let arguments = ["worktree", "list", "--porcelain", "-z"]

    /// Each worktree is a list of fields that end in NUL bytes, and an empty
    /// field ends the worktree. The first field is `worktree` and the path,
    /// which can hold any character but NUL. git adds fields from time to
    /// time, such as `locked` with a reason, and the ones yaga doesn't use are
    /// skipped.
    public static func parse(_ output: [UInt8]) throws(ParseError) -> [Worktree] {
        // Every field ends in a NUL byte, so splitting leaves an empty piece
        // after the last one.
        var fields = output.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.removeLast().isEmpty else {
            throw ParseError("git worktree list stopped in the middle of a field.")
        }
        var worktrees: [Worktree] = []
        var current: Worktree?
        for field in fields {
            if field.isEmpty {
                if let finished = current { worktrees.append(finished) }
                current = nil
                continue
            }
            let space = field.firstIndex(of: UInt8(ascii: " ")) ?? field.endIndex
            let name = String(decoding: field[..<space], as: UTF8.self)
            let value = space < field.endIndex ? field[(space + 1)...] : []
            guard current != nil else {
                guard name == "worktree", !value.isEmpty else {
                    throw ParseError("git worktree list printed \(name.debugDescription) before a worktree's path.")
                }
                current = Worktree(path: String(decoding: value, as: UTF8.self), isMain: worktrees.isEmpty)
                continue
            }
            switch name {
            case "HEAD":
                guard let id = ObjectID(hexDigits: value) else {
                    throw ParseError("git worktree list printed a HEAD that isn't an object ID.")
                }
                // A branch without commits yet shows as an ID of zeros.
                current?.head = value.allSatisfy { $0 == UInt8(ascii: "0") } ? nil : id
            case "branch":
                current?.branch = String(decoding: value, as: UTF8.self)
            case "bare":
                current?.isBare = true
            case "prunable":
                current?.isPrunable = true
            default:
                break
            }
        }
        guard current == nil else {
            throw ParseError("git worktree list stopped in the middle of a worktree.")
        }
        return worktrees
    }
}
