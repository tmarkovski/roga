import GitRunner
import Testing

struct GitVersionTests {
    @Test(arguments: [
        ("git version 2.52.0\n", GitVersion(major: 2, minor: 52, patch: 0)),
        ("git version 2.50.1 (Apple Git-155)", GitVersion(major: 2, minor: 50, patch: 1)),
        ("git version 2.53.0.rc1", GitVersion(major: 2, minor: 53, patch: 0)),
        ("git version 2.52.0.290.g1a2b3c4", GitVersion(major: 2, minor: 52, patch: 0)),
        ("git version 2.44.4.windows.1", GitVersion(major: 2, minor: 44, patch: 4)),
        ("git version 3.0", GitVersion(major: 3, minor: 0, patch: 0)),
    ])
    func readsVersionOutput(_ output: String, _ expected: GitVersion) {
        #expect(GitVersion(versionOutput: output) == expected)
    }

    @Test(arguments: ["", "git version", "git version 2", "git version two.44", "hub version 2.14.2"])
    func rejectsOtherOutput(_ output: String) {
        #expect(GitVersion(versionOutput: output) == nil)
    }

    @Test func requiresGit2_44() {
        #expect(!GitVersion(major: 2, minor: 43, patch: 7).isSupported)
        #expect(GitVersion(major: 2, minor: 44).isSupported)
        #expect(GitVersion(major: 3, minor: 0).isSupported)
    }
}
