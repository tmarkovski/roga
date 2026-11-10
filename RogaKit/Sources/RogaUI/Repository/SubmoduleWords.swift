import Foundation
import GitCore
import RepositoryEngine

/// What a submodule's row says in place of line counts: how its pointer moves
/// (decision 75).
nonisolated struct SubmoduleLabel: Equatable {
    /// What the row shows, as in `3 behind`.
    var text: String
    /// The same for VoiceOver and the row's tooltip, which have room to say what
    /// it's behind.
    var spoken: String
    /// Whether it's in the orange of uncommitted files, which a count of the
    /// submodule's own uncommitted files is.
    var isUncommitted = false
}

nonisolated extension DiffFile {
    /// What this row says about its submodule, or nil for any other file, and
    /// for a submodule that hasn't been read yet or has nothing to count. A
    /// row under Unstaged compares what's recorded with what's checked out, and
    /// every other row compares two commits that are recorded.
    var submoduleLabel: SubmoduleLabel? {
        guard isSubmodule, let submodule else { return nil }
        guard let checkout = submodule.checkout, oldMode == Self.submoduleMode, newMode == Self.submoduleMode else {
            guard case .counted(let ahead, let behind) = submodule.distance else { return nil }
            switch (ahead, behind) {
            case (0, 0): return nil
            case (_, 0): return SubmoduleLabel(text: counted(ahead, "commit"), spoken: "\(counted(ahead, "commit")) forward")
            case (0, _): return SubmoduleLabel(text: "\(counted(behind, "commit")) back", spoken: "\(counted(behind, "commit")) back")
            default:
                return SubmoduleLabel(
                    text: "\(ahead.formatted()) forward, \(behind.formatted()) back",
                    spoken: "\(counted(ahead, "commit")) forward and \(behind.formatted()) back"
                )
            }
        }
        guard checkout.contains(.commitChanged) else {
            guard checkout.hasFilesInside else { return nil }
            // Status says there are some before anything has counted them.
            guard let files = submodule.filesInside else {
                return SubmoduleLabel(text: "files inside", spoken: "uncommitted files inside", isUncommitted: true)
            }
            return SubmoduleLabel(text: "\(counted(files, "file")) inside", spoken: "\(counted(files, "uncommitted file")) inside", isUncommitted: true)
        }
        switch submodule.distance {
        case .counted(let ahead, let behind):
            switch (ahead, behind) {
            case (0, 0): return nil
            case (_, 0): return SubmoduleLabel(text: counted(ahead, "new commit"), spoken: counted(ahead, "new commit"))
            case (0, _):
                return SubmoduleLabel(text: "\(behind.formatted()) behind", spoken: "\(counted(behind, "commit")) behind what's recorded")
            default:
                return SubmoduleLabel(
                    text: "\(ahead.formatted()) new, \(behind.formatted()) behind",
                    spoken: "\(counted(ahead, "new commit")), and \(behind.formatted()) behind what's recorded"
                )
            }
        case .commitMissing:
            return SubmoduleLabel(text: "not fetched", spoken: "the commit that's recorded isn't fetched")
        case .notCheckedOut, nil:
            return nil
        }
    }
}

nonisolated extension Submodule {
    /// What names its row in the refs panel among the rows of refs, which a
    /// ref's name can't be, since none has a colon in it.
    var refsRow: String {
        "submodule:" + path
    }

    /// The second line of its row in the refs panel: the short hash that's
    /// checked out and where that stands against what the worktree records, as
    /// in `52e8a1b0 · 3 behind what's recorded` (decision 75). Until its own
    /// repository has been read, which follows the list, it's the hash alone.
    /// One that isn't checked out in the worktree has no hash to show.
    var subtitle: String {
        guard let checkedOut else { return "not checked out" }
        return ([short(checkedOut)] + [standing].compactMap(\.self)).joined(separator: " · ")
    }

    /// Where the checkout stands, or nil until that's been read.
    var standing: String? {
        var parts: [String] = []
        switch change.distance {
        case nil:
            return nil
        case .notCheckedOut:
            return "not checked out"
        case .commitMissing:
            parts.append("recorded commit not fetched")
        case .counted(let ahead, let behind):
            switch (ahead, behind) {
            case (0, 0): break
            case (_, 0): parts.append(counted(ahead, "new commit"))
            case (0, _): parts.append("\(behind.formatted()) behind what's recorded")
            default: parts.append("\(ahead.formatted()) new, \(behind.formatted()) behind what's recorded")
            }
        }
        if let files = change.filesInside, files > 0 { parts.append(counted(files, "uncommitted file")) }
        return parts.isEmpty ? "as recorded" : parts.joined(separator: ", ")
    }

    /// What shows beside its name: how many commits the checkout has that
    /// aren't recorded, how many recorded ones it's missing, and how many
    /// uncommitted files it has. They're all zero until it's been read, and
    /// for one whose recorded commit isn't fetched, which nothing can count.
    var counts: (ahead: Int, behind: Int, files: Int) {
        var counts = (ahead: 0, behind: 0, files: change.filesInside ?? 0)
        if case .counted(let ahead, let behind) = change.distance { (counts.ahead, counts.behind) = (ahead, behind) }
        return counts
    }
}

