import Foundation
import GitCore
import Testing
import TestSupport
@testable import GitRunner

@Suite(.timeLimit(.minutes(1)))
struct CatFileSessionTests {
    func makeSession(log: CommandLog = CommandLog()) async throws -> CatFileSession {
        try CatFileSession(git: try await TestGit.make(log: log), directory: try await Fixture.repository("basic"))
    }

    @Test func readsAnObject() async throws {
        let session = try await makeSession()
        let objects = try await session.objects([Fixture.Basic.main])
        let commit = try #require(objects.first ?? nil)
        #expect(commit.id == ObjectID(hex: Fixture.Basic.main))
        #expect(commit.type == .commit)
        #expect(String(decoding: commit.contents, as: UTF8.self) == """
            tree \(Fixture.Basic.mainTree)
            parent ef4cfd964ac0378cb3723640730be1b46724b795
            author Ana Kovač <ana@example.com> 1767434400 +0000
            committer Ana Kovač <ana@example.com> 1767434400 +0000

            Change the app

            The body says why.

            """)
    }

    @Test func readsObjectsByAnyName() async throws {
        let session = try await makeSession()
        let objects = try await session.objects(["HEAD:README.md", "main~2", "v0.1"])
        #expect(objects.map { $0?.type } == [.blob, .commit, .tag])
        #expect(objects[0]?.contents == Array("yaga\n".utf8))
        #expect(objects[1]?.id == ObjectID(hex: Fixture.Basic.mainHistory[2]))
    }

    @Test func readsInfo() async throws {
        let session = try await makeSession()
        let info = try await session.info([Fixture.Basic.readme, "main^{tree}", Fixture.Basic.tag])
        #expect(info.map { $0?.type } == [.blob, .tree, .tag])
        #expect(info[0]?.size == 5)
        #expect(info[1]?.id == ObjectID(hex: Fixture.Basic.mainTree))
    }

    @Test func returnsNilForMissingObjects() async throws {
        let session = try await makeSession()
        let objects = try await session.objects([
            String(repeating: "0", count: 40),
            Fixture.Basic.main,
            "no-such-branch",
        ])
        #expect(objects[0] == nil)
        #expect(objects[1]?.type == .commit)
        #expect(objects[2] == nil)
        // The session keeps working afterwards.
        #expect(try await session.info(["main"]).first??.type == .commit)
    }

    @Test func rejectsNamesThatBreakTheProtocol() async throws {
        let session = try await makeSession()
        await #expect(throws: GitError.invalidObjectName("main\nflush")) {
            try await session.objects(["main\nflush"])
        }
        await #expect(throws: GitError.invalidObjectName("")) {
            try await session.info([""])
        }
        #expect(try await session.objects([]).isEmpty)
    }

    @Test func answersConcurrentRequestsInOrder() async throws {
        let session = try await makeSession()
        let names = Fixture.Basic.mainHistory + [Fixture.Basic.feature, Fixture.Basic.readme, Fixture.Basic.tag]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                let request = (0...(index % 5)).map { names[($0 + index) % names.count] }
                let wantsContents = index.isMultiple(of: 2)
                group.addTask {
                    let ids = wantsContents
                        ? try await session.objects(request).map { $0?.id }
                        : try await session.info(request).map { $0?.id }
                    #expect(ids == request.map { ObjectID(hex: $0) })
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func runsOneGitForTheWholeSession() async throws {
        let log = CommandLog()
        let session = try await makeSession(log: log)
        for name in Fixture.Basic.mainHistory {
            _ = try await session.objects([name])
        }
        #expect(log.entries.count == 1)
        #expect(log.entries[0].arguments == ["--no-optional-locks", "cat-file", "--batch-command", "--buffer"])
        #expect(log.entries[0].outcome == .running)
        session.close()
        #expect(await eventually { log.entries[0].outcome == .finished(.exited(0)) })
    }

    @Test func throwsAfterClosing() async throws {
        let session = try await makeSession()
        session.close()
        await #expect(throws: GitError.self) { try await session.objects(["main"]) }
    }

    @Test func endsGitWhenTheSessionIsDropped() async throws {
        let log = CommandLog()
        var session: CatFileSession? = try await makeSession(log: log)
        _ = try await session?.objects(["main"])
        session = nil
        #expect(await eventually { log.entries.first?.outcome == .finished(.exited(0)) })
    }

    @Test func failsWhenGitExits() async throws {
        let git = try await TestGit.make()
        let session = try CatFileSession(git: git, directory: try makeTemporaryFolder().path(percentEncoded: false))
        let error = await #expect(throws: GitError.self) { try await session.objects(["main"]) }
        guard case .failed(_, .exited(128), let errorOutput) = error else {
            Issue.record("Expected git to fail outside a repository, got \(String(describing: error))")
            return
        }
        #expect(errorOutput.contains("not a git repository"))
    }

    @Test func cancelledRequestsDontDisturbOthers() async throws {
        let session = try await makeSession()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.objects(["main"])
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await session.objects(["feature"]).first??.id == ObjectID(hex: Fixture.Basic.feature))
    }
}
