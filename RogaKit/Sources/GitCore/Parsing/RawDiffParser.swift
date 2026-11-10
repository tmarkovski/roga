/// Reads what `git diff-tree --raw --numstat -z` prints: a raw record for each
/// file, and then a numstat record for each file in the same order.
public enum RawDiffParser {
    public static let arguments = ["--raw", "--numstat", "-z"]

    /// A raw record is `:100644 100644 <old ID> <new ID> M`, then the path. A
    /// numstat record is the lines added, a tab, the lines removed, a tab and
    /// the path, with `-` for the counts of a binary file. Each field ends in
    /// a NUL byte. A renamed or copied file has two paths, in fields of their
    /// own, so its numstat record has none after the second tab. A path can
    /// hold any character but NUL.
    public static func parse(_ output: [UInt8]) throws(ParseError) -> [DiffFile] {
        // Every field ends in a NUL byte, so splitting leaves an empty piece
        // after the last one.
        var fields = output.split(separator: 0, omittingEmptySubsequences: false)[...]
        guard fields.removeLast().isEmpty else {
            throw ParseError("git diff-tree stopped in the middle of a field.")
        }

        var files: [DiffFile] = []
        while fields.first?.first == UInt8(ascii: ":") {
            files.append(try rawRecord(&fields))
        }
        for index in files.indices {
            guard let record = fields.popFirst() else {
                throw ParseError("git diff-tree listed \(files.count) files, but counted the lines of only \(index).")
            }
            try addLineCounts(record, to: &files[index], fields: &fields)
        }
        guard fields.isEmpty else {
            throw ParseError("git diff-tree printed more after the last file.")
        }
        return files
    }

    private static func rawRecord(_ fields: inout ArraySlice<ArraySlice<UInt8>>) throws(ParseError) -> DiffFile {
        let record = fields.removeFirst()
        let parts = record.dropFirst().split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
        guard parts.count == 5,
              let oldMode = UInt32(String(decoding: parts[0], as: UTF8.self), radix: 8),
              let newMode = UInt32(String(decoding: parts[1], as: UTF8.self), radix: 8),
              let oldID = ObjectID(hexDigits: parts[2]),
              let newID = ObjectID(hexDigits: parts[3]),
              let letter = parts[4].first
        else {
            throw ParseError("git diff-tree printed a record Roga can't read: \(text(record).debugDescription)")
        }

        // The digits after the letter say how similar a renamed or copied file is.
        let similarity = Int(String(decoding: parts[4].dropFirst(), as: UTF8.self)) ?? 0
        let status: DiffFile.Status
        switch letter {
        case UInt8(ascii: "A"): status = .added
        case UInt8(ascii: "D"): status = .deleted
        case UInt8(ascii: "M"): status = .modified
        case UInt8(ascii: "R"): status = .renamed(similarity: similarity)
        case UInt8(ascii: "C"): status = .copied(similarity: similarity)
        case UInt8(ascii: "T"): status = .typeChanged
        default: status = .other(text(parts[4].prefix(1)))
        }

        var oldPath: String?
        switch status {
        case .renamed, .copied: oldPath = try path(&fields)
        default: break
        }
        let isSubmodule = oldMode == DiffFile.submoduleMode || newMode == DiffFile.submoduleMode
        return DiffFile(
            status: status,
            path: try path(&fields),
            oldPath: oldPath,
            oldMode: oldMode,
            newMode: newMode,
            oldID: isZero(parts[2]) ? nil : oldID,
            newID: isZero(parts[3]) ? nil : newID,
            submodule: isSubmodule ? SubmoduleChange() : nil
        )
    }

    private static func addLineCounts(
        _ record: ArraySlice<UInt8>,
        to file: inout DiffFile,
        fields: inout ArraySlice<ArraySlice<UInt8>>
    ) throws(ParseError) {
        // Only the first two tabs separate anything, since a path can hold tabs.
        let parts = record.split(separator: UInt8(ascii: "\t"), maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw ParseError("git diff-tree printed line counts Roga can't read: \(text(record).debugDescription)")
        }
        if file.oldPath != nil {
            // A rename's paths are in the raw record too, so these just move past them.
            guard parts[2].isEmpty else {
                throw ParseError("git diff-tree printed one path for the rename of \(file.path.debugDescription).")
            }
            _ = try path(&fields)
            guard try path(&fields) == file.path else {
                throw ParseError("git diff-tree listed files in a different order when it counted their lines.")
            }
        } else if text(parts[2]) != file.path {
            throw ParseError("git diff-tree listed files in a different order when it counted their lines.")
        }
        // Binary files have `-` for both counts.
        guard parts[0].first != UInt8(ascii: "-") else { return }
        guard let added = Int(text(parts[0])), let removed = Int(text(parts[1])) else {
            throw ParseError("git diff-tree printed line counts Roga can't read: \(text(record).debugDescription)")
        }
        // git counts the `Subproject commit` lines of a submodule's patch, which
        // aren't lines of any file, and would add to a folder's counts.
        file.lines = file.isSubmodule ? DiffFile.LineCounts(added: 0, removed: 0) : DiffFile.LineCounts(added: added, removed: removed)
    }

    private static func path(_ fields: inout ArraySlice<ArraySlice<UInt8>>) throws(ParseError) -> String {
        guard let path = fields.popFirst(), !path.isEmpty else {
            throw ParseError("git diff-tree stopped before a file's path.")
        }
        return text(path)
    }

    private static func isZero(_ hexDigits: ArraySlice<UInt8>) -> Bool {
        hexDigits.allSatisfy { $0 == UInt8(ascii: "0") }
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
