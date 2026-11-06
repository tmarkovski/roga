/// How often Roga looks again at a worktree while changes on disk keep coming,
/// as during a build, a code generator or a long rebase. The first change is
/// looked at straight away. After that, each look waits until the one before it
/// is at least half a second behind, or twice as long as it took, whichever is
/// longer, so that git runs at most half the time. In a small repository that's
/// twice a second. On a worktree the size of Linux, where `git status` takes
/// about 370 ms, it's about once every 0.75 seconds.
enum ChangePacing {
    /// The shortest time from the start of one look to the start of the next.
    static let shortestGap = Duration.milliseconds(500)

    /// How long after a look started the next one may start.
    static func gap(afterLookFrom started: ContinuousClock.Instant, to finished: ContinuousClock.Instant) -> Duration {
        max(shortestGap, (finished - started) * 2)
    }

    /// Waits until the next look may start, after one that ran from `started`
    /// to `finished`.
    static func wait(afterLookFrom started: ContinuousClock.Instant, to finished: ContinuousClock.Instant) async {
        try? await Task.sleep(until: started + gap(afterLookFrom: started, to: finished), clock: .continuous)
    }
}
