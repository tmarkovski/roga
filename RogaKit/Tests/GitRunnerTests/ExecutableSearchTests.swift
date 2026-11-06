import Foundation
import Testing
@testable import GitRunner

@Suite(.timeLimit(.minutes(1)))
struct ExecutableSearchTests {
    @Test func findsTheNameInEachFolderOfThePathAndThenTheWellKnownPaths() throws {
        let first = try makeTemporaryFolder()
        let second = try makeTemporaryFolder()
        let elsewhere = try makeTemporaryFolder()
        let a = try makeScript("exit 0", named: "claude", in: first)
        let b = try makeScript("exit 0", named: "claude", in: second)
        let c = try makeScript("exit 0", named: "claude", in: elsewhere)
        let found = ExecutableSearch.candidates(
            named: ["claude"],
            searchPath: [first.plainPath, second.plainPath].joined(separator: ":"),
            wellKnown: [c]
        )
        #expect(found == [a, b, c])
    }

    @Test func triesEveryNameInAFolderBeforeTheNextFolder() throws {
        let first = try makeTemporaryFolder()
        let second = try makeTemporaryFolder()
        let firstB = try makeScript("exit 0", named: "b", in: first)
        let secondA = try makeScript("exit 0", named: "a", in: second)
        let firstA = try makeScript("exit 0", named: "a", in: first)
        let found = ExecutableSearch.candidates(
            named: ["a", "b"],
            searchPath: first.plainPath + ":" + second.plainPath,
            wellKnown: []
        )
        #expect(found == [firstA, firstB, secondA])
    }

    @Test func skipsRelativePathsFoldersAndFilesThatCantRun() throws {
        let folder = try makeTemporaryFolder()
        let notExecutable = folder.appending(path: "plain")
        try FileManager.default.createDirectory(at: notExecutable, withIntermediateDirectories: true)
        try "echo".write(to: notExecutable.appending(path: "codex"), atomically: true, encoding: .utf8)
        let aFolder = try makeTemporaryFolder()
        try FileManager.default.createDirectory(at: aFolder.appending(path: "codex"), withIntermediateDirectories: true)
        let usable = try makeScript("exit 0", named: "codex", in: try makeTemporaryFolder())
        let found = ExecutableSearch.candidates(
            named: ["codex"],
            searchPath: ["", "relative", "~/bin", notExecutable.plainPath, aFolder.plainPath].joined(separator: ":"),
            wellKnown: ["codex", "/nonexistent/codex", usable]
        )
        #expect(found == [usable])
    }

    @Test func keepsOnlyTheFirstPathToEachFile() throws {
        let folder = try makeTemporaryFolder()
        let program = try makeScript("exit 0", named: "codex", in: folder)
        let link = try makeTemporaryFolder().appending(path: "bin")
        try FileManager.default.createSymbolicLink(atPath: link.plainPath, withDestinationPath: folder.plainPath)
        let found = ExecutableSearch.candidates(
            named: ["codex"],
            searchPath: [link.plainPath, folder.plainPath, folder.plainPath + "/"].joined(separator: ":"),
            wellKnown: [program]
        )
        #expect(found == [link.plainPath + "/codex"])
    }

    @Test func resolvesRealPaths() throws {
        let folder = try makeTemporaryFolder()
        let program = try makeScript("exit 0", named: "claude", in: folder)
        let link = folder.appending(path: "link").plainPath
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: program)
        #expect(ExecutableSearch.realPath(link) == program)
        #expect(ExecutableSearch.realPath(folder.plainPath + "/./claude") == program)
        #expect(ExecutableSearch.realPath("/nonexistent/claude") == "/nonexistent/claude")
        #expect(ExecutableSearch.isExecutableFile(link))
        #expect(!ExecutableSearch.isExecutableFile(folder.plainPath))
    }
}
