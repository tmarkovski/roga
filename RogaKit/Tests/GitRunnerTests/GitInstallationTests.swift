import Foundation
import Testing
import TestSupport
@testable import GitRunner

@Suite(.timeLimit(.minutes(1)))
struct GitInstallationTests {
    /// A folder with a fake git that reports `version`.
    func folder(withGit version: String) throws -> String {
        let folder = try makeTemporaryFolder()
        try makeScript("echo 'git version \(version)'", in: folder)
        return folder.plainPath
    }

    func locate(
        configuredPath: String? = nil,
        searchPath: [String],
        wellKnown: [String] = [],
        developerToolsGit: String = "/nonexistent/git",
        developerToolsInstalled: Bool = true
    ) async throws(GitInstallationError) -> GitInstallation {
        try await GitInstallation.locate(
            configuredPath: configuredPath,
            searchPath: searchPath.joined(separator: ":"),
            wellKnownDirectories: wellKnown,
            developerToolsGit: developerToolsGit,
            developerToolsInstalled: { developerToolsInstalled }
        )
    }

    @Test func usesTheFirstSupportedGitAndListsTheOnesItSkipped() async throws {
        let old = try folder(withGit: "2.43.7")
        let supported = try folder(withGit: "2.45.1 (Apple Git-150)")
        let newer = try folder(withGit: "2.52.0")
        let installation = try await locate(searchPath: [old, supported, newer])
        #expect(installation.executable == supported + "/git")
        #expect(installation.version == GitVersion(major: 2, minor: 45, patch: 1))
        #expect(installation.skipped == [.init(executable: old + "/git", version: GitVersion(major: 2, minor: 43, patch: 7))])
        #expect(installation.searchPath == [old, supported, newer].joined(separator: ":"))
    }

    @Test func searchesWellKnownFoldersAfterThePath() async throws {
        let onPath = try folder(withGit: "2.44.0")
        let homebrew = try folder(withGit: "2.52.0")
        #expect(try await locate(searchPath: [onPath], wellKnown: [homebrew]).executable == onPath + "/git")
        #expect(try await locate(searchPath: [], wellKnown: [homebrew]).executable == homebrew + "/git")
    }

    @Test func ignoresRelativeAndRepeatedFolders() async throws {
        let old = try folder(withGit: "2.30.0")
        let supported = try folder(withGit: "2.50.0")
        let installation = try await locate(searchPath: ["", "relative", "~/bin", old, old, supported])
        #expect(installation.executable == supported + "/git")
        #expect(installation.skipped.count == 1)
    }

    @Test func recognizesApplesGitThroughAnyPath() async throws {
        let apple = try folder(withGit: "2.54.0 (Apple Git-157)")
        let link = try makeTemporaryFolder().appending(path: "bin")
        try FileManager.default.createSymbolicLink(atPath: link.plainPath, withDestinationPath: apple)
        for searchPath in [link.plainPath, apple + "/", apple.replacingOccurrences(of: "/var/", with: "/var//")] {
            await #expect(throws: GitInstallationError.notFound(developerToolsMissing: true)) {
                try await locate(searchPath: [searchPath], developerToolsGit: apple + "/git", developerToolsInstalled: false)
            }
        }
    }

    @Test func runsApplesGitOnlyWithTheDeveloperTools() async throws {
        let apple = try folder(withGit: "2.54.0 (Apple Git-157)")
        let appleGit = apple + "/git"
        let withTools = try await locate(searchPath: [apple], developerToolsGit: appleGit, developerToolsInstalled: true)
        #expect(withTools.executable == appleGit)

        await #expect(throws: GitInstallationError.notFound(developerToolsMissing: true)) {
            try await locate(searchPath: [apple], developerToolsGit: appleGit, developerToolsInstalled: false)
        }
        let homebrew = try folder(withGit: "2.52.0")
        let withoutTools = try await locate(
            searchPath: [apple],
            wellKnown: [homebrew],
            developerToolsGit: appleGit,
            developerToolsInstalled: false
        )
        #expect(withoutTools.executable == homebrew + "/git")
    }

    @Test func reportsWhenEveryGitIsTooOld() async throws {
        let old = try folder(withGit: "2.39.5")
        let broken = try makeTemporaryFolder()
        try makeScript("exit 1", in: broken)
        let brokenPath = broken.plainPath
        await #expect(throws: GitInstallationError.unsupported(
            [
                .init(executable: old + "/git", version: GitVersion(major: 2, minor: 39, patch: 5)),
                .init(executable: brokenPath + "/git", version: nil),
            ],
            developerToolsMissing: false
        )) {
            try await locate(searchPath: [old, brokenPath])
        }
    }

    @Test func reportsWhenThereIsNoGit() async throws {
        let empty = try makeTemporaryFolder().plainPath
        await #expect(throws: GitInstallationError.notFound(developerToolsMissing: false)) {
            try await locate(searchPath: [empty])
        }
    }

    @Test func usesTheConfiguredGitOrNothing() async throws {
        let onPath = try folder(withGit: "2.52.0")
        let configured = try folder(withGit: "2.44.2") + "/git"
        #expect(try await locate(configuredPath: configured, searchPath: [onPath]).executable == configured)

        let tooOld = try folder(withGit: "2.40.0") + "/git"
        await #expect(throws: GitInstallationError.configuredGitUnsupported(
            .init(executable: tooOld, version: GitVersion(major: 2, minor: 40, patch: 0))
        )) {
            try await locate(configuredPath: tooOld, searchPath: [onPath])
        }
        await #expect(throws: GitInstallationError.configuredGitMissing("/nonexistent/git")) {
            try await locate(configuredPath: "/nonexistent/git", searchPath: [onPath])
        }
    }

    @Test func findsTheGitTheTestsUse() async throws {
        let installation = try await TestGit.installation()
        #expect(installation.version.isSupported)
        #expect(installation.executable.hasPrefix("/"))
    }
}
