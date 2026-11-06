/// Mending the links between a repository and its linked worktrees, which break
/// when a folder moves outside git.
///
/// Each linked worktree's `.git` file names its folder in the repository's git
/// directory, and that folder names the worktree's folder back. A linked
/// worktree that moves leaves the second link pointing where it was, so
/// `git worktree list` calls it prunable. The main worktree moving leaves every
/// first link pointing into a folder that's gone, so git fails in each of them
/// and lists none as prunable. `git worktree repair` mends both.
public enum WorktreeRepair {
    /// What mends a linked worktree that moved to `folder`. Without a folder, it
    /// mends every linked worktree that's still where git last saw it, which is
    /// what the main worktree moving breaks. It runs in the repository's git
    /// directory.
    public static func arguments(movedTo folder: String? = nil) -> [String] {
        ["worktree", "repair"] + (folder.map { [$0] } ?? [])
    }
}
