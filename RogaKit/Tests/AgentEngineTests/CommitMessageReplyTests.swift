import GitRunner
import Testing
@testable import AgentEngine

/// Reading what Claude Code and Codex print, with the error texts they really
/// print where they're known.
@Suite(.timeLimit(.minutes(1)))
struct CommitMessageReplyTests {
    func result(_ output: String, errorOutput: String = "", status: Int32 = 0) -> ProgramResult {
        ProgramResult(status: .exited(status), output: Array(output.utf8), errorOutput: errorOutput, duration: .seconds(2))
    }

    func claudeJSON(result: String, isError: Bool, apiErrorStatus: String = "null") -> String {
        """
        {"type":"result","subtype":"success","is_error":\(isError),"api_error_status":\(apiErrorStatus),"duration_ms":2400,\
        "result":\(String(reflecting: result)),"session_id":"17a60621-58b1-4c6e-aa80-090b9ba78cdb"}
        """
    }

    func failure(_ result: ProgramResult, _ agent: AgentKind) -> CommitMessageError? {
        do {
            _ = try CommitMessageReply.message(from: result, agent: agent)
            return nil
        } catch {
            return error
        }
    }

    func message(of error: CommitMessageError?) -> String? {
        if case .agentFailed(_, let message, _) = error { return message }
        return nil
    }

    // MARK: Claude Code

    @Test func readsClaudeCodesResult() throws {
        let reply = result(claudeJSON(result: "Add the sidebar\n\nIt lists every worktree.", isError: false) + "\n")
        #expect(try CommitMessageReply.message(from: reply, agent: .claude) == "Add the sidebar\n\nIt lists every worktree.")
    }

    @Test func readsTheLastLineOfJSONAfterAWarning() throws {
        let reply = result("Warning: something about the terminal\n" + claudeJSON(result: "Add the sidebar", isError: false) + "\n")
        #expect(try CommitMessageReply.message(from: reply, agent: .claude) == "Add the sidebar")
    }

