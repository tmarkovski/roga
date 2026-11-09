import Foundation
import GitRunner
import Testing
@testable import AgentEngine

@Suite(.timeLimit(.minutes(1)))
struct AgentInstallationTests {
    func locate(
        _ kind: AgentKind,
        configuredPath: String? = nil,
        searchPath: [String],
        wellKnown: [String] = [],
        timeLimit: Duration = .seconds(5)
    ) async -> AgentLookup {
        await AgentInstallation.locate(
            kind,
            configuredPath: configuredPath,
            searchPath: searchPath.joined(separator: ":"),
            programs: FakeAgent.programs,
            home: "/nonexistent-home",
            wellKnown: wellKnown,
            timeLimit: timeLimit
        )
    }

    func found(_ lookup: AgentLookup) throws -> AgentInstallation {
        guard case .found(let installation) = lookup else {
            Issue.record("Expected an installation, got \(lookup)")
            throw CancellationError()
        }
        return installation
    }

    @Test func claudeUsesTheFirstUsableCopyInPathOrder() async throws {
        let old = try FakeAgent.folder(with: "claude", printing: "2.1.100 (Claude Code)")
        let first = try FakeAgent.folder(with: "claude", printing: "2.1.286 (Claude Code)")
        let newer = try FakeAgent.folder(with: "claude", printing: "2.1.318 (Claude Code)")
        let installation = try found(await locate(.claude, searchPath: [old, first, newer]))
        #expect(installation.kind == .claude)
        #expect(installation.executable == first + "/claude")
        #expect(installation.version == AgentVersion(major: 2, minor: 1, patch: 286))
        #expect(installation.others == [FoundAgent(executable: newer + "/claude", version: AgentVersion(major: 2, minor: 1, patch: 318))])
        #expect(installation.skipped == [
            SkippedAgent(kind: .claude, executable: old + "/claude", reason: .tooOld(AgentVersion(major: 2, minor: 1, patch: 100))),
        ])
    }

    @Test func codexUsesTheNewestCopyWhereverItIs() async throws {
        let homebrew = try FakeAgent.folder(with: "codex", printing: "codex-cli 0.137.0")
        let release = try FakeAgent.folder(with: "codex", printing: "codex-cli 0.166.0")
        let app = try FakeAgent.folder(with: "codex", printing: "codex-cli 0.166.0-alpha.6")
        let installation = try found(await locate(.codex, searchPath: [homebrew], wellKnown: [app + "/codex", release + "/codex"]))
        #expect(installation.executable == release + "/codex")
        #expect(installation.version == AgentVersion(major: 0, minor: 166))
        #expect(installation.others.map(\.executable) == [homebrew + "/codex", app + "/codex"])
        #expect(installation.skipped.isEmpty)
    }

    @Test func aTieGoesToPathOrder() async throws {
        let first = try FakeAgent.folder(with: "codex", printing: "codex-cli 0.166.0")
        let second = try FakeAgent.folder(with: "codex", printing: "codex-cli 0.166.0")
        let installation = try found(await locate(.codex, searchPath: [first, second]))
        #expect(installation.executable == first + "/codex")
    }

    // MARK: Every copy

    func survey(_ kind: AgentKind, searchPath: [String], wellKnown: [String] = []) async -> AgentSurvey {
        await AgentInstallation.survey(
            kind,
            searchPath: searchPath.joined(separator: ":"),
            programs: FakeAgent.programs,
            home: "/nonexistent-home",
            wellKnown: wellKnown,
            timeLimit: .seconds(5)
        )
    }

    @Test func theSurveyListsEveryCopyAndWhyRogaCantUseSome() async throws {
        let old = try FakeAgent.folder(with: "claude", printing: "2.1.100 (Claude Code)")
        let first = try FakeAgent.folder(with: "claude", printing: "2.1.286 (Claude Code)")
        let silent = try FakeAgent.folder()
        try FakeAgent.script("exit 0", named: "claude", in: silent)
        let elsewhere = try FakeAgent.folder(with: "claude", printing: "2.1.318 (Claude Code)")
        let survey = await survey(.claude, searchPath: [old, first, FakeAgent.path(silent)], wellKnown: [elsewhere + "/claude"])

        #expect(survey.kind == .claude)
        #expect(survey.copies.map(\.executable) == [old + "/claude", first + "/claude", FakeAgent.path(silent) + "/claude", elsewhere + "/claude"])
        #expect(survey.copies.map(\.isUsable) == [false, true, false, true])
        // A copy that's too old still says which version it is.
        #expect(survey.copies[0].version == AgentVersion(major: 2, minor: 1, patch: 100))
        #expect(survey.copies[0].skipped?.reason == .tooOld(AgentVersion(major: 2, minor: 1, patch: 100)))
        #expect(survey.copies[2].version == nil)
        #expect(survey.usable.map(\.executable) == [first + "/claude", elsewhere + "/claude"])
        #expect(survey.skipped.map(\.executable) == [old + "/claude", FakeAgent.path(silent) + "/claude"])
        #expect(survey.recommended?.executable == first + "/claude")
        // A terminal runs the first one, whether or not Roga can use it.
        #expect(survey.firstInPath == old + "/claude")
        #expect(survey.searchPath == [old, first, FakeAgent.path(silent)].joined(separator: ":"))
    }

    @Test func theSurveyRecommendsTheCopyLocateFinds() async throws {
        let homebrew = try FakeAgent.folder(with: "codex", printing: "codex-cli 0.137.0")
        let release = try FakeAgent.folder(with: "codex", printing: "codex-cli 0.166.0")
        let app = try FakeAgent.folder(with: "codex", printing: "codex-cli 0.166.0-alpha.6")
        let survey = await survey(.codex, searchPath: [homebrew], wellKnown: [app + "/codex", release + "/codex"])
        // The newest, not the first, and a release before its prerelease.
        #expect(survey.recommended?.executable == release + "/codex")
        #expect(survey.firstInPath == homebrew + "/codex")
        #expect(survey.lookup == (await locate(.codex, searchPath: [homebrew], wellKnown: [app + "/codex", release + "/codex"])))
    }

    @Test func aSurveyOfNothingComesToNotFoundAndOneOfUnusableCopiesSaysWhy() async throws {
        let empty = try FakeAgent.folder()
        let none = await survey(.codex, searchPath: [FakeAgent.path(empty)])
        #expect(none.copies.isEmpty)
        #expect(none.recommended == nil)
        #expect(none.lookup == .notFound)

        let old = try FakeAgent.folder(with: "codex", printing: "codex-cli 0.100.0")
        let onlyOld = await survey(.codex, searchPath: [old])
        #expect(onlyOld.recommended == nil)
        #expect(onlyOld.lookup == .unusable([
            SkippedAgent(kind: .codex, executable: old + "/codex", reason: .tooOld(AgentVersion(major: 0, minor: 100))),
        ]))
    }

    @Test func searchesTheWellKnownPathsAfterThePath() async throws {
        let onPath = try FakeAgent.folder(with: "claude", printing: "2.1.200 (Claude Code)")
        let wellKnown = try FakeAgent.folder(with: "claude", printing: "2.1.300 (Claude Code)")
        #expect(try found(await locate(.claude, searchPath: [onPath], wellKnown: [wellKnown + "/claude"])).executable == onPath + "/claude")
        #expect(try found(await locate(.claude, searchPath: [], wellKnown: [wellKnown + "/claude"])).executable == wellKnown + "/claude")
    }

    @Test func asksEachCopyForItsVersionAtUtilityPriority() async throws {
        let folder = try FakeAgent.folder()
        let log = FakeAgent.path(folder) + "/runs"
        try FakeAgent.script(FakeAgent.recording(to: log, then: "echo 'codex-cli 0.166.0'"), named: "codex", in: folder)
        _ = try found(await locate(.codex, searchPath: [FakeAgent.path(folder)]))
        #expect(FakeAgent.runs(in: log) == [["--version"]])
    }

    @Test func reportsCopiesThatFailCrashOrHang() async throws {
        let failing = try FakeAgent.folder()
        try FakeAgent.script("echo 'Error: unknown option' >&2; exit 2", named: "codex", in: failing)
        let crashing = try FakeAgent.folder()
        try FakeAgent.script(
            "echo 'dyld[4242]: Library not loaded: @rpath/libnode.dylib' >&2; kill -ABRT $$",
            named: "codex",
            in: crashing
        )
        let hanging = try FakeAgent.folder()
        try FakeAgent.script("sleep 30", named: "codex", in: hanging)
        let silent = try FakeAgent.folder()
        try FakeAgent.script("echo 'no version here'", named: "codex", in: silent)
        let old = try FakeAgent.folder(with: "codex", printing: "codex-cli 0.120.0")

        let folders: [String] = [failing, crashing, hanging, silent].map(FakeAgent.path) + [old]
        let lookup = await locate(.codex, searchPath: folders, timeLimit: .milliseconds(500))
        guard case .unusable(let skipped) = lookup else {
            Issue.record("Expected every copy to be unusable, got \(lookup)")
            return
        }
        let paths = folders.map { $0 + "/codex" }
        #expect(skipped.map(\.executable) == paths)
        let reasons: [SkippedAgent.Reason] = [
            .noVersion(status: .exited(2), errorOutput: "Error: unknown option"),
            .noVersion(status: .signaled(6), errorOutput: "dyld[4242]: Library not loaded: @rpath/libnode.dylib"),
            .timedOut,
            .noVersion(status: .exited(0), errorOutput: "no version here"),
            .tooOld(AgentVersion(major: 0, minor: 120, patch: 0)),
        ]
        #expect(skipped.map(\.reason) == reasons)
        let home = NSHomeDirectory()
        let shown = paths.map { $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0 }
        let descriptions = [
            "\(shown[0]) exited with status 2 before saying its version: Error: unknown option",
            "\(shown[1]) stopped by signal 6 before saying its version: Library not loaded: @rpath/libnode.dylib",
            "\(shown[2]) didn't say its version within 5 seconds",
            "\(shown[3]) didn't print a version Roga could read: no version here",
            "\(shown[4]) is Codex 0.120.0, older than 0.131.0",
        ]
        #expect(skipped.map(\.description) == descriptions)
    }

    @Test func abbreviatesTheHomeFolderWhenDescribingACopy() {
        let skipped = SkippedAgent(
            kind: .codex,
            executable: NSHomeDirectory() + "/.local/bin/codex",
            reason: .tooOld(AgentVersion(major: 0, minor: 120, patch: 0))
        )
        #expect(skipped.description == "~/.local/bin/codex is Codex 0.120.0, older than 0.131.0")
        let unstartable = SkippedAgent(kind: .claude, executable: "/opt/claude", reason: .noVersion(status: nil, errorOutput: ""))
        #expect(unstartable.description == "/opt/claude couldn't be started")
    }

    @Test func reportsWhenThereIsNoCopy() async throws {
        let empty = FakeAgent.path(try FakeAgent.folder())
        #expect(await locate(.claude, searchPath: [empty], wellKnown: ["/nonexistent/claude"]) == .notFound)
    }

    @Test func usesTheConfiguredCopyOrNothing() async throws {
        let onPath = try FakeAgent.folder(with: "codex", printing: "codex-cli 0.170.0")
        let configured = try FakeAgent.folder(with: "codex", printing: "codex-cli 0.140.0") + "/codex"
        let installation = try found(await locate(.codex, configuredPath: configured, searchPath: [onPath]))
        #expect(installation.executable == configured)
        #expect(installation.others.isEmpty)

        let tooOld = try FakeAgent.folder(with: "codex", printing: "codex-cli 0.120.0") + "/codex"
        #expect(await locate(.codex, configuredPath: tooOld, searchPath: [onPath])
            == .configuredUnusable(SkippedAgent(kind: .codex, executable: tooOld, reason: .tooOld(AgentVersion(major: 0, minor: 120)))))
        #expect(await locate(.codex, configuredPath: "/nonexistent/codex", searchPath: [onPath]) == .configuredMissing("/nonexistent/codex"))

        // An empty choice in Settings means none.
        #expect(try found(await locate(.codex, configuredPath: "", searchPath: [onPath])).executable == onPath + "/codex")
    }

    @Test func knowsWhereEachAgentIsUsuallyInstalled() {
        #expect(AgentKind.claude.wellKnownPaths(home: "/Users/me") == [
            "/Users/me/.local/bin/claude", "/Users/me/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ])
        #expect(AgentKind.codex.wellKnownPaths(home: "/Users/me") == [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Users/me/.local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        ])
        #expect(AgentKind.claude.executableName == "claude")
        #expect(AgentKind.codex.executableName == "codex")
        #expect(AgentKind.claude.minimumVersion == AgentVersion(major: 2, minor: 1, patch: 169))
        #expect(AgentKind.codex.minimumVersion == AgentVersion(major: 0, minor: 131, patch: 0))
        #expect(!AgentKind.claude.prefersNewest)
        #expect(AgentKind.codex.prefersNewest)
    }

    @Test func findsTheDefaultWellKnownPathsUnderHome() async throws {
        let home = try FakeAgent.folder()
        try FakeAgent.script("echo '2.1.300 (Claude Code)'", named: "claude", in: home.appending(path: ".local/bin"))
        let lookup = await AgentInstallation.locate(.claude, configuredPath: nil, searchPath: "", programs: FakeAgent.programs, home: FakeAgent.path(home))
        #expect(try found(lookup).executable == FakeAgent.path(home) + "/.local/bin/claude")
    }
}
