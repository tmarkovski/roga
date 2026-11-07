import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Comparing two commits, reading a stash and reviewing a branch (decision 56),
/// against real git.
@Suite(.timeLimit(.minutes(1)))
struct ReviewTests {
    /// A repository with one commit on `main`, and a session for it.
    func makeRepository() async throws -> (RepositorySession, String) {
        let repository = try makeTemporaryFolder() + "/repository"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: repository)
        try await runGit("config", "user.name", "Ana", in: repository)
        try await runGit("config", "user.email", "ana@example.com", in: repository)
        try write("one\ntwo\nthree\n", to: "a.txt", in: repository)
        try await commit("First", in: repository)
        return (try await openSession(repository), repository)
    }

    func write(_ text: String, to path: String, in repository: String) throws {
        let file = URL(filePath: repository + "/" + path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    @discardableResult
    func commit(_ message: String, in repository: String) async throws -> ObjectID {
        try await runGit("add", "--all", in: repository)
        try await runGit("commit", "--quiet", "--message=" + message, in: repository)
        return try #require(ObjectID(hex: try await runGit("rev-parse", "HEAD", in: repository)))
    }

    func changedLines(_ file: DiffFile, from source: PatchSource, _ session: RepositorySession) async throws -> [String] {
        let patch = try await session.patch(of: file, from: source)
        return patch.lines.filter { $0.kind == .added || $0.kind == .removed }.map {
            ($0.kind == .added ? "+" : "-") + String(decoding: patch.text(of: $0), as: UTF8.self)
        }
    }

    @Test func comparesTwoCommitsAsOneDiff() async throws {
        let (session, repository) = try await makeRepository()
        let first = try #require(ObjectID(hex: try await runGit("rev-parse", "HEAD", in: repository)))
        try write("one\nTWO\nthree\n", to: "a.txt", in: repository)
        try await commit("Second", in: repository)
        try write("one\nTWO\nthree\nfour\n", to: "a.txt", in: repository)
        try write("new\n", to: "b.txt", in: repository)
        let third = try await commit("Third", in: repository)

        let files = try await session.changedFiles(from: first, to: third)
        #expect(files.map(\.path) == ["a.txt", "b.txt"])
        #expect(files.map(\.lines) == [DiffFile.LineCounts(added: 2, removed: 1), DiffFile.LineCounts(added: 1, removed: 0)])
        let source = PatchSource.commits(from: first, to: third)
        #expect(try await changedLines(files[0], from: source, session) == ["-two", "+TWO", "+four"])

        // Swapped, the same lines go the other way.
        let back = try await session.changedFiles(from: third, to: first)
        #expect(back.map(\.status) == [.modified, .deleted])
    }

    @Test func comparesWithNothingForTheParentOfARootCommit() async throws {
        let (session, repository) = try await makeRepository()
        let first = try #require(ObjectID(hex: try await runGit("rev-parse", "HEAD", in: repository)))
        let files = try await session.changedFiles(from: nil, to: first)
        #expect(files.map(\.path) == ["a.txt"])
        #expect(files.map(\.status) == [.added])
        #expect(try await changedLines(files[0], from: .commits(from: nil, to: first), session) == ["+one", "+two", "+three"])
    }

    @Test func readsAStashsStagedUnstagedAndUntrackedFiles() async throws {
        let (session, repository) = try await makeRepository()
        try write("one\ntwo\nstaged\n", to: "a.txt", in: repository)
        try await runGit("add", "a.txt", in: repository)
        try write("one\ntwo\nstaged\nunstaged\n", to: "a.txt", in: repository)
        try write("untracked\n", to: "new/c.txt", in: repository)
        try await runGit("stash", "push", "--include-untracked", "--quiet", "--message=Try it", in: repository)
        let stash = try #require(ObjectID(hex: try await runGit("rev-parse", "stash@{0}", in: repository)))
        let head = try #require(ObjectID(hex: try await runGit("rev-parse", "HEAD", in: repository)))

        let contents = try await session.stashContents(stash)
        #expect(contents.base == head)
        #expect(contents.parts.map(\.group) == [.staged, .unstaged, .untracked])
        #expect(contents.parts.map { $0.files.map(\.path) } == [["a.txt"], ["a.txt"], ["new/c.txt"]])
        #expect(contents.fileCount == 3)
        #expect(try await changedLines(contents.parts[0].files[0], from: contents.parts[0].source, session) == ["-three", "+staged"])
        #expect(try await changedLines(contents.parts[1].files[0], from: contents.parts[1].source, session) == ["+unstaged"])
        #expect(try await changedLines(contents.parts[2].files[0], from: contents.parts[2].source, session) == ["+untracked"])
    }

    @Test func aStashWithoutUntrackedFilesLeavesOutWhatsEmpty() async throws {
        let (session, repository) = try await makeRepository()
        try write("one\nchanged\nthree\n", to: "a.txt", in: repository)
        try await runGit("stash", "push", "--quiet", in: repository)
        let stash = try #require(ObjectID(hex: try await runGit("rev-parse", "stash@{0}", in: repository)))

        let contents = try await session.stashContents(stash)
        #expect(contents.parts.map(\.group) == [.unstaged])
    }

    @Test func aCommitThatIsntAStashSaysSo() async throws {
        let (session, repository) = try await makeRepository()
        let head = try #require(ObjectID(hex: try await runGit("rev-parse", "HEAD", in: repository)))
        await #expect(throws: RepositoryError.notAStash(head)) {
            try await session.stashContents(head)
        }
    }

    @Test func reviewsABranchSinceItLeftMain() async throws {
        let (session, repository) = try await makeRepository()
        let base = try #require(ObjectID(hex: try await runGit("rev-parse", "HEAD", in: repository)))
        try await runGit("switch", "--quiet", "--create", "agent/fix", in: repository)
        try write("fix\n", to: "fix.txt", in: repository)
        let fix = try await commit("Fix it", in: repository)
        try write("fix\nmore\n", to: "fix.txt", in: repository)
        let more = try await commit("Fix more", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
        try write("main\n", to: "main.txt", in: repository)
        try await commit("Move main on", in: repository)

        let review = try await session.review(branch: "refs/heads/agent/fix", against: ["refs/heads/main"])
        #expect(review.tip == more)
        #expect(review.base == base)
        #expect(review.commits == [more, fix])
        #expect(!review.hasMore)
        // main's own commit isn't part of it.
        let files = try await session.changedFiles(from: review.base, to: review.tip)
        #expect(files.map(\.path) == ["fix.txt"])

        let limited = try await session.review(branch: "refs/heads/agent/fix", against: ["refs/heads/main"], limit: 1)
        #expect(limited.commits == [more])
        #expect(limited.hasMore)
    }

    @Test func theBaseIsTheLatestThatAnyOfTheOthersShares() async throws {
        let (session, repository) = try await makeRepository()
        // origin/main is ahead of main, and the branch left it there.
        try write("ahead\n", to: "ahead.txt", in: repository)
        let ahead = try await commit("Ahead", in: repository)
        try await runGit("update-ref", "refs/remotes/origin/main", "HEAD", in: repository)
        try await runGit("reset", "--quiet", "--hard", "HEAD~1", in: repository)
        try await runGit("switch", "--quiet", "--create", "feature", "origin/main", in: repository)
        try write("feature\n", to: "feature.txt", in: repository)
        let feature = try await commit("Feature", in: repository)

        let review = try await session.review(branch: "refs/heads/feature", against: ["refs/heads/main", "refs/remotes/origin/main"])
        #expect(review.base == ahead)
        #expect(review.commits == [feature])
    }

    @Test func aBranchThatsGoneSaysSo() async throws {
        let (session, _) = try await makeRepository()
        await #expect(throws: RepositoryError.noSuchRef("refs/heads/gone")) {
            try await session.review(branch: "refs/heads/gone", against: ["refs/heads/main"])
        }
    }

    @Test func historiesWithNothingInCommonHaveNoBase() async throws {
        let (session, repository) = try await makeRepository()
        try await runGit("switch", "--quiet", "--orphan", "other", in: repository)
        try write("other\n", to: "other.txt", in: repository)
        let other = try await commit("Other", in: repository)

        let review = try await session.review(branch: "refs/heads/other", against: ["refs/heads/main"])
        #expect(review.base == nil)
        #expect(review.commits == [other])
    }
}
