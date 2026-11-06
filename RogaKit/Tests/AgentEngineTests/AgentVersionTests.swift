import Testing
@testable import AgentEngine

@Suite(.timeLimit(.minutes(1)))
struct AgentVersionTests {
    @Test func readsWhatTheAgentsPrint() {
        #expect(AgentVersion(versionOutput: "2.1.286 (Claude Code)\n") == AgentVersion(major: 2, minor: 1, patch: 286))
        #expect(AgentVersion(versionOutput: "codex-cli 0.166.0\n") == AgentVersion(major: 0, minor: 166, patch: 0))
        #expect(AgentVersion(versionOutput: "codex-cli 0.166.0-alpha.6\n")
            == AgentVersion(major: 0, minor: 166, patch: 0, prerelease: "alpha.6"))
    }

    @Test func readsOtherSpellings() {
        #expect(AgentVersion(versionOutput: "v1.2.3") == AgentVersion(major: 1, minor: 2, patch: 3))
        #expect(AgentVersion(versionOutput: "tool 1.2") == AgentVersion(major: 1, minor: 2, patch: 0))
        #expect(AgentVersion(versionOutput: "tool (1.2.3+build.7)") == AgentVersion(major: 1, minor: 2, patch: 3))
        #expect(AgentVersion(versionOutput: "warning: 3 things\ncodex-cli 0.140.1") == AgentVersion(major: 0, minor: 140, patch: 1))
    }

    @Test func readsNothingWithoutAVersion() {
        #expect(AgentVersion(versionOutput: "") == nil)
        #expect(AgentVersion(versionOutput: "codex-cli") == nil)
        #expect(AgentVersion(versionOutput: "error 1") == nil)
        #expect(AgentVersion(versionOutput: "1.2.3.4") == nil)
        #expect(AgentVersion(versionOutput: "1..2") == nil)
        #expect(AgentVersion(versionOutput: "1.2.3-") == nil)
    }

    @Test func ordersReleasesAndPrereleases() {
        let versions = [
            "0.131.0", "0.165.9", "0.166.0-alpha", "0.166.0-alpha.6", "0.166.0-alpha.10",
            "0.166.0-alpha.beta", "0.166.0-beta", "0.166.0-beta.2", "0.166.0-rc.1", "0.166.0", "0.166.1", "2.1.169",
        ].map { AgentVersion(versionOutput: $0)! }
        for (index, version) in versions.enumerated() {
            for later in versions[(index + 1)...] {
                #expect(version < later, "\(version) should come before \(later)")
                #expect(!(later < version))
            }
            #expect(!(version < version))
        }
    }

    @Test func describesItselfAsPrinted() {
        #expect(AgentVersion(major: 0, minor: 166, patch: 0, prerelease: "alpha.6").description == "0.166.0-alpha.6")
        #expect(AgentVersion(major: 2, minor: 1, patch: 286).description == "2.1.286")
    }
}