/// A number and what it counts, as in `1 commit` and `3 commits`.
nonisolated private func counted(_ count: Int, _ noun: String) -> String {
    count == 1 ? "1 \(noun)" : "\(count.formatted()) \(noun)s"
}

nonisolated private func short(_ id: ObjectID) -> String {
    String(id.hex.prefix(8))
}

/// What the diff panel says about a submodule's row: a band over each list, as
/// a hunk has, the submodule's own commits or files under it, and a few
/// sentences about what the buttons would do (decision 75).
nonisolated struct SubmoduleReport: Equatable {
    struct Section: Equatable, Identifiable {
        var id: Int
        var band: String
        /// Whether the band says the pointer goes back, which shows in red.
        var goesBack = false
        var commits: [SubmoduleDetails.Commit] = []
        /// How many more commits there are than the list has.
        var moreCommits = 0
        var files: [SubmoduleDetails.File] = []
        /// How many more files there are than the list has.
        var moreFiles = 0
    }

    /// The most files of a submodule's own that the panel lists.
    static let fileLimit = 200

    var sections: [Section] = []
    /// What's said under the lists, a paragraph each.
    var notes: [String] = []

    /// - Parameters:
    ///   - details: What was read of the submodule.
    ///   - path: The submodule's path in the parent, which also names it.
    init(_ details: SubmoduleDetails, path: String) {
        let name = String(path.split(separator: "/").last ?? Substring(path))
        if details.comparesCheckout {
            describeCheckout(details, path: path, name: name)
        } else {
            describeRecorded(details, path: path, name: name)
        }
    }

    private mutating func add(
        _ band: String,
        goesBack: Bool = false,
        commits: [SubmoduleDetails.Commit] = [],
        of total: Int = 0,
        files: [SubmoduleDetails.File] = []
    ) {
        sections.append(Section(
            id: sections.count,
            band: band,
            goesBack: goesBack,
            commits: commits,
            moreCommits: max(0, total - commits.count),
            files: Array(files.prefix(Self.fileLimit)),
            moreFiles: max(0, files.count - Self.fileLimit)
        ))
    }

    /// A row whose two commits are both recorded: in a commit, a comparison or
    /// a stash, or under Staged.
    private mutating func describeRecorded(_ details: SubmoduleDetails, path: String, name: String) {
        guard let from = details.from, let to = details.to else {
            if let to = details.to {
                add("Added at \(short(to))")
            } else if let from = details.from {
                add("Removed · it was at \(short(from))")
            }
            return
        }
        let move = "\(short(from)) → \(short(to))"
        switch details.distance {
        case .notCheckedOut:
            add(move)
            notes.append("\(path) isn't checked out in this worktree, so its commits can't be listed.")
        case .commitMissing:
            add(move)
            notes.append("The copy of \(path) that's checked out in this worktree doesn't have both of these commits, so the commits between them can't be listed.")
        case .counted(let ahead, let behind):
            switch (ahead, behind) {
            case (0, 0):
                add(move)
            case (_, 0):
                add("\(move) · \(counted(ahead, "commit")) forward", commits: details.added, of: ahead)
            case (0, _):
                add("\(move) · \(counted(behind, "commit")) back", goesBack: true, commits: details.removed, of: behind)
                notes.append(behind == 1 ? "This commit isn't recorded any more." : "These \(behind.formatted()) commits aren't recorded any more.")
            default:
                add("\(move) · \(counted(ahead, "commit")) forward, \(behind.formatted()) back", goesBack: true, commits: details.added, of: ahead)
                add("\(counted(behind, "commit")) that \(behind == 1 ? "isn't" : "aren't") recorded any more", goesBack: true, commits: details.removed, of: behind)
            }
            if let note = Self.unpushedNote(details, ahead: ahead, name: name) { notes.append(note) }
        }
    }

    /// A row under Unstaged, which compares the commit that's recorded with the
    /// one checked out.
    private mutating func describeCheckout(_ details: SubmoduleDetails, path: String, name: String) {
        guard let recorded = details.from, let checkedOut = details.to else {
            if let recorded = details.from { add("\(short(recorded)) is recorded") }
            notes.append("\(path) isn't checked out in this worktree.")
            return
        }
        let files = details.filesInside
        let filesBand = "\(counted(files.count, "uncommitted file")) inside"
        var updates = false
        switch details.distance {
        case .counted(let ahead, let behind):
            switch (ahead, behind) {
            case (0, 0):
                if files.isEmpty {
                    add("Checked out at \(short(checkedOut)), as recorded")
                    notes.append("There's nothing to update or stage.")
                } else {
                    add("\(filesBand) · checked out at \(short(checkedOut)), as recorded", files: files)
                    notes.append("These are committed inside \(name) rather than in this repository, so there's nothing here to stage.")
                }
                return
            case (_, 0):
                add("Checked out at \(short(checkedOut)) · \(counted(ahead, "new commit")) since \(short(recorded))", commits: details.added, of: ahead)
                notes.append("Stage records \(short(checkedOut)).")
            case (0, _):
                add("Checked out at \(short(checkedOut)) · \(counted(behind, "commit")) behind what's recorded", commits: details.removed, of: behind)
                let these = behind == 1 ? "this commit" : "these \(behind.formatted()) commits"
                notes.append("Update checks out \(short(recorded)), which is what's recorded. Staging the row instead would record \(short(checkedOut)), without \(these).")
                updates = true
            default:
                add(
                    "Checked out at \(short(checkedOut)) · \(counted(ahead, "new commit")), and \(behind.formatted()) behind what's recorded",
                    commits: details.added, of: ahead
                )
                add("\(counted(behind, "commit")) recorded that the checkout is missing", commits: details.removed, of: behind)
                let new = ahead == 1 ? "the new commit" : "the \(ahead.formatted()) new commits"
                notes.append("Updating would check out \(short(recorded)), without \(new), and staging would record \(short(checkedOut)), without the other \(behind.formatted()). To keep both, merge or rebase inside \(name) first.")
                updates = true
            }
            if let note = Self.unpushedNote(details, ahead: ahead, name: name) { notes.append(note) }
        case .commitMissing:
            add("Checked out at \(short(checkedOut)) · \(short(recorded)) is recorded, and this checkout doesn't have it yet")
            notes.append("Update fetches \(short(recorded)) and checks it out. Staging the row instead would record \(short(checkedOut)).")
            updates = true
        case .notCheckedOut:
            add("\(short(recorded)) is recorded")
            notes.append("\(path) isn't checked out in this worktree.")
            return
        }
        if !files.isEmpty {
            add(filesBand, files: files)
            notes.append(
                updates
                    ? "The uncommitted files are \(name)'s own. git won't update over one that's in the way."
                    : "The uncommitted files are \(name)'s own, and staging leaves them as they are."
            )
        }
    }

    /// What to say about new commits that none of the submodule's remote
    /// branches lead to, because a branch that records them can't be built by
    /// anyone else until they're pushed.
    private static func unpushedNote(_ details: SubmoduleDetails, ahead: Int, name: String) -> String? {
        guard let unpushed = details.unpushed, unpushed > 0, ahead > 0 else { return nil }
        let which: String
        if unpushed < ahead {
            which = "\(unpushed.formatted()) of these commits \(unpushed == 1 ? "isn't" : "aren't")"
        } else {
            switch ahead {
            case 1: which = "This commit isn't"
            case 2: which = "Neither commit is"
            default: which = "None of these commits is"
            }
        }
        return "\(which) on any of \(name)'s remotes yet, so push \(name) before this branch."
    }
}

