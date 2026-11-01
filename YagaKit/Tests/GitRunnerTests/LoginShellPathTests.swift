import Foundation
import Testing
@testable import GitRunner

@Suite(.timeLimit(.minutes(1)))
struct LoginShellPathTests {
    /// A fake shell that prints `before`, sets `PATH`, runs the command it's
    /// given with -c the way a real shell would, then runs `after`.
    func shell(before: String = "", after: String = "") throws -> String {
        try makeScript("""
            \(before)
            PATH=/opt/fake/bin:/usr/bin:/bin
            export PATH
            eval "$4"
            \(after)
            """, named: "fake-shell", in: try makeTemporaryFolder())
    }

    @Test func readsThePathBetweenTheMarkers() async throws {
        let shell = try shell(before: "echo 'Last login: yesterday'", after: "echo; echo goodbye")
        #expect(await LoginShellPath.read(shell: shell) == "/opt/fake/bin:/usr/bin:/bin")
    }

    @Test func returnsNilWhenTheShellPrintsNoPath() async throws {
        let shell = try makeScript("echo 'no path here'", named: "fake-shell", in: try makeTemporaryFolder())
        #expect(await LoginShellPath.read(shell: shell) == nil)
    }

    @Test func givesUpOnAShellThatHangs() async throws {
        let shell = try shell(before: "sleep 30")
        let started = ContinuousClock.now
        #expect(await LoginShellPath.read(shell: shell, timeout: .milliseconds(300)) == nil)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func doesNotWaitForBackgroundJobsThatHoldTheOutput() async throws {
        let shell = try shell(after: "sleep 30 &")
        let started = ContinuousClock.now
        #expect(await LoginShellPath.read(shell: shell) == "/opt/fake/bin:/usr/bin:/bin")
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func returnsNilForAShellThatDoesNotExist() async {
        #expect(await LoginShellPath.read(shell: "/nonexistent/shell") == nil)
    }

    @Test(arguments: [
        ("_YAGA_PATH_START_/usr/bin:/bin_YAGA_PATH_END_", "/usr/bin:/bin"),
        ("motd\n_YAGA_PATH_START_/a b/bin_YAGA_PATH_END_\ntrailing", "/a b/bin"),
        ("_YAGA_PATH_START_/usr/bin", nil),
        ("_YAGA_PATH_START__YAGA_PATH_END_", nil),
        ("", nil),
    ] as [(String, String?)])
    func findsThePathInTheOutput(_ output: String, _ expected: String?) {
        #expect(LoginShellPath.path(in: Array(output.utf8)) == expected)
    }

    @Test func readsTheUsersRealShell() async {
        let path = await LoginShellPath.read()
        #expect(path?.split(separator: ":").contains("/usr/bin") == true)
    }
}
