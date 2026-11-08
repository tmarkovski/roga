import DiffUI
import GitCore
import RepositoryEngine

/// Names the two sides of a file's conflicts by where they came from, from the
/// labels git wrote after its markers (decision 60). git calls them ours and
/// theirs, but in a rebase or a stash pop ours is what's coming in, so Roga says
/// `origin/main`, `a17f9d3`, `the revert` or `your changes` instead.
///
/// What git writes after the markers:
///
/// | What stopped | Ours | Theirs |
/// | --- | --- | --- |
/// | `git merge origin/main` | `HEAD` | `origin/main` |
/// | `git pull` that merges | `HEAD` | the commit's full hash |
/// | `git rebase`, `git pull --rebase` | `HEAD`, which is what it's going onto | `a17f9d3 (Add a retry button)` |
/// | `git revert 86b3386` | `HEAD` | `parent of 86b3386 (Show the error)` |
/// | `git cherry-pick a17f9d3` | `HEAD` | `a17f9d3 (Add a retry button)` |
/// | `git stash pop` | `Updated upstream` | `Stashed changes` |
struct ConflictNaming {
    /// The short name of the branch `HEAD` is on, or nil when it's detached.
    var branch: String?
    /// The commit `HEAD` is on.
    var head: ObjectID?
    /// What the worktree is partway through, if anything.
    var work: StoppedWork?
    /// The commit a rebase is putting commits onto.
    var onto: ObjectID?
    /// Every ref, for naming a commit that a label gives only the hash of.
    var refs: [Ref] = []
    /// The full name of the current branch's upstream, which comes first when
    /// several refs point at a commit.
    var upstream: String?
    /// The subjects of the commits above, as far as they're known.
    var subjects: [ObjectID: String] = [:]

    /// The commits whose subjects say more about the sides.
    func commitsToDescribe(oursLabel: String, theirsLabel: String) -> [ObjectID] {
        var ids = [head, onto].compactMap(\.self)
        if let id = ObjectID(hex: theirsLabel) ?? ObjectID(hex: theirsLabel.dropFirst("parent of ".count)) { ids.append(id) }
        if let ref = ref(named: theirsLabel) { ids.append(ref.peeled) }
        return ids
    }

    func sides(oursLabel: String, theirsLabel: String) -> ConflictSides {
        ConflictSides(ours: ours(oursLabel), theirs: theirs(theirsLabel))
    }

    private func ours(_ label: String) -> ConflictSides.Side {
        guard label == "HEAD" || label == "Updated upstream" else { return named(label, detail: "") }
        if case .rebase = work, let onto {
            let name = refName(at: onto) ?? Self.short(onto)
            let detail = head == onto
                ? describe(onto)
                : "\(Self.short(onto)) and the commits rebased onto it so far"
            return named(name, detail: detail)
        }
        let name = branch ?? "HEAD"
        let detail = head.map(describe) ?? ""
        return named(name, detail: label == "Updated upstream" && !detail.isEmpty ? "as committed, \(detail)" : detail)
    }

    private func theirs(_ label: String) -> ConflictSides.Side {
        if label == "Stashed changes" {
            return ConflictSides.Side(name: "Your changes", detail: "from the stash", keepTitle: "Keep Yours", keptTitle: "Kept yours")
        }
        if label.hasPrefix("parent of ") {
            let reverted = String(label.dropFirst("parent of ".count))
            let commit = Self.commitLabel(reverted).map { "\($0.hash) · \($0.subject)" } ?? ObjectID(hex: reverted).map(describe) ?? reverted
            return ConflictSides.Side(name: "The revert", detail: "taking out \(commit)", keepTitle: "Keep the Revert", keptTitle: "Kept the revert")
        }
        if let commit = Self.commitLabel(label) {
            let detail = if case .rebase = work { "your commit being rebased · \(commit.subject)" } else { commit.subject }
            return named(commit.hash, detail: detail)
        }
        if let id = ObjectID(hex: label) {
            return named(refName(at: id) ?? Self.short(id), detail: describe(id))
        }
        return named(label, detail: ref(named: label).map { describe($0.peeled) } ?? "")
    }

    private func named(_ name: String, detail: String) -> ConflictSides.Side {
        ConflictSides.Side(name: name, detail: detail, keepTitle: "Keep \(name)'s", keptTitle: "Kept \(name)'s")
    }

    /// A commit's short hash and subject, or only the hash when its subject isn't known.
    private func describe(_ id: ObjectID) -> String {
        subjects[id].map { "\(Self.short(id)) · \($0)" } ?? Self.short(id)
    }

    /// The branch or remote branch at a commit, preferring the upstream, then
    /// remote branches, because a pull merges what came from the remote.
    private func refName(at id: ObjectID) -> String? {
        let candidates = refs.filter { ($0.kind == .branch || $0.kind == .remoteBranch) && $0.symbolicTarget == nil && $0.peeled == id }
        let best = candidates.first { $0.name == upstream }
            ?? candidates.first { $0.kind == .remoteBranch }
            ?? candidates.first
        return best?.shortName
    }

    /// The branch, remote branch or tag a label names, such as `origin/main`.
    private func ref(named label: String) -> Ref? {
        refs.first { $0.symbolicTarget == nil && ($0.shortName == label || $0.name == label) }
    }

    /// The hash and subject of a label like `a17f9d3 (Add a retry button)`.
    static func commitLabel(_ label: String) -> (hash: String, subject: String)? {
        guard let space = label.firstIndex(of: " ") else { return nil }
        let hash = label[..<space]
        let rest = label[label.index(after: space)...]
        guard hash.count >= 4, hash.allSatisfy(\.isHexDigit), rest.hasPrefix("("), rest.hasSuffix(")") else { return nil }
        return (String(hash), String(rest.dropFirst().dropLast()))
    }

    static func short(_ id: ObjectID) -> String {
        String(id.hex.prefix(7))
    }
}
