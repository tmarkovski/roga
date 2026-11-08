import Testing
@testable import RepositoryEngine

/// Finding the paths in what git said (decision 63).
struct GitFailureFactsTests {
    @Test func findsAPathInGitsWords() {
        let said = """
            fatal: bad object HEAD
            fatal: 'git status --porcelain=2' failed in submodule prototypes/git-access/.build/checkouts/swift-argument-parser
            """
        #expect(RepositorySession.pathsNamed(in: said, worktree: "/work") == ["prototypes/git-access/.build/checkouts/swift-argument-parser"])
    }

    @Test func takesOffQuotesAndPunctuationButNotALeadingDot() {
        #expect(RepositorySession.pathsNamed(in: "error: '.build/a' and (b/c), `d/e`: f/g.", worktree: "/work") == [".build/a", "b/c", "d/e", "f/g"])
    }

    @Test func makesAPathInTheWorktreeRelative() {
        #expect(RepositorySession.pathsNamed(in: "cannot read /work/a/b and /other/c", worktree: "/work") == ["a/b"])
    }

    @Test func takesAQuotedFileNameWithoutASlash() {
        #expect(RepositorySession.pathsNamed(in: "pathspec 'a.txt' did not match, 'main' neither", worktree: "/work") == ["a.txt"])
    }

    @Test func leavesOutWhatIsntAPathInTheWorktree() {
        let said = "fatal: unable to access 'https://example.com/a.git/' from git@host:a/b.git .git/index.lock refs/heads/main --work/tree"
        #expect(RepositorySession.pathsNamed(in: said, worktree: "/work").isEmpty)
    }

    @Test func eachPathOnceAndNotTooMany() {
        let said = (1...20).map { "a/\($0)" }.joined(separator: " ") + " a/1"
        let paths = RepositorySession.pathsNamed(in: said, worktree: "/work")
        #expect(paths.count == RepositorySession.factPathLimit)
        #expect(Set(paths).count == paths.count)
    }
}
