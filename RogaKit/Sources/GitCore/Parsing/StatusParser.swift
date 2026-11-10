/// Reads what `git status --porcelain=v2 -z --branch` prints.
///
/// git's own list of what changed comes from here rather than from
/// `git diff-files`, which also lists a file that was only touched, because
/// nothing has told the index otherwise and Roga doesn't write the index.
public enum StatusParser {
    /// `--no-ahead-behind` leaves out counting how far the branch is from its
    /// upstream, which takes a while in a large repository and isn't used here.
    /// `--find-renames` overrides `status.renames`.
    public static let arguments = ["status", "--porcelain=v2", "-z", "--branch", "--no-ahead-behind", "--find-renames"]

    /// Each record ends in a NUL byte. They look like this, where `XY` are the
    /// letters for the file's staged and unstaged changes, with `.` for none,
    /// and the three modes and two IDs are for `HEAD`, the index and the
    /// worktree:
    ///
    ///     # branch.oid <commit>
    ///     1 XY <submodule> <mode> <mode> <mode> <id> <id> <path>
    ///     2 XY <submodule> <mode> <mode> <mode> <id> <id> R100 <path>
    ///     u XY <submodule> <mode> <mode> <mode> <mode> <id> <id> <id> <path>
    ///     ? <path>
    ///     ! <path>
    ///
    /// The record for a renamed file is followed by a field with its old path.
    /// A path can hold any character but NUL, including spaces.
    ///
    /// `<submodule>` is `N...` for anything else, and for a submodule it's `S`
    /// and then a `C` when its checkout is on another commit than the index
    /// records, an `M` when it has changes to tracked files and a `U` when it
    /// has untracked ones, with `.` for each that it hasn't (decision 75).
    public static func parse(_ output: [UInt8]) throws(ParseError) -> WorktreeChanges {
        var fields = output.split(separator: 0, omittingEmptySubsequences: false)[...]
        guard fields.removeLast().isEmpty else {
            throw ParseError("git status stopped in the middle of a field.")
        }

        var changes = WorktreeChanges()
        while let field = fields.popFirst() {
            switch field.first {
            case UInt8(ascii: "#"):
                try header(field, &changes)
            case UInt8(ascii: "1"):
                let parts = split(field, into: 9)
                guard parts.count == 9 else { throw unreadable(field) }
                try addTracked(parts, path: text(parts[8]), oldPath: nil, similarity: 0, field, &changes)
            case UInt8(ascii: "2"):
                let parts = split(field, into: 10)
                guard parts.count == 10, let oldPath = fields.popFirst() else { throw unreadable(field) }
                let similarity = Int(text(parts[8].dropFirst())) ?? 0
                try addTracked(parts, path: text(parts[9]), oldPath: text(oldPath), similarity: similarity, field, &changes)
            case UInt8(ascii: "u"):
                let parts = split(field, into: 11)
                guard parts.count == 11 else { throw unreadable(field) }
                changes.conflicted.append(uncounted(.conflicted, path: text(parts[10])))
                changes.fileCount += 1
            case UInt8(ascii: "?"):
                let parts = split(field, into: 2)
                guard parts.count == 2 else { throw unreadable(field) }
                changes.untracked.append(uncounted(.untracked, path: text(parts[1])))
                changes.fileCount += 1
            case UInt8(ascii: "!"):
                let parts = split(field, into: 2)
                guard parts.count == 2 else { throw unreadable(field) }
                changes.ignored.append(text(parts[1]))
            default:
                throw unreadable(field)
            }
        }
        return changes
    }

    /// `(initial)` is what git prints in place of the commit before there's one.
    private static func header(_ field: ArraySlice<UInt8>, _ changes: inout WorktreeChanges) throws(ParseError) {
        let parts = split(field, into: 3)
        guard parts.count == 3, text(parts[1]) == "branch.oid", text(parts[2]) != "(initial)" else { return }
        guard let head = ObjectID(hexDigits: parts[2]) else { throw unreadable(field) }
        changes.head = head
    }

    private static func addTracked(
        _ parts: [ArraySlice<UInt8>],
        path: String,
        oldPath: String?,
        similarity: Int,
        _ field: ArraySlice<UInt8>,
        _ changes: inout WorktreeChanges
    ) throws(ParseError) {
        guard parts[1].count == 2,
              let headMode = mode(parts[3]), let indexMode = mode(parts[4]), let worktreeMode = mode(parts[5]),
              ObjectID(hexDigits: parts[6]) != nil, ObjectID(hexDigits: parts[7]) != nil
        else { throw unreadable(field) }
        let staged = parts[1].first!
        let unstaged = parts[1].last!

        /// - Parameter checkout: What git says about the submodule's checkout,
        ///   which is about the worktree's side, so only an unstaged change has it.
        func file(
            _ letter: UInt8,
            oldMode: UInt32,
            newMode: UInt32,
            oldID: ArraySlice<UInt8>,
            newID: ArraySlice<UInt8>?,
            checkout: SubmoduleChange.Checkout? = nil
        ) -> DiffFile {
            let status = status(letter, similarity: similarity)
            var isMove = false
            switch status {
            case .renamed, .copied: isMove = true
            default: break
            }
            let isSubmodule = oldMode == DiffFile.submoduleMode || newMode == DiffFile.submoduleMode
            return DiffFile(
                status: status,
                path: path,
                oldPath: isMove ? oldPath : nil,
                oldMode: oldMode,
                newMode: newMode,
                oldID: id(oldID),
                newID: newID.flatMap(id),
                lines: DiffFile.LineCounts(added: 0, removed: 0),
                submodule: isSubmodule ? SubmoduleChange(checkout: checkout) : nil
            )
        }
        if staged != UInt8(ascii: ".") {
            changes.staged.append(file(staged, oldMode: headMode, newMode: indexMode, oldID: parts[6], newID: parts[7]))
        }
        if unstaged != UInt8(ascii: ".") {
            changes.unstaged.append(
                file(unstaged, oldMode: indexMode, newMode: worktreeMode, oldID: parts[7], newID: nil, checkout: checkout(parts[2]))
            )
        }
        changes.fileCount += 1
    }

