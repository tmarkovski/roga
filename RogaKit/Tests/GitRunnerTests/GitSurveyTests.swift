import Foundation
import Testing
import TestSupport
@testable import GitRunner

/// Every git on a Mac, as setup and Settings list them: the same places
/// `locate` looks, in the same order, each with its version.
@Suite(.timeLimit(.minutes(1)))
struct GitSurveyTests {
    /// A folder with a fake git that reports `version`.
    func folder(withGit version: String) throws -> String {
        let folder = try makeTemporaryFolder()
        try makeScript("echo 'git version \(version)'", in: folder)
        return folder.plainPath
    }

    func survey(
        searchPath: [String],
        wellKnown: [String] = [],
        developerToolsGit: String = "/nonexistent/git",
        commandLineToolsGit: String = "/nonexistent/tools/usr/bin/git",
        developerToolsFolder: String? = "/Applications/Xcode.app/Contents/Developer"
    ) async -> GitSurvey {
        await GitInstallation.survey(
            searchPath: searchPath.joined(separator: ":"),
            wellKnownDirectories: wellKnown,
            developerToolsGit: developerToolsGit,
            commandLineToolsGit: commandLineToolsGit,
            developerToolsFolder: { developerToolsFolder }
        )
    }

    @Test func listsEveryGitInTheOrderRogaLooksAndRecommendsTheFirstItCanUse() async throws {
        let old = try folder(withGit: "2.33.0")
        let supported = try folder(withGit: "2.45.1 (Apple Git-150)")
        let broken = try makeTemporaryFolder()
        try makeScript("exit 1", in: broken)
        let homebrew = try folder(withGit: "2.52.0")
        let survey = await survey(searchPath: [old, supported, broken.plainPath], wellKnown: [homebrew])
        #expect(survey.copies == [
            FoundGit(executable: old + "/git", version: GitVersion(major: 2, minor: 33, patch: 0)),
            FoundGit(executable: supported + "/git", version: GitVersion(major: 2, minor: 45, patch: 1)),
            FoundGit(executable: broken.plainPath + "/git", version: nil),
            FoundGit(executable: homebrew + "/git", version: GitVersion(major: 2, minor: 52, patch: 0)),
        ])
        #expect(survey.copies.map(\.isUsable) == [false, true, false, true])
        #expect(survey.recommended?.executable == supported + "/git")
        // A terminal runs the first one, whether or not Roga can use it.
        #expect(survey.firstInPath == old + "/git")
        #expect(survey.searchPath == [old, supported, broken.plainPath].joined(separator: ":"))
        #expect(!survey.developerToolsMissing)
    }

    @Test func recommendsTheGitThatLocateFinds() async throws {
        let old = try folder(withGit: "2.40.0")
        let first = try folder(withGit: "2.44.0")
        let newer = try folder(withGit: "2.54.0")
        let survey = await survey(searchPath: [old, first, newer])
        let located = try await GitInstallation.locate(
            configuredPath: nil,
            searchPath: [old, first, newer].joined(separator: ":"),
            wellKnownDirectories: [],
            developerToolsGit: "/nonexistent/git",
            developerToolsInstalled: { true }
        )
        #expect(survey.recommended?.executable == located.executable)
        #expect(survey.recommended?.version == located.version)
    }

    @Test func leavesOutApplesGitWithoutTheDeveloperTools() async throws {
        let apple = try folder(withGit: "2.54.0 (Apple Git-157)")
        let homebrew = try folder(withGit: "2.52.0")
        let without = await survey(searchPath: [apple], wellKnown: [homebrew], developerToolsGit: apple + "/git", developerToolsFolder: nil)
        #expect(without.copies.map(\.executable) == [homebrew + "/git"])
        #expect(without.developerToolsMissing)
        #expect(without.developerToolsFolder == nil)
        // It's still what a terminal would run.
        #expect(without.firstInPath == apple + "/git")

        let with = await survey(searchPath: [apple], wellKnown: [homebrew], developerToolsGit: apple + "/git")
        #expect(with.copies.map(\.executable) == [apple + "/git", homebrew + "/git"])
        #expect(!with.developerToolsMissing)
        #expect(with.developerToolsFolder == "/Applications/Xcode.app/Contents/Developer")
    }

    @Test func addsTheCommandLineToolsGitUnlessApplesGitRunsIt() async throws {
        let apple = try folder(withGit: "2.54.0 (Apple Git-157)")
        let tools = try makeTemporaryFolder()
        let bin = tools.appending(path: "usr/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let toolsGit = try makeScript("echo 'git version 2.50.1 (Apple Git-155)'", in: bin)

        // With Xcode chosen, the tools' git is a git of its own, found last.
        let withXcode = await survey(searchPath: [apple], developerToolsGit: apple + "/git", commandLineToolsGit: toolsGit)
        #expect(withXcode.copies.map(\.executable) == [apple + "/git", toolsGit])
        #expect(withXcode.copies.last?.version == GitVersion(major: 2, minor: 50, patch: 1))

        // With the tools chosen, Apple's git is that git, so it's listed once.
        let withTools = await survey(searchPath: [apple], developerToolsGit: apple + "/git", commandLineToolsGit: toolsGit, developerToolsFolder: tools.plainPath)
        #expect(withTools.copies.map(\.executable) == [apple + "/git"])
    }

    @Test func findsNothingWhereThereIsNoGit() async throws {
        let empty = try makeTemporaryFolder().plainPath
        let survey = await survey(searchPath: [empty])
        #expect(survey.copies.isEmpty)
        #expect(survey.recommended == nil)
        #expect(survey.firstInPath == nil)
    }
}
