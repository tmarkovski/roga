import DiffUI
import GitCore

/// What's been resolved in each of a worktree's conflicted files from the diff
/// panel, so that each choice can be undone (decision 60). A file is kept as it was
/// first read, with every conflict, and the choices made since. What's on disk is
/// always that file with those choices, and when it isn't, because an editor or an
/// agent wrote to it meanwhile, the file on disk becomes the new starting point.
///
/// Like a discard's Undo (decision 39), this lasts until Roga quits, or until the
/// file is marked resolved.
final class ConflictResolution {
    struct Progress: Equatable {
        /// The file as first read.
        var original: ConflictedFile
        /// How each resolved conflict was resolved, by its index.
        var choices: [Int: ConflictedFile.Choice] = [:]
        /// Who wrote the lines some conflicts kept, such as an agent, by index.
        var writtenBy: [Int: String] = [:]
        /// The resolved conflicts that show their sides under what they kept.
        var shownSides: Set<Int> = []

        /// What the file has with these choices, which is what's on disk.
        var current: [UInt8] { original.resolving(choices) }
        /// How many conflicts are left.
        var left: Int { original.conflicts.count - choices.count }
    }

    private var files: [String: Progress] = [:]

    /// What's been resolved in a file, given what's on disk now, or nil when the
    /// file has no conflicts and nothing was resolved here.
    func progress(of path: String, onDisk file: ConflictedFile) -> Progress? {
        if let known = files[path], known.current == file.bytes { return known }
        guard file.hasConflicts else {
            files[path] = nil
            return nil
        }
        let progress = Progress(original: file)
        files[path] = progress
        return progress
    }

    /// What's been resolved in a file, as last read or written.
    func progress(of path: String) -> Progress? {
        files[path]
    }

    func remember(_ progress: Progress, for path: String) {
        files[path] = progress
    }

    /// Forgets a file, once it's marked resolved or one side's version took its place.
    func forget(_ path: String) {
        files[path] = nil
    }
}

/// How far a conflicted file showing in the diff panel has got, for its header.
struct ConflictSummary: Equatable {
    /// How many conflicts it had when first read, or 0 for a file without markers,
    /// such as a binary file or one that a side deleted.
    var total: Int
    /// How many are left.
    var left: Int
    /// What the sides are called.
    var sides: ConflictSides
}
