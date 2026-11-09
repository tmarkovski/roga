import Darwin
import Foundation
import Synchronization
import Testing
@testable import GitRunner

@Suite(.timeLimit(.minutes(1)))
struct ChildProcessTests {
    func spawn(_ script: String, withInput: Bool = false) throws -> ChildProcess {
        try ChildProcess.spawn(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: shellEnvironment,
            withInput: withInput
        )
    }

    @Test func startsAtThePriorityItsAskedFor() async throws {
        func running(at priority: GitCommand.Priority) async throws -> Int {
            let process = try ChildProcess.spawn(
                executable: "/bin/sh",
                arguments: ["-c", "ps -o pri= -p $$"],
                environment: shellEnvironment,
                priority: priority
            )
            let output = String(decoding: try await process.readAll(), as: UTF8.self)
            return try #require(Int(output.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let background = try await running(at: .background)
        let utility = try await running(at: .utility)
        let normal = try await running(at: .normal)
        #expect(background < utility)
        // A command at normal priority runs at the priority of whatever
        // started it. That's above utility when the tests run from a terminal
        // or Xcode. A CI runner's jobs run at utility already, 20 in ps, so
        // there the two are the same.
        #expect(utility <= normal)
        if normal > 20 {
            #expect(utility < normal)
        }
    }

    @Test func reportsExitStatus() async throws {
        let process = try spawn("exit 3")
        #expect(await process.exitStatus() == .exited(3))
        #expect(process.currentStatus == .exited(3))
    }

    @Test func reportsSignals() async throws {
        let process = try spawn("kill -TERM $$")
        #expect(await process.exitStatus() == .signaled(SIGTERM))
    }

    @Test(arguments: [(Int32(0), ExitStatus.exited(0)), (0x0100, .exited(1)), (0x8000, .exited(128)), (15, .signaled(15)), (9 | 0x80, .signaled(9))] as [(Int32, ExitStatus)])
    func decodesWaitStatus(_ raw: Int32, _ expected: ExitStatus) {
        #expect(ExitStatus(waitStatus: raw) == expected)
    }

    @Test func readsLargeOutput() async throws {
        let process = try spawn("seq 1 400000")
        let output = try await process.readAll()
        let expected = (1...400_000).map(String.init).joined(separator: "\n") + "\n"
        #expect(output.count == expected.utf8.count)
        #expect(output == Array(expected.utf8))
        #expect(await process.exitStatus() == .exited(0))
    }

    @Test func writesInputWhileReadingOutput() async throws {
        // Larger than a pipe's buffer in both directions, so writing everything
        // before reading would deadlock.
        let input = (0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let process = try spawn("cat", withInput: true)
        let writer = try #require(process.input)
        writer.submit(input)
        writer.close()
        #expect(try await process.readAll() == input)
        #expect(await process.exitStatus() == .exited(0))
    }

    @Test func awaitsWrites() async throws {
        let process = try spawn("cat", withInput: true)
        let writer = try #require(process.input)
        try await writer.write(Array("first\n".utf8))
        try await writer.write(Array("second\n".utf8))
        writer.close()
        #expect(String(decoding: try await process.readAll(), as: UTF8.self) == "first\nsecond\n")
    }

    @Test func collectsStandardError() async throws {
        let process = try spawn("echo oops >&2; echo fine; exit 1")
        #expect(try await process.readAll() == Array("fine\n".utf8))
        #expect(await process.exitStatus() == .exited(1))
        #expect(await process.errorOutput.collected() == Array("oops\n".utf8))
    }

    @Test func keepsTheEndOfLongStandardError() async throws {
        let process = try spawn("seq 1 100000 >&2")
        _ = try await process.readAll()
        let collected = await process.errorOutput.collected()
        #expect(collected.count == process.errorOutput.limit)
        #expect(String(decoding: collected.suffix(13), as: UTF8.self) == "99999\n100000\n")
    }

    @Test func startsInTheGivenFolder() async throws {
        let folder = try makeTemporaryFolder()
        let process = try ChildProcess.spawn(
            executable: "/bin/pwd",
            arguments: [],
            environment: shellEnvironment,
            directory: folder.path(percentEncoded: false)
        )
        let output = String(decoding: try await process.readAll(), as: UTF8.self)
        #expect(output == folder.plainPath + "\n")
    }

    @Test func passesTheEnvironment() async throws {
        let process = try ChildProcess.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "printf %s \"$ROGA_TEST\""],
            environment: ["ROGA_TEST": "a value with spaces"]
        )
        #expect(String(decoding: try await process.readAll(), as: UTF8.self) == "a value with spaces")
    }

    @Test func failsForAMissingExecutable() {
        #expect(throws: SpawnError.self) {
            try ChildProcess.spawn(executable: "/nonexistent/git", arguments: [], environment: [:])
        }
    }

    @Test func explainsAMissingFolder() throws {
        let error = #expect(throws: SpawnError.self) {
            try ChildProcess.spawn(
                executable: "/bin/pwd",
                arguments: [],
                environment: [:],
                directory: "/nonexistent/folder"
            )
        }
        #expect(error?.description.contains("folder doesn't exist") == true)
    }

    @Test func seesEveryExitOfManyShortProcesses() async throws {
        try await withThrowingTaskGroup(of: ExitStatus.self) { group in
            for _ in 0..<200 {
                let process = try ChildProcess.spawn(executable: "/usr/bin/true", arguments: [], environment: [:])
                group.addTask { await process.exitStatus() }
            }
            for try await status in group {
                #expect(status == .exited(0))
            }
        }
    }

    @Test func callsTheExitHandler() async throws {
        let reported = Mutex<ExitStatus?>(nil)
        let process = try ChildProcess.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "exit 4"],
            environment: [:],
            onExit: { status in reported.withLock { $0 = status } }
        )
        _ = await process.exitStatus()
        #expect(reported.withLock { $0 } == .exited(4))
    }

    @Test func terminatesWithSIGTERM() async throws {
        let process = try ChildProcess.spawn(executable: "/bin/sleep", arguments: ["60"], environment: [:])
        let started = ContinuousClock.now
        process.terminate()
        #expect(await process.exitStatus() == .signaled(SIGTERM))
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func killsAProcessThatIgnoresSIGTERM() async throws {
        let process = try spawn("trap '' TERM; echo ready; exec sleep 60")
        // Wait until the trap is set, so SIGTERM can't arrive before it.
        _ = try await process.output.next()
        process.terminate(grace: .milliseconds(200))
        #expect(await process.exitStatus() == .signaled(SIGKILL))
    }

    @Test func terminatesTheWholeProcessGroup() async throws {
        let process = try spawn("sleep 60 & echo $!; wait")
        let line = String(decoding: try #require(try await process.output.next()), as: UTF8.self)
        let child = try #require(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        process.terminate()
        _ = await process.exitStatus()
        let childGone = await eventually { kill(child, 0) != 0 && errno == ESRCH }
        #expect(childGone)
    }

    @Test func closingOutputStopsTheWriter() async throws {
        let process = try ChildProcess.spawn(executable: "/usr/bin/yes", arguments: [], environment: [:])
        _ = try await process.output.next()
        process.output.close()
        #expect(await process.exitStatus() == .signaled(SIGPIPE))
    }
}
