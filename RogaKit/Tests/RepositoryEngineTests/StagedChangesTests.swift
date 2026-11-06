import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Reading what's staged for a commit message, and cutting it down to a
/// budget, against real git.
@Suite(.timeLimit(.minutes(1)))
struct StagedChangesTests {
    /// A new repository with `files` in its first commit, or with no commits
    /// when there are none.
    func makeRepository(files: [String: String] = ["a.txt": "one\ntwo\n"], git: Git? = nil) async throws -> (RepositorySession, String) {
        let repository = try makeTemporaryFolder() + "/repository"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: repository)
        try await runGit("config", "user.name", "Ana", in: repository)
        try await runGit("config", "user.email", "ana@example.com", in: repository)
        for (path, text) in files {
            try write(text, to: path, in: repository)
        }
        if !files.isEmpty {
            try await runGit("add", "--all", in: repository)
            try await runGit("commit", "--quiet", "--message=First", in: repository)
        }
        let git = if let git { git } else { try await TestGit.make() }
        return (try await RepositorySession.open(containing: repository, git: git), repository)
    }

    func write(_ text: String, to path: String, in repository: String) throws {
        try write(Data(text.utf8), to: path, in: repository)
    }

    func write(_ data: Data, to path: String, in repository: String) throws {
        let file = URL(filePath: repository + "/" + path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func stage(_ repository: String) async throws {
        try await runGit("add", "--all", in: repository)
    }

    func file(_ path: String, in changes: StagedChanges) throws -> StagedChanges.File {
        try #require(changes.files.first { $0.path == path })
    }

    /// Lines numbered from 1, so that changing a few far apart makes hunks of
    /// their own.
    func numberedLines(_ count: Int, changing changed: Set<Int> = []) -> String {
        (1...count).map { changed.contains($0) ? "line \($0) changed\n" : "line \($0)\n" }.joined()
    }

    // MARK: What's staged

    @Test func readsAChangedFile() async throws {
        let (session, repository) = try await makeRepository()
        try write("one\ntwo\nthree\n", to: "a.txt", in: repository)
        try write("not staged\n", to: "b.txt", in: repository)
        try await runGit("add", "a.txt", in: repository)
        let changes = try await session.stagedChanges(in: repository, amending: false)
        #expect(changes.files == [.init(path: "a.txt", status: "M", added: 1, deleted: 0)])
        #expect(changes.patch.hasPrefix("diff --git a/a.txt b/a.txt\n"))
        #expect(changes.patch.contains("\n+three\n"))
        #expect(!changes.patch.contains("not staged"))
        #expect(!changes.isCut)
        #expect(changes.files[0].note == nil)
    }

    @Test func readsARenamedFile() async throws {
        let (session, repository) = try await makeRepository(files: ["old.txt": numberedLines(10)])
        try await runGit("mv", "old.txt", "new.txt", in: repository)
        try write(numberedLines(10, changing: [10]), to: "new.txt", in: repository)
        try await stage(repository)
        let changes = try await session.stagedChanges(in: repository, amending: false)
        #expect(changes.files == [.init(path: "new.txt", oldPath: "old.txt", status: "R", added: 1, deleted: 1)])
        #expect(changes.patch.hasPrefix("diff --git a/old.txt b/new.txt\n"))
        #expect(changes.patch.contains("rename from old.txt\nrename to new.txt\n"))
        #expect(changes.patch.contains("+line 10 changed\n"))
    }

    @Test func leavesOutABinaryFile() async throws {
        let (session, repository) = try await makeRepository()
        try write(Data([0, 1, 2, 3]), to: "image.bin", in: repository)
        try write("one\ntwo\nthree\n", to: "a.txt", in: repository)
        try await stage(repository)
        let changes = try await session.stagedChanges(in: repository, amending: false)
        let binary = try file("image.bin", in: changes)
        #expect(binary.leftOut == .binary)
        #expect(binary.added == nil && binary.deleted == nil)
        #expect(binary.note == "binary, not shown")
        #expect(changes.patch.contains("diff --git a/image.bin b/image.bin\n[binary, not shown]\n"))
        #expect(!changes.patch.contains("Binary files"))
        #expect(try file("a.txt", in: changes).leftOut == nil)
        // Leaving out a kind of file isn't cutting for length.
        #expect(!changes.isCut)
    }

    @Test func showsALockfileWhenItsAllThatsStaged() async throws {
        let (session, repository) = try await makeRepository(files: ["package-lock.json": "{\n  \"a\": 1\n}\n"])
        try write("{\n  \"a\": 2\n}\n", to: "package-lock.json", in: repository)
        try await stage(repository)
        let changes = try await session.stagedChanges(in: repository, amending: false)
        #expect(changes.files.map(\.leftOut) == [nil])
        #expect(changes.patch.contains("+  \"a\": 2\n"))
    }

    @Test func leavesOutLockfilesAndGeneratedFilesBesideCode() async throws {
        let (session, repository) = try await makeRepository(files: [
            "package-lock.json": "{}\n", "App.xcodeproj/project.pbxproj": "a\n", "web/app.min.js": "a\n",
            "web/app.js.map": "a\n", "Sources/main.swift": "print(1)\n", "admin.js": "a\n",
        ])
        try write("{\"lock\": true}\n", to: "package-lock.json", in: repository)
        try write("b\n", to: "App.xcodeproj/project.pbxproj", in: repository)
        try write("b\n", to: "web/app.min.js", in: repository)
        try write("b\n", to: "web/app.js.map", in: repository)
        try write("b\n", to: "admin.js", in: repository)
        try write("print(2)\n", to: "Sources/main.swift", in: repository)
        try await stage(repository)
        let changes = try await session.stagedChanges(in: repository, amending: false)
        #expect(try file("package-lock.json", in: changes).leftOut == .lockfile)
        #expect(try file("App.xcodeproj/project.pbxproj", in: changes).leftOut == .generated)
        #expect(try file("web/app.min.js", in: changes).leftOut == .generated)
        #expect(try file("web/app.js.map", in: changes).leftOut == .generated)
        #expect(try file("admin.js", in: changes).leftOut == nil)
        #expect(try file("Sources/main.swift", in: changes).leftOut == nil)
        #expect(try file("package-lock.json", in: changes).added == 1)
        #expect(changes.patch.contains("diff --git a/package-lock.json b/package-lock.json\n[lockfile, not shown]\n"))
        #expect(changes.patch.contains("diff --git a/web/app.min.js b/web/app.min.js\n[generated, not shown]\n"))
        #expect(!changes.patch.contains("lock\": true"))
        #expect(changes.patch.contains("+print(2)\n"))
        #expect(changes.patch.contains("+b\n"), "admin.js is shown")
        #expect(!changes.isCut)
    }

    @Test func readsTheFirstCommitAgainstTheEmptyTree() async throws {
        let (session, repository) = try await makeRepository(files: [:])
        try write("hello\n", to: "hello.txt", in: repository)
        try await stage(repository)
        let changes = try await session.stagedChanges(in: repository, amending: false)
        #expect(changes.files == [.init(path: "hello.txt", status: "A", added: 1, deleted: 0)])
        #expect(changes.patch.contains("new file mode 100644\n"))
        // Amending with no commit to amend compares with the empty tree too.
        #expect(try await session.stagedChanges(in: repository, amending: true).files == changes.files)
    }

    @Test func amendingComparesWithTheParentOfHead() async throws {
        let (session, repository) = try await makeRepository()
        try write("one\ntwo\nthree\n", to: "a.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Second", in: repository)
        try write("new\n", to: "b.txt", in: repository)
        try await stage(repository)

        let plain = try await session.stagedChanges(in: repository, amending: false)
        #expect(plain.files.map(\.path) == ["b.txt"])
        // The amended commit holds both its own change and what's staged now.
        let amending = try await session.stagedChanges(in: repository, amending: true)
        #expect(amending.files.map(\.path) == ["a.txt", "b.txt"])
        #expect(amending.patch.contains("+three\n"))
        #expect(amending.digest != plain.digest)
    }

    @Test func amendingTheFirstCommitComparesWithTheEmptyTree() async throws {
        let (session, repository) = try await makeRepository()
        let changes = try await session.stagedChanges(in: repository, amending: true)
        #expect(changes.files == [.init(path: "a.txt", status: "A", added: 2, deleted: 0)])
    }

    @Test func readsNothingWhenNothingIsStaged() async throws {
        let (session, repository) = try await makeRepository()
        try write("changed\n", to: "a.txt", in: repository)
        let changes = try await session.stagedChanges(in: repository, amending: false)
        #expect(changes.files.isEmpty)
        #expect(changes.patch.isEmpty)
        #expect(!changes.isCut)
    }

    @Test func matchesSectionsToFilesWithQuotedNamesAndAChangeOfKind() async throws {
        let (session, repository) = try await makeRepository(files: ["kind.txt": "text\n", "a.txt": "one\n"])
        // A file that becomes a symbolic link has two sections, and a name
        // with a tab or a quote is quoted in its header. Neither may make the
        // lockfile after them lose its place.
        try FileManager.default.removeItem(atPath: repository + "/kind.txt")
        try FileManager.default.createSymbolicLink(atPath: repository + "/kind.txt", withDestinationPath: "a.txt")
        try write(Data([0, 1]), to: "t\tab.bin", in: repository)
        try write("quote\n", to: "say \"hi\".txt", in: repository)
        try write("{}\n", to: "z/yarn.lock", in: repository)
        try write("ü\n", to: "čćž.txt", in: repository)
        try await stage(repository)
        let changes = try await session.stagedChanges(in: repository, amending: false)
        #expect(try file("kind.txt", in: changes).status == "T")
        #expect(try file("t\tab.bin", in: changes).leftOut == .binary)
        #expect(try file("z/yarn.lock", in: changes).leftOut == .lockfile)
        #expect(try file("say \"hi\".txt", in: changes).leftOut == nil)
        #expect(changes.patch.contains("diff --git \"a/t\\tab.bin\" \"b/t\\tab.bin\"\n[binary, not shown]\n"))
        #expect(changes.patch.contains("diff --git a/z/yarn.lock b/z/yarn.lock\n[lockfile, not shown]\n"))
        #expect(changes.patch.contains("+quote\n"))
        #expect(changes.patch.contains("diff --git a/čćž.txt b/čćž.txt\n"), "paths aren't escaped")
        #expect(changes.patch.contains("-text\n") && changes.patch.contains("+a.txt\n"), "both sections of kind.txt")
    }

    @Test func readsStagedFilesBesideAConflict() async throws {
        let (session, repository) = try await makeRepository()
        try await runGit("switch", "--quiet", "-c", "other", in: repository)
        try write("theirs\n", to: "a.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Theirs", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
        try write("ours\n", to: "a.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Ours", in: repository)
        var merge = GitCommand("merge", "other", in: repository)
        merge.successStatuses = [1]
        _ = try await TestGit.make().run(merge)
        try write("new\n", to: "b.txt", in: repository)
        try await runGit("add", "b.txt", in: repository)
        let changes = try await session.stagedChanges(in: repository, amending: false)
        #expect(changes.files.map(\.status) == ["U", "A"])
        #expect(try file("a.txt", in: changes).leftOut == nil)
        #expect(changes.patch.contains("* Unmerged path a.txt\n"))
        #expect(changes.patch.contains("+new\n"))
    }

    // MARK: Cutting to the budget

    @Test func cutsLongLinesWhenOverTheBudget() async throws {
        let (session, repository) = try await makeRepository()
        let long = String(repeating: "é", count: 1000)
        try write("one\n\(long)\n", to: "a.txt", in: repository)
        try await stage(repository)

        let roomy = try await session.stagedChanges(in: repository, amending: false)
        #expect(roomy.patch.contains("+\(long)\n"), "a patch within the budget is left as it is")
        #expect(!roomy.isCut)

        let changes = try await session.stagedChanges(in: repository, amending: false, budget: 1000)
        let cut = "+" + String(repeating: "é", count: 255) + " [rest of line cut]\n"
        #expect(changes.patch.contains(cut))
        #expect(changes.patch.utf8.count <= 1000)
        #expect(changes.isCut)
        #expect(changes.digest == roomy.digest, "the digest is of what git printed")
        #expect(try file("a.txt", in: changes).leftOut == nil)
    }

    @Test func dropsHunksFromTheFileWithTheMost() async throws {
        let (session, repository) = try await makeRepository(files: [
            "many.txt": numberedLines(200), "few.txt": numberedLines(40),
        ])
        try write(numberedLines(200, changing: [10, 50, 90, 130, 170]), to: "many.txt", in: repository)
        try write(numberedLines(40, changing: [5, 30]), to: "few.txt", in: repository)
        try await stage(repository)
        let full = try await session.stagedChanges(in: repository, amending: false)
        #expect(full.patch.components(separatedBy: "\n@@ ").count - 1 == 7)

        // many.txt's last two hunks take 216 bytes, and the marker that takes
        // their place 38, so dropping them is just enough. few.txt has fewer,
        // so it keeps both of its own.
        let budget = full.patch.utf8.count - 150
        let changes = try await session.stagedChanges(in: repository, amending: false, budget: budget)
        #expect(changes.isCut)
        #expect(changes.patch.utf8.count <= budget)
        let many = try file("many.txt", in: changes)
        let few = try file("few.txt", in: changes)
        #expect(many.hunksLeftOut == 2)
        #expect(few.hunksLeftOut == 0)
        #expect(many.note == "2 hunks not shown")
        #expect(changes.patch.contains("+line 10 changed\n"), "a file keeps its first hunk")
        #expect(!changes.patch.contains("+line 170 changed\n"), "the last hunk goes first")
        #expect(changes.patch.contains("[2 more hunks in this file not shown]\n"))
        #expect(changes.patch.contains("+line 30 changed\n"))
    }

    @Test func leavesOutWholeFilesWhenTheirFirstHunksDontFit() async throws {
        let (session, repository) = try await makeRepository(files: ["small.txt": "one\n"])
        try write(numberedLines(400), to: "big.txt", in: repository)
        try write("two\n", to: "small.txt", in: repository)
        try await stage(repository)
        let changes = try await session.stagedChanges(in: repository, amending: false, budget: 1000)
        #expect(changes.isCut)
        #expect(try file("big.txt", in: changes).leftOut == .tooLong)
        #expect(try file("big.txt", in: changes).note == "too long, not shown")
        #expect(try file("small.txt", in: changes).leftOut == nil)
        #expect(changes.patch.contains("diff --git a/big.txt b/big.txt\n[too long, not shown]\n"))
        #expect(changes.patch.contains("+two\n"))
        #expect(changes.patch.utf8.count <= 1000)
    }

    @Test func leavingOutABigFileLeavesTheOthersTheirHunks() async throws {
        // A new file has one hunk, so dropping hunks can't shrink it. Leaving
        // it out must not first cost the small file all but its first hunk,
        // when the small file fits whole once the big one is gone.
        let (session, repository) = try await makeRepository(files: ["small.txt": numberedLines(40)])
        try write(numberedLines(40, changing: [5, 20, 35]), to: "small.txt", in: repository)
        try write(numberedLines(400), to: "big.txt", in: repository)
        try await stage(repository)
        let changes = try await session.stagedChanges(in: repository, amending: false, budget: 1000)
        #expect(changes.isCut)
        #expect(changes.patch.utf8.count <= 1000)
        #expect(try file("big.txt", in: changes).leftOut == .tooLong)
        let small = try file("small.txt", in: changes)
        #expect(small.leftOut == nil)
        #expect(small.hunksLeftOut == 0)
        #expect(small.note == nil)
        for line in [5, 20, 35] {
            #expect(changes.patch.contains("+line \(line) changed\n"))
        }
        #expect(!changes.patch.contains("more hunk"))
    }

    @Test func dropsOnlyTheHunksThatDontFitOnceABigFileIsLeftOut() async throws {
        let (session, repository) = try await makeRepository(files: ["many.txt": numberedLines(200)])
        try write(numberedLines(200, changing: [10, 50, 90, 130, 170]), to: "many.txt", in: repository)
        try await stage(repository)
        let alone = try await session.stagedChanges(in: repository, amending: false)
        try write(numberedLines(400), to: "big.txt", in: repository)
        try await stage(repository)

        // The budget leaves many.txt 150 bytes short once big.txt is down to
        // its marker, which costs it its last two hunks and no more, as in
        // dropsHunksFromTheFileWithTheMost.
        let marker = "diff --git a/big.txt b/big.txt\n[too long, not shown]\n"
        let budget = alone.patch.utf8.count + marker.utf8.count - 150
        let changes = try await session.stagedChanges(in: repository, amending: false, budget: budget)
        #expect(changes.patch.utf8.count <= budget)
        #expect(changes.patch.hasPrefix(marker))
        #expect(try file("big.txt", in: changes).leftOut == .tooLong)
        let many = try file("many.txt", in: changes)
        #expect(many.leftOut == nil)
        #expect(many.hunksLeftOut == 2)
        #expect(changes.patch.contains("+line 90 changed\n"))
        #expect(!changes.patch.contains("+line 130 changed\n"))
        #expect(changes.patch.contains("[2 more hunks in this file not shown]\n"))
    }

    @Test func cutsAPatchWithManyHunksAndFilesQuickly() throws {
        // One file with 20,000 hunks beside 10,000 lockfiles. Cutting it has
        // to take time in proportion to the patch, rather than to the hunks
        // times their lines or the files times the sections, or someone who
        // clicks Generate waits minutes.
        let hunks = 20_000
        let lockfiles = 10_000
        var files = [
            DiffFile(status: .modified, path: "big.txt", oldMode: 0o100644, newMode: 0o100644, lines: .init(added: hunks, removed: hunks)),
        ]
        var patch = "diff --git a/big.txt b/big.txt\nindex 1111111..2222222 100644\n--- a/big.txt\n+++ b/big.txt\n"
        for hunk in 0..<hunks {
            let start = hunk * 10 + 1
            patch += "@@ -\(start),7 +\(start),7 @@\n one\n two\n three\n-old \(hunk)\n+new \(hunk)\n four\n five\n six\n"
        }
        for index in 0..<lockfiles {
            let path = "lock\(index)/yarn.lock"
            files.append(DiffFile(status: .modified, path: path, oldMode: 0o100644, newMode: 0o100644, lines: .init(added: 1, removed: 1)))
            patch += "diff --git a/\(path) b/\(path)\nindex 1111111..2222222 100644\n--- a/\(path)\n+++ b/\(path)\n@@ -1 +1 @@\n-a\n+b\n"
        }
        let budget = 1_000_000

        let clock = ContinuousClock()
        let start = clock.now
        let changes = StagedChanges.cut(files: files, patch: Array(patch.utf8), budget: budget)
        let elapsed = clock.now - start

        #expect(elapsed < .seconds(10), "took \(elapsed)")
        #expect(changes.isCut)
        #expect(changes.patch.utf8.count <= budget)
        #expect(changes.files.dropFirst().allSatisfy { $0.leftOut == .lockfile })
        let big = changes.files[0]
        #expect(big.leftOut == nil)
        #expect(big.hunksLeftOut > 0 && big.hunksLeftOut < hunks)
        #expect(changes.patch.contains("+new 0\n"))
        #expect(changes.patch.contains("[\(big.hunksLeftOut) more hunks in this file not shown]\n"))
        #expect(changes.patch.contains("diff --git a/lock9999/yarn.lock b/lock9999/yarn.lock\n[lockfile, not shown]\n"))
    }

    @Test func sendsTheListOfFilesAloneWhenNothingFits() async throws {
        let (session, repository) = try await makeRepository()
        try write("one\ntwo\nthree\n", to: "a.txt", in: repository)
        try write("{}\n", to: "Cargo.lock", in: repository)
        try await stage(repository)
        let changes = try await session.stagedChanges(in: repository, amending: false, budget: 10)
        #expect(changes.patch.isEmpty)
        #expect(changes.isCut)
        #expect(try file("a.txt", in: changes).leftOut == .tooLong)
        #expect(try file("Cargo.lock", in: changes).leftOut == .lockfile)
        #expect(try file("a.txt", in: changes).added == 1)
    }

    @Test func sendsTheListOfFilesAloneWhenThePatchIsTooLongToRead() async throws {
        let (session, repository) = try await makeRepository()
        try write(numberedLines(1000), to: "a.txt", in: repository)
        try await stage(repository)
        let changes = try await StagedChanges.load(
            in: repository, amending: false, budget: 32_000, format: session.location.format, git: session.git, limit: 1000
        )
        #expect(changes.patch.isEmpty)
        #expect(changes.isCut)
        #expect(changes.files.map(\.leftOut) == [.tooLong])
    }

    // MARK: Noticing changes

    @Test func theDigestChangesWhenWhatsStagedChanges() async throws {
        let (session, repository) = try await makeRepository()
        try write("one\ntwo\nthree\n", to: "a.txt", in: repository)
        try await stage(repository)
        let first = try await session.stagedChanges(in: repository, amending: false)
        let again = try await session.stagedChanges(in: repository, amending: false)
        #expect(first.digest == again.digest)
        #expect(first.digest.count == 16)

        // Changing the worktree alone changes nothing that's staged.
        try write("one\ntwo\nthree\nfour\n", to: "a.txt", in: repository)
        #expect(try await session.stagedChanges(in: repository, amending: false).digest == first.digest)

        try await stage(repository)
        #expect(try await session.stagedChanges(in: repository, amending: false).digest != first.digest)
    }

    @Test func ignoresVariablesThatChangeThePatch() async throws {
        var environment = TestGit.isolatedEnvironment
        environment["GIT_DIFF_OPTS"] = "--unified=0"
        environment["GIT_EXTERNAL_DIFF"] = "/usr/bin/false"
        environment["GIT_EXTERNAL_DIFF_TRUST_EXIT_CODE"] = "1"
        let git = Git(installation: try await TestGit.installation(), environment: environment)
        let (session, repository) = try await makeRepository(files: ["a.txt": numberedLines(9)], git: git)
        try write(numberedLines(9, changing: [5]), to: "a.txt", in: repository)
        try await stage(repository)
        let changes = try await session.stagedChanges(in: repository, amending: false)
        // Three lines of context on each side, and git's own diff.
        #expect(changes.patch.contains("@@ -2,7 +2,7 @@ line 1\n line 2\n line 3\n line 4\n-line 5\n+line 5 changed\n line 6\n line 7\n line 8\n"))
    }

    // MARK: Recent subjects

    @Test func listsRecentSubjectsWithoutMerges() async throws {
        let (session, repository) = try await makeRepository()
        try await runGit("switch", "--quiet", "-c", "side", in: repository)
        try write("side\n", to: "side.txt", in: repository)
        try await stage(repository)
        try await runGit("commit", "--quiet", "--message=Work on the side", in: repository)
        try await runGit("switch", "--quiet", "main", in: repository)
        try write("main\n", to: "main.txt", in: repository)
        try await stage(repository)
        try await runGit("commit", "--quiet", "--message=Work on main", in: repository)
        try await runGit("merge", "--quiet", "--no-edit", "--message=Merge the side", "side", in: repository)
        try write("after\n", to: "after.txt", in: repository)
        try await stage(repository)
        try await runGit("commit", "--quiet", "--message=Add after\n\nWith a body.", in: repository)

        #expect(try await session.recentSubjects(in: repository) == ["Add after", "Work on main", "First"])
        #expect(try await session.recentSubjects(in: repository, count: 2) == ["Add after", "Work on main"])
        #expect(try await session.recentSubjects(in: repository, count: 0) == [])
    }

    @Test func listsNoSubjectsBeforeTheFirstCommit() async throws {
        let (session, repository) = try await makeRepository(files: [:])
        #expect(try await session.recentSubjects(in: repository) == [])
    }

    @Test func readsBesideAFileNamedHead() async throws {
        // A file named HEAD at the top of the worktree makes git refuse a bare
        // `HEAD` as both a revision and a path, unless a `--` ends the
        // revisions. APFS ignores case by default, so a file named `head` is
        // enough there, but this name fails on any file system.
        let (session, repository) = try await makeRepository(files: ["HEAD": "one\n"])
        try write("two\n", to: "HEAD", in: repository)
        try await stage(repository)
        #expect(try await session.recentSubjects(in: repository) == ["First"])
        let changes = try await session.stagedChanges(in: repository, amending: false)
        #expect(changes.files == [.init(path: "HEAD", status: "M", added: 1, deleted: 1)])
        #expect(changes.patch.contains("+two\n"))
        #expect(try await session.stagedChanges(in: repository, amending: true).files.map(\.path) == ["HEAD"])
    }

    @Test func listsNoSubjectsBeforeTheFirstCommitBesideAFileNamedHead() async throws {
        let (session, repository) = try await makeRepository(files: [:])
        try write("one\n", to: "HEAD", in: repository)
        try await stage(repository)
        #expect(try await session.recentSubjects(in: repository) == [])
        #expect(try await session.stagedChanges(in: repository, amending: false).files.map(\.path) == ["HEAD"])
    }
}
