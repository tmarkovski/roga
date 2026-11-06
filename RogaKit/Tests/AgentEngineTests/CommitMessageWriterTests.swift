import Foundation
import GitRunner
import Synchronization
import Testing
@testable import AgentEngine

/// Running an agent for a commit message, with a closure or a script in place
/// of the real agent, which is never run.
@Suite(.timeLimit(.minutes(1)))
struct CommitMessageWriterTests {
    let claude = CommitMessageAgent(kind: .claude, executable: "/bin/claude", model: "haiku", effort: "low")
    let codex = CommitMessageAgent(kind: .codex, executable: "/bin/codex")
    let request = CommitMessageRequest(
        worktree: "/repository",
        branch: "main",
        changes: CommitMessageInput(files: [.init(path: "a.txt", status: "M", added: 1, deleted: 0)], patch: "diff --git a/a.txt b/a.txt\n+three\n"),
        recentSubjects: ["Add a"],
        draft: "fix a",
        style: "Be brief."
    )

    /// What the fake agent was given, run by run.
    final class Runs: Sendable {
        private let runs = Mutex<[(command: ProgramCommand, input: [UInt8])]>([])

        func record(_ command: ProgramCommand, _ input: [UInt8]) {
            runs.withLock { $0.append((command, input)) }
        }

        var count: Int { runs.withLock { $0.count } }
        var all: [(command: ProgramCommand, input: [UInt8])] { runs.withLock { $0 } }
    }

    /// A run closure that answers with `replies` in turn, as Claude Code's JSON.
    func claudeReplies(_ replies: [String], runs: Runs) -> @Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult {
        { command, input in
            let index = runs.count
            runs.record(command, input)
            let json = #"{"type":"result","is_error":false,"result":\#(String(reflecting: replies[min(index, replies.count - 1)]))}"#
            return ProgramResult(status: .exited(0), output: Array(json.utf8), errorOutput: "", duration: .seconds(2))
        }
    }

    @Test func passesTheCommandAndTheInputWithTheMarker() async throws {
        let runs = Runs()
        let written = try await CommitMessageWriter.write(
            request, with: claude, makeToken: { "feedfacefeedface" }, run: claudeReplies(["Fix a\n\nIt was broken."], runs: runs)
        )
        #expect(written == WrittenMessage(text: "Fix a\n\nIt was broken.", duration: .seconds(2)))
        let run = try #require(runs.all.first)
        #expect(runs.count == 1)
        #expect(run.command == CommitMessageCommand.command(for: claude, worktree: "/repository", style: "Be brief.", hasDraft: true))
        #expect(run.command.environment["ROGA_GENERATING"] == "1")
        #expect(run.command.arguments.last == CommitMessagePrompt.task(hasDraft: true))
        #expect(String(decoding: run.input, as: UTF8.self) == CommitMessagePrompt.input(for: request, token: "feedfacefeedface"))
    }

    @Test func usesANewTokenForEachRequest() async throws {
        let runs = Runs()
        _ = try await CommitMessageWriter.write(request, with: claude, run: claudeReplies(["Fix a"], runs: runs))
        _ = try await CommitMessageWriter.write(request, with: claude, run: claudeReplies(["Fix a"], runs: runs))
        let tags = runs.all.map { String(decoding: $0.input, as: UTF8.self).prefix(while: { $0 != "\n" }) }
        #expect(tags.allSatisfy { $0.hasPrefix("<context-") && $0.count == "<context-0123456789abcdef>".count })
        #expect(tags[0] != tags[1])
    }

    @Test func asksWithoutADraftWhenTheBoxIsEmpty() async throws {
        var empty = request
        empty.draft = "\n  "
        let runs = Runs()
        _ = try await CommitMessageWriter.write(empty, with: claude, run: claudeReplies(["Fix a"], runs: runs))
        #expect(runs.all.first?.command.arguments.last == CommitMessagePrompt.task(hasDraft: false))
    }

    @Test func cleansUpTheReply() async throws {
        let runs = Runs()
        let written = try await CommitMessageWriter.write(request, with: claude, run: claudeReplies(["```\nFix a.\n```"], runs: runs))
        #expect(written.text == "Fix a")
    }