    /// What the `<submodule>` field says about a submodule's checkout, or nil
    /// for something that isn't a submodule.
    private static func checkout(_ field: ArraySlice<UInt8>) -> SubmoduleChange.Checkout? {
        let letters = Array(field)
        guard letters.count == 4, letters[0] == UInt8(ascii: "S") else { return nil }
        var checkout: SubmoduleChange.Checkout = []
        if letters[1] == UInt8(ascii: "C") { checkout.insert(.commitChanged) }
        if letters[2] == UInt8(ascii: "M") { checkout.insert(.modifiedFiles) }
        if letters[3] == UInt8(ascii: "U") { checkout.insert(.untrackedFiles) }
        return checkout
    }

    /// An untracked or conflicted file, whose lines aren't counted. It has
    /// counts of zero rather than none, which would mean it's binary.
    private static func uncounted(_ status: DiffFile.Status, path: String) -> DiffFile {
        DiffFile(status: status, path: path, oldMode: 0, newMode: 0, lines: DiffFile.LineCounts(added: 0, removed: 0))
    }

    private static func status(_ letter: UInt8, similarity: Int) -> DiffFile.Status {
        switch letter {
        case UInt8(ascii: "A"): .added
        case UInt8(ascii: "D"): .deleted
        case UInt8(ascii: "M"): .modified
        case UInt8(ascii: "R"): .renamed(similarity: similarity)
        case UInt8(ascii: "C"): .copied(similarity: similarity)
        case UInt8(ascii: "T"): .typeChanged
        default: .other(String(decoding: [letter], as: UTF8.self))
        }
    }

    private static func mode(_ digits: ArraySlice<UInt8>) -> UInt32? {
        UInt32(text(digits), radix: 8)
    }

    /// The ID, or nil for the zeros that mean the file isn't on that side.
    private static func id(_ digits: ArraySlice<UInt8>) -> ObjectID? {
        digits.allSatisfy { $0 == UInt8(ascii: "0") } ? nil : ObjectID(hexDigits: digits)
    }

    /// Only the spaces before the last part separate anything, since a path
    /// can hold spaces.
    private static func split(_ field: ArraySlice<UInt8>, into count: Int) -> [ArraySlice<UInt8>] {
        field.split(separator: UInt8(ascii: " "), maxSplits: count - 1, omittingEmptySubsequences: false)
    }

    private static func unreadable(_ field: ArraySlice<UInt8>) -> ParseError {
        ParseError("git status printed a record Roga can't read: \(text(field).debugDescription)")
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

/// Reads what `git diff-index --numstat -z` and `git diff-files --numstat -z`
/// print: how many lines each file's diff adds and removes.
public enum NumstatParser {
    public static let arguments = ["--numstat", "-z"]

    /// A record is the lines added, a tab, the lines removed, a tab and the
    /// path, with `-` for the counts of a binary file. A renamed file has its
    /// two paths in fields of their own after the second tab. It returns the
    /// counts by the file's path after the change, which are nil for a binary
    /// file.
    public static func parse(_ output: [UInt8]) throws(ParseError) -> [String: DiffFile.LineCounts?] {
        var fields = output.split(separator: 0, omittingEmptySubsequences: false)[...]
        guard fields.removeLast().isEmpty else {
            throw ParseError("git stopped in the middle of counting lines.")
        }
        var counts: [String: DiffFile.LineCounts?] = [:]
        while let record = fields.popFirst() {
            let parts = record.split(separator: UInt8(ascii: "\t"), maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { throw unreadable(record) }
            var path = parts[2]
            if path.isEmpty {
                guard fields.popFirst() != nil, let newPath = fields.popFirst() else { throw unreadable(record) }
                path = newPath
            }
            if parts[0].first == UInt8(ascii: "-") {
                counts[text(path)] = .some(nil)
            } else {
                guard let added = Int(text(parts[0])), let removed = Int(text(parts[1])) else { throw unreadable(record) }
                counts[text(path)] = DiffFile.LineCounts(added: added, removed: removed)
            }
        }
        return counts
    }

    private static func unreadable(_ record: ArraySlice<UInt8>) -> ParseError {
        ParseError("git printed line counts Roga can't read: \(text(record).debugDescription)")
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
