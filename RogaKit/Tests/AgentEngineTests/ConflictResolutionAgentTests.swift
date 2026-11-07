import Foundation
import GitRunner
import Synchronization
import Testing
@testable import AgentEngine

/// Asking an agent to resolve a file's conflicts (decision 60).
struct ConflictResolutionAgentTests {
    let request = ConflictResolutionRequest(
        worktree: "/work",
        path: "Sources/LoginView.swift",
        ours: .init(name: "main", detail: "a17f9d3 · Add a retry button"),
        theirs: .init(name: "origin/main", detail: "86b3386 · Show the error"),
        conflicts: [
            .init(before: "struct LoginView {\n", ours: "    var attempts = 0\n", theirs: "    var failure: String?\n", after: "}\n"),
            .init(before: "", ours: "a\n", base: "base\n", theirs: "", after: ""),
        ]
    )
    let claude = CommitMessageAgent(kind: .claude, executable: "/usr/local/bin/claude", model: "sonnet")

    final class Inputs: Sendable {
        let inputs = Mutex<[(ProgramCommand, String)]>([])
    }

    /// A run that answers with Claude Code's JSON around `reply`.
    func claudeReply(_ reply: String, _ inputs: Inputs = Inputs()) -> @Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult {
        { command, input in
            inputs.inputs.withLock { $0.append((command, String(decoding: input, as: UTF8.self))) }
            let json = #"{"type":"result","is_error":false,"result":\#(String(reflecting: reply))}"#
            return ProgramResult(status: .exited(0), output: Array(json.utf8), errorOutput: "", duration: .seconds(12))
        }
    }

    @Test func sendsEachConflictWithGitsMarkersInBlocksOfItsOwn() {
        let input = ConflictResolutionPrompt.input(for: request, token: "feedface")
        #expect(input == """
            <context-feedface>
            File: Sources/LoginView.swift
            First side: main (a17f9d3 · Add a retry button)
            Second side: origin/main (86b3386 · Show the error)
            Conflicts: 2
            </context-feedface>

            <conflict-1-feedface>
            struct LoginView {
            <<<<<<< first side, main
                var attempts = 0
            =======
                var failure: String?
            >>>>>>> second side, origin/main
            }
            </conflict-1-feedface>

            <conflict-2-feedface>
            <<<<<<< first side, main
            a
            ||||||| what both started from
            base
            =======
            >>>>>>> second side, origin/main
            </conflict-2-feedface>

            """)
    }

    @Test func readsTheExplanationAndEachConflict() {
        let reply = """
            Here you go.
            <why>
            main counts attempts, and origin/main keeps the error. Both stay.
            </why>
            <conflict n="1">
                var attempts = 0
                var failure: String?
            </conflict>
            <conflict n="2">
            </conflict>
            """
        let (explanation, lines) = ConflictResolutionPrompt.parse(reply, count: 2)
        #expect(explanation == "main counts attempts, and origin/main keeps the error. Both stay.")
        #expect(lines == [0: "    var attempts = 0\n    var failure: String?", 1: ""])
    }

    @Test func leavesOutConflictsItDidntAnswerAndCodeFences() {
        let reply = "<conflict n=\"2\">\n```swift\nb\n```\n</conflict>"
        let (explanation, lines) = ConflictResolutionPrompt.parse(reply, count: 2)
        #expect(explanation.isEmpty)
        #expect(lines == [1: "b"])
    }

    @Test func runsTheAgentWithNoToolsAndTheFileOnItsInput() async throws {
        let inputs = Inputs()
        let resolution = try await ConflictResolutionWriter.resolve(
            request,
            with: claude,
            makeToken: { "feedface" },
            run: claudeReply("<why>Kept both.</why><conflict n=\"1\">\nx\n</conflict>", inputs)
        )
        #expect(resolution == AgentResolution(explanation: "Kept both.", lines: [0: "x"], duration: .seconds(12)))
        let (command, input) = try #require(inputs.inputs.withLock { $0.first })
        #expect(command.arguments.contains("--tools="))
        #expect(command.arguments.contains(ConflictResolutionPrompt.instructions))
        #expect(command.arguments.last == ConflictResolutionPrompt.task)
        #expect(command.environment[CommitMessageCommand.generatingVariable] == "1")
        #expect(command.timeout == ConflictResolutionWriter.shortestTimeLimit)
        #expect(input.hasPrefix("<context-feedface>"))
    }

    @Test func aReplyWithNoConflictsIsAFailure() async throws {
        await #expect(throws: CommitMessageError.agentFailed(.claude, message: "Claude Code replied without resolving any of the conflicts.", output: "Not sure.")) {
            try await ConflictResolutionWriter.resolve(request, with: claude, run: claudeReply("Not sure."))
        }
    }

    @Test func aLongTimeLimitStaysLong() {
        var agent = claude
        agent.timeLimit = .seconds(600)
        #expect(ConflictResolutionWriter.command(for: agent, worktree: "/work").timeout == .seconds(600))
    }

    @Test func aRequestThatsTooBigDoesntFit() {
        var big = request
        big.conflicts[0].ours = String(repeating: "x", count: ConflictResolutionRequest.sizeLimit)
        #expect(request.fits)
        #expect(!big.fits)
    }
}