    @Test func triesAgainOnceWhenTheSubjectIsEmpty() async throws {
        let runs = Runs()
        let written = try await CommitMessageWriter.write(request, with: claude, run: claudeReplies(["```\n```", "Fix a"], runs: runs))
        #expect(runs.count == 2)
        #expect(written == WrittenMessage(text: "Fix a", duration: .seconds(4)))
    }

    @Test func triesAgainOnceWhenTheSubjectEndsInAnEllipsis() async throws {
        let runs = Runs()
        #expect(try await CommitMessageWriter.write(request, with: claude, run: claudeReplies(["Fix the...", "Fix a"], runs: runs)).text == "Fix a")
        #expect(runs.count == 2)

        let again = Runs()
        let written = try await CommitMessageWriter.write(request, with: claude, run: claudeReplies(["Fix the\u{2026}"], runs: again))
        #expect(again.count == 2)
        // The author can finish a cut-off subject, which beats no message.
        #expect(written.text == "Fix the\u{2026}")
    }

    @Test func throwsWhenTheReplyIsEmptyTwice() async throws {
        let runs = Runs()
        await #expect(throws: CommitMessageError.empty(.claude)) {
            try await CommitMessageWriter.write(request, with: claude, run: claudeReplies(["", "  "], runs: runs))
        }
        #expect(runs.count == 2)
    }

    @Test func doesntTryAgainWhenTheAgentFails() async throws {
        let runs = Runs()
        let run: @Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult = { command, input in
            runs.record(command, input)
            let json = #"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#
            return ProgramResult(status: .exited(1), output: Array(json.utf8), errorOutput: "", duration: .seconds(1))
        }
        await #expect(throws: CommitMessageError.agentFailed(
            .claude, message: "Claude Code isn't signed in. Run claude auth login in Terminal.", output: "Not logged in · Please run /login"
        )) {
            try await CommitMessageWriter.write(request, with: claude, run: run)
        }
        #expect(runs.count == 1)
    }

    @Test func reportsAProgramThatDidntFinish() async throws {
        let command = CommitMessageCommand.command(for: codex, worktree: "/repository", style: "Be brief.", hasDraft: true)
        let timedOut = ProgramError.timedOut(command, .seconds(60), errorOutput: "")
        await #expect(throws: CommitMessageError.program(timedOut)) {
            try await CommitMessageWriter.write(request, with: codex) { _, _ in throw timedOut }
        }
    }

    @Test func readsCodexsReply() async throws {
        let written = try await CommitMessageWriter.write(request, with: codex) { command, _ in
            #expect(command.arguments.first == "exec")
            return ProgramResult(status: .exited(0), output: Array("Fix a\n".utf8), errorOutput: "tokens used\n12\n", duration: .seconds(6))
        }
        #expect(written == WrittenMessage(text: "Fix a", duration: .seconds(6)))
    }

    @Test func runsARealProgramWithTheInputTheMarkerAndTheFolder() async throws {
        // A stand-in for claude that answers only when it gets what Claude
        // Code would: -p first, the task last after --, the tagged input on
        // standard input, and the marker that keeps Roga's hooks quiet.
        let folder = try makeFolder()
        let script = folder + "/claude"
        try """
            #!/bin/sh
            input=$(cat)
            for last; do :; done
            case "$input" in *"<diff-"*"+three"*) ;; *) echo '{"is_error":true,"result":"no diff"}'; exit 1 ;; esac
            [ "$1" = "-p" ] && [ "$2" = "--safe-mode" ] || { echo '{"is_error":true,"result":"wrong arguments"}'; exit 1; }
            case "$last" in Write*) ;; *) echo '{"is_error":true,"result":"no task"}'; exit 1 ;; esac
            printf '{"type":"result","is_error":false,"result":"Fix a with %s in %s"}\\n' "$ROGA_GENERATING" "$(basename "$PWD")"
            """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)

        var request = request
        request.worktree = folder
        let programs = Programs(searchPath: "/usr/bin:/bin:/usr/sbin:/sbin")
        let agent = CommitMessageAgent(kind: .claude, executable: script)
        let written = try await CommitMessageWriter.write(request, with: agent) { try await programs.run($0, input: $1) }
        #expect(written.text == "Fix a with 1 in " + (folder as NSString).lastPathComponent)
    }

    /// A new, empty folder for the stand-in agent.
    private func makeFolder() throws -> String {
        let folder = FileManager.default.temporaryDirectory.appending(path: "roga-writer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.path(percentEncoded: false)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
