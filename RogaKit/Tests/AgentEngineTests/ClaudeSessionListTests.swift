import Foundation
import GitRunner
import Testing
@testable import AgentEngine

@Suite(.timeLimit(.minutes(1)))
struct ClaudeSessionListTests {
    /// What Claude Code 2.1.286 printed, with the session's details changed.
    let listing = #"""
        [{"pid":76725,"cwd":"/Users/me/git/roga","kind":"interactive","startedAt":1793929461013,"sessionId":"0a1b2c3d","name":"Agents","status":"busy"},
         {"pid":81234,"cwd":"/Users/me/git/other","kind":"background","sessionId":"4e5f","status":"waiting","waitingFor":"permission"}]
        """#

    @Test func readsTheSessions() {
        #expect(ClaudeSessionList.parse(Array(listing.utf8)) == [
            ClaudeListedSession(pid: 76725, cwd: "/Users/me/git/roga", sessionId: "0a1b2c3d", status: "busy", kind: "interactive"),
            ClaudeListedSession(pid: 81234, cwd: "/Users/me/git/other", sessionId: "4e5f", status: "waiting", waitingFor: "permission", kind: "background"),
        ])
    }

    @Test func toleratesMissingFieldsWrongTypesAndJunkEntries() {
        let odd = #"[{}, 7, "text", null, {"pid":"76725","sessionId":12,"status":"idle"}, {"pid":99999999999,"cwd":"/x"}, {"pid":42,"waitingFor":{"tool":"Bash"}}]"#
        #expect(ClaudeSessionList.parse(Array(odd.utf8)) == [
            ClaudeListedSession(),
            ClaudeListedSession(status: "idle"),
            ClaudeListedSession(cwd: "/x"),
            ClaudeListedSession(pid: 42),
        ])
    }

    @Test func readsAnythingButAListAsNoSessions() {
        for junk in ["", "Usage: claude agents", "{}", #"{"sessions":[]}"#, "[", "null"] {
            #expect(ClaudeSessionList.parse(Array(junk.utf8)) == [], "\(junk)")
        }
        #expect(ClaudeSessionList.parse(Array("[]".utf8)) == [])
    }

    @Test func asksClaudeCodeAtUtilityPriority() async throws {
        let folder = try FakeAgent.folder()
        let log = FakeAgent.path(folder) + "/runs"
        let claude = try FakeAgent.script(FakeAgent.recording(to: log, then: "cat <<'EOF'\n\(listing)\nEOF"), named: "claude", in: folder)
        let sessions = await ClaudeSessionList.list(executable: claude, programs: FakeAgent.programs)
        #expect(sessions?.map(\.sessionId) == ["0a1b2c3d", "4e5f"])
        #expect(FakeAgent.runs(in: log) == [["agents", "--json"]])

        let command = ClaudeSessionList.command(executable: claude)
        #expect(command.arguments == ["agents", "--json"])
        #expect(command.priority == .utility)
        #expect(command.timeout == .seconds(5))
    }

    @Test func returnsNothingWhenClaudeCodeFails() async throws {
        let folder = try FakeAgent.folder()
        let failing = try FakeAgent.script("echo '[]'; echo 'not signed in' >&2; exit 1", named: "claude", in: folder)
        #expect(await ClaudeSessionList.list(executable: failing, programs: FakeAgent.programs) == nil)

        let junk = try FakeAgent.script("echo 'Usage: claude agents [options]'", named: "junk", in: folder)
        #expect(await ClaudeSessionList.list(executable: junk, programs: FakeAgent.programs) == nil)

        let crashing = try FakeAgent.script("kill -ABRT $$", named: "crashing", in: folder)
        #expect(await ClaudeSessionList.list(executable: crashing, programs: FakeAgent.programs) == nil)

        let hanging = try FakeAgent.script("sleep 30", named: "hanging", in: folder)
        let started = ContinuousClock.now
        #expect(await ClaudeSessionList.list(executable: hanging, programs: FakeAgent.programs, timeLimit: .milliseconds(300)) == nil)
        #expect(ContinuousClock.now - started < .seconds(10))

        #expect(await ClaudeSessionList.list(executable: "/nonexistent/claude", programs: FakeAgent.programs) == nil)

        let empty = try FakeAgent.script("echo '[]'", named: "empty", in: folder)
        #expect(await ClaudeSessionList.list(executable: empty, programs: FakeAgent.programs) == [])
    }
}
