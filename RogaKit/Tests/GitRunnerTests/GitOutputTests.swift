import Darwin
import Foundation
import Testing
import TestSupport
@testable import GitRunner

@Suite(.timeLimit(.minutes(1)))
struct GitOutputTests {
    @Test func streamsWhatRunReturns() async throws {
        let git = try await TestGit.make()
        let repository = try await Fixture.repository("basic")
        let command = GitCommand("log", "--all", "--format=%H %an %s", in: repository)
        var streamed: [UInt8] = []
        for try await chunk in git.stream(command) {
            streamed.append(contentsOf: chunk)
        }
        #expect(streamed == (try await git.run(command)).output)
    }

    @Test func splitsLines() async throws {
        let git = try await TestGit.make()
        let repository = try await Fixture.repository("basic")
        var ids: [String] = []
        for try await line in git.stream(GitCommand("rev-list", "main", in: repository)).records(separatedBy: UInt8(ascii: "\n")) {
            ids.append(String(decoding: line, as: UTF8.self))
        }
        #expect(ids == Fixture.Basic.mainHistory)
    }

    @Test func writesInput() async throws {
        let git = try await TestGit.make()
        let repository = try await Fixture.repository("basic")
        let input = Array("main\n^\(Fixture.Basic.mainHistory[2])\n".utf8)
        var ids: [String] = []
        for try await line in git.stream(GitCommand("rev-list", "--stdin", in: repository), input: input)
            .records(separatedBy: UInt8(ascii: "\n")) {
            ids.append(String(decoding: line, as: UTF8.self))
        }
        #expect(ids == Array(Fixture.Basic.mainHistory.prefix(2)))
    }

    @Test func splitsNULSeparatedRecords() async throws {
        let git = try await TestGit.make()
        let repository = try await Fixture.repository("basic")
        // With -z, log separates commits with NUL and doesn't end the last one.
        let command = GitCommand("log", "-z", "--format=%H%n%s", "main", in: repository)
        var subjects: [String] = []
        for try await record in git.stream(command).records(separatedBy: 0) {
            let lines = String(decoding: record, as: UTF8.self).split(separator: "\n")
            subjects.append(String(lines[1]))
        }
        #expect(subjects == ["Change the app", "Add the app", "Add the readme"])
    }

    @Test func throwsWhenGitFailsAtTheEnd() async throws {
        let git = try await TestGit.make()
        let repository = try await Fixture.repository("basic")
        await #expect(throws: GitError.self) {
            for try await _ in git.stream(GitCommand("rev-list", "no-such-branch", in: repository)) {}
        }
    }

    @Test func runsAgainForEachIteration() async throws {
        let log = CommandLog()
        let git = try await TestGit.make(log: log)
        let output = git.stream(GitCommand("version"))
        for _ in 0..<2 {
            for try await _ in output {}
        }
        #expect(log.entries.count == 2)
    }

    @Test func leavingEarlyStopsGit() async throws {
        let log = CommandLog()
        let git = try scriptedGit("exec yes", log: log)
        for try await _ in git.stream(GitCommand("log")) {
            break
        }
        let stopped = await eventually {
            if case .finished(.signaled) = log.entries.first?.outcome { true } else { false }
        }
        #expect(stopped)
    }

    @Test func cancellingStopsGit() async throws {
        let log = CommandLog()
        let git = try scriptedGit("exec sleep 60", log: log)
        let task = Task {
            for try await _ in git.stream(GitCommand("log")) {}
        }
        #expect(await eventually { log.entries.first?.outcome == .running })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(log.entries.first?.outcome == .finished(.signaled(SIGTERM)))
    }

    @Test(arguments: [
        // Records split across chunks in every way.
        (["a\0bb\0ccc"], ["a", "bb", "ccc"]),
        (["a", "\0b", "b\0c", "cc"], ["a", "bb", "ccc"]),
        (["a\0", "bb\0", "ccc\0"], ["a", "bb", "ccc"]),
        (["", "a\0", "", "b"], ["a", "b"]),
        // Empty records between separators are kept, and an empty last one isn't.
        (["a\0\0b\0"], ["a", "", "b"]),
        (["\0"], [""]),
        ([], []),
        ([""], []),
    ])
    func splitsChunksIntoRecords(_ chunks: [String], _ expected: [String]) async throws {
        let base = AsyncStream<[UInt8]> { continuation in
            for chunk in chunks { continuation.yield(Array(chunk.utf8)) }
            continuation.finish()
        }
        var records: [String] = []
        for try await record in GitRecords(base: base, separator: 0) {
            records.append(String(decoding: record, as: UTF8.self))
        }
        #expect(records == expected)
    }
}
