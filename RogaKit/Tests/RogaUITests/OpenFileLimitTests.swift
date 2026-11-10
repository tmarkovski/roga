import Darwin
import Testing
@testable import RogaUI

/// The limit on open files: what Roga raises it to, and that raising it never
/// lowers it.
struct OpenFileLimitTests {
    /// A hard limit of "unlimited", which is what an app starts with.
    static let unlimited = rlim_t(Int64.max)

    @Test func raisesTheLimitAnAppStartsWith() {
        #expect(OpenFileLimit.target(soft: 256, hard: Self.unlimited) == 10_240)
    }

    @Test func staysWithinTheHardLimit() {
        #expect(OpenFileLimit.target(soft: 256, hard: 4096) == 4096)
        #expect(OpenFileLimit.target(soft: 256, hard: 256) == nil)
    }

    @Test func leavesAHigherLimitAlone() {
        #expect(OpenFileLimit.target(soft: 10_240, hard: Self.unlimited) == nil)
        #expect(OpenFileLimit.target(soft: 1_048_576, hard: Self.unlimited) == nil)
    }

    /// Whatever limit the tests start with: 256 from Xcode, and more from
    /// most shells. Afterwards the process can hold more files than an app
    /// starts with room for.
    @Test func leavesTheProcessWithRoom() throws {
        var before = rlimit()
        try #require(getrlimit(RLIMIT_NOFILE, &before) == 0)
        let raised = try #require(OpenFileLimit.raise())
        var after = rlimit()
        try #require(getrlimit(RLIMIT_NOFILE, &after) == 0)
        #expect(after.rlim_cur == raised)
        #expect(after.rlim_cur >= before.rlim_cur)
        #expect(after.rlim_cur >= min(OpenFileLimit.most, before.rlim_max))
        #expect(after.rlim_max == before.rlim_max)

        var pipes: [Int32] = []
        defer { pipes.forEach { close($0) } }
        for _ in 0..<200 {
            var ends: [Int32] = [-1, -1]
            try #require(pipe(&ends) == 0)
            pipes += ends
        }
        #expect(pipes.count == 400)
    }
}
