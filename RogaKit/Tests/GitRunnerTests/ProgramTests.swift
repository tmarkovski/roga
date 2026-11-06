import Foundation
import Testing
@testable import GitRunner

@Suite(.timeLimit(.minutes(1)))
struct ProgramTests {
    private let programs = Programs(searchPath: "/usr/bin:/bin:/usr/sbin:/sbin")

    @Test func returnsWhatTheProgramPrintedAndItsStatus() async throws {
        let script = try makeScript("echo out; echo err >&2; exit 3", named: "agent", in: try makeTemporaryFolder())
        let result = try await programs.run(ProgramCommand(script, []))
        #expect(result.status == .exited(3))
        #expect(result.text == "out\n")
        #expect(result.errorOutput == "err\n")
        #expect(!result.succeeded)
    }

    @Test func writesTheInputAndClosesIt() async throws {
        // `cat` only finishes once its input is closed.
        let script = try makeScript("cat", named: "agent", in: try makeTemporaryFolder())
        let result = try await programs.run(ProgramCommand(script, []), input: Array("a diff\n".utf8))
        #expect(result.text == "a diff\n")
        #expect(result.succeeded)
    }

    @Test func runsInTheGivenFolderWithTheEnvironment() async throws {
        let folder = try makeTemporaryFolder()
        let script = try makeScript("pwd; echo \"$MARK $NO_COLOR\"", named: "agent", in: folder)
        var command = ProgramCommand(script, [], in: folder.plainPath)
        command.environment = ["MARK": "set"]
        let result = try await programs.run(command)
        #expect(result.text == "\(folder.plainPath)\nset 1\n")
    }

    @Test func stopsAProgramThatRunsPastItsTimeLimit() async throws {
        let script = try makeScript("echo started >&2; sleep 30", named: "agent", in: try makeTemporaryFolder())
        var command = ProgramCommand(script, [])
        command.timeout = .milliseconds(300)
        let started = ContinuousClock.now
        await #expect(throws: ProgramError.timedOut(command, .milliseconds(300), errorOutput: "started\n")) {
            try await programs.run(command)
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func stopsAProgramThatPrintsTooMuch() async throws {
        let script = try makeScript("yes", named: "agent", in: try makeTemporaryFolder())
        var command = ProgramCommand(script, [])
        command.outputLimit = 10_000
        await #expect(throws: ProgramError.outputTooLong(command, limit: 10_000)) {
            try await programs.run(command)
        }
    }

    @Test func cancellingStopsTheProgram() async throws {
        let folder = try makeTemporaryFolder()
        let marker = folder.appending(path: "finished").plainPath
        let script = try makeScript("sleep 5; touch '\(marker)'", named: "agent", in: folder)
        let task = Task { try await programs.run(ProgramCommand(script, [])) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .seconds(6))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func reportsAProgramThatCantStart() async throws {
        let command = ProgramCommand("/nonexistent/agent", [])
        await #expect(throws: ProgramError.self) { try await programs.run(command) }
    }

    @Test func recordsTheRunInTheCommandLog() async throws {
        let log = CommandLog()
        let script = try makeScript("exit 0", named: "agent", in: try makeTemporaryFolder())
        _ = try await Programs(searchPath: "/usr/bin:/bin", log: log).run(ProgramCommand(script, ["-p", "hi"]))
        let entry = try #require(log.entries.last)
        #expect(entry.program == script)
        #expect(entry.arguments == ["-p", "hi"])
        #expect(await eventually { log.entries.last?.outcome == .finished(.exited(0)) })
    }

    @Test func describesTheCommandSoItCanBePasted() {
        let command = ProgramCommand("/opt/homebrew/bin/codex", ["exec", "-c", "notify=[]", "Write it"])
        #expect(command.description == "/opt/homebrew/bin/codex exec -c 'notify=[]' 'Write it'")
        #expect(command.name == "codex")
    }
}
