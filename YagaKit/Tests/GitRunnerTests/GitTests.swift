import Darwin
import Foundation
import Testing
import TestSupport
@testable import GitRunner

@Suite(.timeLimit(.minutes(1)))
struct GitTests {
    @Test func runsACommand() async throws {
        let git = try await TestGit.make()
        let repository = try await Fixture.repository("basic")
        let result = try await git.run(GitCommand("rev-parse", "main", in: repository))
        #expect(result.status == 0)
        #expect(result.text == Fixture.Basic.main + "\n")
        #expect(result.errorOutput.isEmpty)
    }

    @Test func returnsTextWithoutTheFinalNewline() async throws {
        let git = try await TestGit.make()
        let repository = try await Fixture.repository("basic")
        #expect(try await git.text(GitCommand("rev-parse", "feature", in: repository)) == Fixture.Basic.feature)
    }

    @Test func throwsWhenGitFails() async throws {
        let git = try await TestGit.make()
        let repository = try await Fixture.repository("basic")
        let command = GitCommand("rev-parse", "--verify", "no-such-branch", in: repository)
        let error = await #expect(throws: GitError.self) { try await git.run(command) }
        guard case .failed(let failed, let status, let errorOutput) = error else {
            Issue.record("Expected GitError.failed, got \(String(describing: error))")
            return
        }
        #expect(failed == command)
        #expect(status == .exited(128))
        #expect(errorOutput.contains("fatal"))
        #expect(error?.description.contains("exited with status 128: fatal") == true)
    }

    @Test func acceptsTheCommandsSuccessStatuses() async throws {
        let git = try await TestGit.make()
        let repository = try await Fixture.repository("basic")
        // main has a commit that feature doesn't, so it isn't an ancestor.
        var command = GitCommand("merge-base", "--is-ancestor", "main", "feature", in: repository)
        command.successStatuses = [0, 1]
        #expect(try await git.run(command).status == 1)
    }

    @Test func writesInput() async throws {
        let git = try await TestGit.make()
        let repository = try await Fixture.repository("basic")
        let result = try await git.run(GitCommand("hash-object", "--stdin", in: repository), input: Array("yaga\n".utf8))
        #expect(result.text == Fixture.Basic.readme + "\n")
    }

    @Test func ignoresVariablesThatChooseARepository() async throws {
        let installation = try await TestGit.installation()
        var inherited = ProcessInfo.processInfo.environment
        inherited["GIT_DIR"] = "/nonexistent"
        inherited["GIT_WORK_TREE"] = "/nonexistent"
        let git = Git(installation: installation, environment: TestGit.isolatedEnvironment, inheritedEnvironment: inherited)
        let repository = try await Fixture.repository("basic")
        #expect(try await git.text(GitCommand("rev-parse", "--show-toplevel", in: repository)) == repository)
    }

    @Test func buildsTheEnvironment() {
        let environment = Git.environment(
            inheriting: ["GIT_DIR": "/somewhere", "GIT_INDEX_FILE": "/index", "HOME": "/Users/ana", "PATH": "/usr/bin"],
            searchPath: "/opt/homebrew/bin:/usr/bin"
        )
        #expect(environment == [
            "HOME": "/Users/ana",
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "GIT_TERMINAL_PROMPT": "0",
        ])
    }

    @Test func putsYagasOptionsFirst() {
        var command = GitCommand("log", "--format=%H %s")
        #expect(command.fullArguments == ["--no-optional-locks", "log", "--format=%H %s"])
        #expect(command.description == "git --no-optional-locks log '--format=%H %s'")

        command.configuration = ["diff.noprefix": "false", "color.ui": "never"]
        command.takesOptionalLocks = true
        #expect(command.fullArguments == ["-c", "color.ui=never", "-c", "diff.noprefix=false", "log", "--format=%H %s"])
        #expect(GitCommand("show", "it's").description == #"git --no-optional-locks show 'it'\''s'"#)
    }

    @Test func logsCommands() async throws {
        let log = CommandLog()
        let git = try await TestGit.make(log: log)
        let repository = try await Fixture.repository("basic")
        _ = try await git.run(GitCommand("rev-parse", "main", in: repository))
        _ = try? await git.run(GitCommand("rev-parse", "--verify", "no-such-branch", in: repository))

        let entries = log.entries
        #expect(entries.count == 2)
        #expect(entries[0].arguments == ["--no-optional-locks", "rev-parse", "main"])
        #expect(entries[0].directory == repository)
        #expect(entries[0].outcome == .finished(.exited(0)))
        #expect(entries[0].duration != nil)
        #expect(entries[1].outcome == .finished(.exited(128)))
        #expect(entries[0].id < entries[1].id)
    }

    @Test func logsCommandsThatCouldNotStart() async throws {
        let log = CommandLog()
        let installation = GitInstallation(executable: "/nonexistent/git", version: .minimumSupported, searchPath: "/usr/bin")
        let git = Git(installation: installation, log: log)
        await #expect(throws: GitError.self) { try await git.run(GitCommand("version")) }
        guard case .couldNotStart = log.entries.first?.outcome else {
            Issue.record("Expected the entry to record that git couldn't start, got \(String(describing: log.entries.first))")
            return
        }
    }

    @Test func keepsTheMostRecentCommands() async throws {
        let log = CommandLog(capacity: 2)
        let git = try await TestGit.make(log: log)
        let repository = try await Fixture.repository("basic")
        for argument in ["main", "feature", "v0.1"] {
            _ = try await git.run(GitCommand("rev-parse", argument, in: repository))
        }
        #expect(log.entries.map { $0.arguments.last } == ["feature", "v0.1"])
    }

    @Test func cancellingStopsGit() async throws {
        let log = CommandLog()
        let git = try scriptedGit("exec sleep 60", log: log)
        let task = Task { try await git.run(GitCommand("status")) }
        #expect(await eventually { log.entries.first?.outcome == .running })
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(log.entries.first?.outcome == .finished(.signaled(SIGTERM)))
    }

    @Test func doesNotStartGitInACancelledTask() async throws {
        let log = CommandLog()
        let git = try scriptedGit("exit 0", log: log)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await git.run(GitCommand("status"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(log.entries.isEmpty)
    }
}