    @Test func saysClaudeCodeIsntSignedIn() {
        // What `claude -p --output-format json` printed on this Mac, with the
        // OAuth session expired: JSON on standard output, nothing on standard
        // error, and status 1.
        let real = """
            {"duration_api_ms":0,"stop_reason":"stop_sequence","session_id":"17a60621-58b1-4c6e-aa80-090b9ba78cdb",\
            "total_cost_usd":0,"modelUsage":{},"permission_denials":[],"terminal_reason":"api_error","safety_stops":0,\
            "is_error":true,"num_turns":1,"subtype":"success","api_error_status":null,\
            "result":"Failed to authenticate: OAuth session expired and could not be refreshed","type":"result",\
            "duration_ms":35,"uuid":"f392e596-b81c-41c6-8a05-7c9105b94d69","queued_turn_count":0,"result_index":0}
            """
        let error = failure(result(real + "\n", status: 1), .claude)
        #expect(error == .agentFailed(
            .claude,
            message: "Claude Code isn't signed in. Run claude auth login in Terminal.",
            output: "Failed to authenticate: OAuth session expired and could not be refreshed"
        ))
        #expect(error?.description == "Claude Code isn't signed in. Run claude auth login in Terminal.")

        let notLoggedIn = failure(result(claudeJSON(result: "Not logged in · Please run /login", isError: true), status: 1), .claude)
        #expect(message(of: notLoggedIn) == "Claude Code isn't signed in. Run claude auth login in Terminal.")
    }

    @Test func saysClaudeCodeHasReachedALimit() {
        let limit = "Claude Code has reached a usage limit, so try again once it resets, or choose another model."
        for text in ["You've hit your limit · resets 3pm (Europe/Zagreb)", "Claude AI usage limit reached|1793929461", "API Error: 429 rate_limit_error"] {
            #expect(message(of: failure(result(claudeJSON(result: text, isError: true), status: 1), .claude)) == limit)
        }
        let byStatus = failure(result(claudeJSON(result: "API Error: overloaded", isError: true, apiErrorStatus: "429"), status: 1), .claude)
        #expect(message(of: byStatus) == limit)
    }

    @Test func passesOnClaudeCodesOwnFirstLine() {
        let error = failure(result(claudeJSON(result: "API Error: 500 Internal server error\nRequest ID: abc", isError: true), status: 1), .claude)
        #expect(message(of: error) == "API Error: 500 Internal server error")
        if case .agentFailed(_, _, let output) = error {
            #expect(output == "API Error: 500 Internal server error\nRequest ID: abc")
        }
    }

    @Test func requiresBothSuccessAndNoError() {
        // A failure's text must never land in the message box.
        #expect(failure(result(claudeJSON(result: "Add the sidebar", isError: false), status: 1), .claude) != nil)
        #expect(failure(result(claudeJSON(result: "Overloaded", isError: true), status: 0), .claude) != nil)
    }

    @Test func readsClaudeCodesStandardErrorWhenThereIsNoJSON() {
        let error = failure(result("", errorOutput: "error: unknown option '--safe-mode'\n", status: 1), .claude)
        #expect(error == .agentFailed(.claude, message: "error: unknown option '--safe-mode'", output: "error: unknown option '--safe-mode'"))

        let silent = failure(ProgramResult(status: .signaled(9), output: [], errorOutput: "", duration: .zero), .claude)
        #expect(message(of: silent) == "Claude Code stopped by signal 9 without saying why.")
    }

    @Test func refusesTextThatIsntJSON() {
        let error = failure(result("Add the sidebar\n"), .claude)
        #expect(message(of: error) == "Claude Code replied with something Roga can't read: Add the sidebar.")
    }

    // MARK: Codex

    @Test func readsCodexsStandardOutput() throws {
        // Codex logs to standard error as it goes, even when it works.
        let stderr = """
            Reading additional input from stdin...
            2026-11-06T02:21:34.034010Z ERROR codex_models_manager::cache: failed to load models cache: unknown variant `max`
            tokens used
            1,234
            """
        let reply = result("Make the settings sidebar full height\n\nShow the page's title.\n", errorOutput: stderr)
        #expect(try CommitMessageReply.message(from: reply, agent: .codex) == "Make the settings sidebar full height\n\nShow the page's title.\n")
    }

    @Test func saysTheModelNeedsANewerCodex() {
        // What codex 0.137 printed for the account's model: the prompt echoed,
        // standard input included, then the same error twice.
        let line = """
            ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-6-astra' model \
            requires a newer version of Codex. Please upgrade to the latest app or CLI and try again."}}
            """
        let stderr = """
            Reading additional input from stdin...
            OpenAI Codex v0.137.0
            --------
            user
            You write git commit messages.

            <stdin>
            diff --git a/a.txt b/a.txt
            </stdin>
            \(line)
            \(line)
            """
        let error = failure(result("", errorOutput: stderr, status: 1), .codex)
        #expect(error == .agentFailed(
            .codex,
            message: "This model needs a newer version of Codex, which Roga can use once you choose it on the Agents page.",
            output: line + "\n" + line
        ))
    }

    @Test func saysCodexIsntSignedIn() {
        let signedOut = "Codex isn't signed in. Run codex login in Terminal."
        let byStatus = #"ERROR: {"type":"error","status":401,"error":{"message":"Your access token could not be refreshed."}}"#
        #expect(message(of: failure(result("", errorOutput: byStatus, status: 1), .codex)) == signedOut)
        let plain = "ERROR: unexpected status 401 Unauthorized: Missing bearer or basic authentication in header"
        #expect(message(of: failure(result("", errorOutput: plain, status: 1), .codex)) == signedOut)
        #expect(message(of: failure(result("", errorOutput: "Not logged in\n", status: 1), .codex)) == signedOut)
    }

    @Test func saysCodexHasReachedALimit() {
        let limit = "Codex has reached a usage limit, so try again once it resets, or choose another model."
        let usage = #"ERROR: {"type":"error","status":429,"error":{"type":"usage_limit_reached","message":"You've hit your usage limit. Try again at 3:00 PM."}}"#
        #expect(message(of: failure(result("", errorOutput: usage, status: 1), .codex)) == limit)
        let plain = "ERROR: exceeded retry limit, last status: 429 Too Many Requests"
        #expect(message(of: failure(result("", errorOutput: plain, status: 1), .codex)) == limit)
    }

    @Test func passesOnCodexsOwnError() {
        let stderr = """
            user
            ERROR: this line came from the diff on standard input
            ERROR: {"type":"error","status":400,"error":{"message":"The model 'nope' does not exist."}}
            """
        #expect(message(of: failure(result("", errorOutput: stderr, status: 1), .codex)) == "The model 'nope' does not exist.")
        // A number in the text that only contains 401 isn't a sign-in problem.
        let other = "ERROR: Request 14012 failed"
        #expect(message(of: failure(result("", errorOutput: other, status: 1), .codex)) == "Request 14012 failed")
    }

    @Test func readsCodexsLastLineWhenThereIsNoError() {
        let stderr = "Reading additional input from stdin...\nError: unexpected argument '--frobnicate' found\n\n"
        let error = failure(result("", errorOutput: stderr, status: 2), .codex)
        #expect(error == .agentFailed(
            .codex,
            message: "Error: unexpected argument '--frobnicate' found",
            output: "Reading additional input from stdin...\nError: unexpected argument '--frobnicate' found"
        ))
    }

    // MARK: Errors

    @Test func describesEachError() {
        #expect(CommitMessageError.empty(.codex).description == "Codex replied without a message.")
        let command = ProgramCommand("/bin/claude", ["-p"])
        let timedOut = ProgramError.timedOut(command, .seconds(60), errorOutput: "partway\n")
        #expect(CommitMessageError.program(timedOut).description == timedOut.description)
        #expect(CommitMessageError.program(timedOut).output == "partway\n")
        #expect(CommitMessageError.agentFailed(.claude, message: "Sign in.", output: "").output == nil)
        #expect(CommitMessageError.agentFailed(.claude, message: "Sign in.", output: "details").output == "details")
    }
}
