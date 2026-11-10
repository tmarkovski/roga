import Darwin

/// The limit macOS puts on how many files Roga has open at once.
///
/// macOS starts an app with room for 256, and Roga keeps about a dozen open
/// for each repository in the sidebar: FSEvents holds every folder on the way
/// down to the repository, to notice when one is renamed, and `git cat-file`
/// has three pipes. Each git command then takes four to six while it starts.
/// With 17 repositories listed that left about 40, and a refresh that started
/// too many commands at once showed "Too many open files" in the refs panel.
/// About 20 repositories would have left no room to run git at all.
public nonisolated enum OpenFileLimit {
    /// The most Roga asks for, which is what `man setrlimit` says to ask
    /// macOS for when the hard limit is unlimited, as an app's is.
    static let most = rlim_t(OPEN_MAX)

    /// Raises the limit, which the app does as it starts, before it opens a
    /// repository. A limit that's already higher stays as it is, and so does
    /// one that macOS won't raise. The programs Roga starts, git among them,
    /// start with the same limit.
    ///
    /// - Returns: The limit afterwards, or nil when macOS wouldn't say what
    ///   it is.
    @discardableResult
    public static func raise() -> rlim_t? {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return nil }
        guard let target = target(soft: limit.rlim_cur, hard: limit.rlim_max) else { return limit.rlim_cur }
        var raised = limit
        raised.rlim_cur = target
        return setrlimit(RLIMIT_NOFILE, &raised) == 0 ? target : limit.rlim_cur
    }

    /// What to raise a limit of `soft` to when it can go as high as `hard`,
    /// or nil to leave it where it is.
    static func target(soft: rlim_t, hard: rlim_t) -> rlim_t? {
        let target = min(most, hard)
        return target > soft ? target : nil
    }
}