nonisolated enum SubmoduleWords {
    /// What the title row says about the submodules that staging everything left
    /// out, and why, or nil when it left none (decision 75). It starts in lower
    /// case, to go after what else happened. It's short, because the title row
    /// cuts the repository's and the branch's names short to make room for it.
    static func leftOut(_ files: [DiffFile]) -> String? {
        guard let first = files.first else { return nil }
        guard files.count == 1 else {
            return "left out \(files.count.formatted()) submodules that are behind"
        }
        let why: String
        switch first.submodule?.distance {
        case .counted(_, let behind): why = "which is \(counted(behind, "commit")) behind"
        case .commitMissing: why = "whose recorded commit isn't fetched"
        case .notCheckedOut, nil: why = "which couldn't be read"
        }
        return "left out \(first.path), \(why)"
    }

    /// What staging left out, as a sentence of its own, for when nothing else
    /// happened that the title row says first.
    static func leftOutSentence(_ files: [DiffFile]) -> String? {
        leftOut(files).map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    /// What Update does, and the exact command, for its tooltip.
    @MainActor
    static func updateHelp(_ file: DiffFile) -> String {
        "Check out the commit that's recorded for \(file.name)\n" + ShellCommand.text(RepositorySession.updateSubmoduleArguments(file.path))
    }
}
