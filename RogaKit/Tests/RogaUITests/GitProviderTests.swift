import AgentEngine
import Foundation
import GitRunner
import Synchronization
import Testing
@testable import RogaUI

/// Finding git, listing every git, and going over to one someone chose. No
/// test here reads the login shell or runs a real git: what the provider
/// finds is made up.
@Suite(.timeLimit(.minutes(1)), .removesTemporaryFolders)
@MainActor
struct GitProviderTests {
    static let searchPath = "/usr/local/bin:/usr/bin"
    static let old = FoundGit(executable: "/usr/local/bin/git", version: GitVersion(major: 2, minor: 33, patch: 0))
    static let apples = FoundGit(executable: "/usr/bin/git", version: GitVersion(major: 2, minor: 54, patch: 0))
    static let homebrew = FoundGit(executable: "/opt/homebrew/bin/git", version: GitVersion(major: 2, minor: 52, patch: 0))
    static let survey = GitSurvey(searchPath: searchPath, copies: [old, apples, homebrew], firstInPath: old.executable)

    /// The paths the provider asked to locate, in order.
    nonisolated final class Asked: Sendable {
        private let paths = Mutex<[String?]>([])
        func add(_ path: String?) { paths.withLock { $0.append(path) } }
        var all: [String?] { paths.withLock { $0 } }
    }

    /// Holds the login shell back until a test lets it answer.
    nonisolated final class Shell: Sendable {
        private let state = Mutex<(answers: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

        func answer() {
            let waiting = state.withLock { state in
                state.answers = true
                defer { state.waiting = [] }
                return state.waiting
            }
            for continuation in waiting { continuation.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let answers = state.withLock { state in
                    if !state.answers { state.waiting.append(continuation) }
                    return state.answers
                }
                if answers { continuation.resume() }
            }
        }
    }

    let defaults: UserDefaults
    let name: String
    let asked = Asked()
    /// The `PATH`s the provider looked for git in, in order.
    let searched = Asked()

    init() {
        (defaults, name) = AgentTestSupport.defaults()
    }

    /// A provider whose `PATH` and gits are made up. Locating with no chosen
    /// path finds Apple's, and a chosen one is found when it's one of
    /// `usable`.
    ///
    /// The login shell says the survey's `PATH` unless `shell` says otherwise.
    func provider(
        survey: GitSurvey = GitProviderTests.survey,
        finds: Bool = true,
        usable: [FoundGit] = [apples, homebrew],
        shell: (@Sendable (_ priority: GitCommand.Priority) async -> (searchPath: String, fromLoginShell: Bool))? = nil
    ) -> GitProvider {
        let (asked, searched) = (asked, searched)
        let (apples, old) = (Self.apples, Self.old)
        return GitProvider(defaults: defaults, finding: GitProvider.Finding(
            searchPath: shell ?? { _ in (survey.searchPath, true) },
            locate: { configured, searchPath in
                asked.add(configured)
                searched.add(searchPath)
                guard let configured else {
                    guard finds, let version = apples.version else {
                        return .failure(.unsupported([.init(executable: old.executable, version: old.version)], developerToolsMissing: false))
                    }
                    return .success(GitInstallation(executable: apples.executable, version: version, searchPath: searchPath))
                }
                guard let found = usable.first(where: { $0.executable == configured }), let version = found.version else {
                    return .failure(.configuredGitMissing(configured))
                }
                return .success(GitInstallation(executable: configured, version: version, searchPath: searchPath))
            },
            survey: { _ in survey }
        ))
    }

    private func settled(_ provider: GitProvider) async {
        #expect(await AgentTestSupport.eventually { !provider.isLooking })
    }

    @Test func findsGitAndThenEveryGit() async {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let provider = provider()
        #expect(provider.isLooking)
        await settled(provider)
        #expect(provider.git?.installation.executable == "/usr/bin/git")
        #expect(provider.survey == Self.survey)
        #expect(provider.searchPath?.path == Self.searchPath)
        #expect(provider.searchPath?.fromLoginShell == true)
        #expect(provider.chosenPath == nil)
        #expect(asked.all == [nil])
        // What the shell said, for the next launch to start from.
        #expect(defaults.string(forKey: GitPreferences.searchPathKey) == Self.searchPath)
    }

    // MARK: The PATH from the last launch (decision 97)

    @Test func findsGitInLastLaunchsPathWhileTheShellStarts() async {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let saved = "/opt/old/bin:/usr/bin"
        defaults.set(saved, forKey: GitPreferences.searchPathKey)
        let shell = Shell()
        let fresh = Self.searchPath
        let priorities = Mutex<[GitCommand.Priority]>([])
        let provider = provider(shell: { priority in
            priorities.withLock { $0.append(priority) }
            await shell.wait()
            return (fresh, true)
        })
        // Windows can open repositories before the shell has said anything.
        #expect(await AgentTestSupport.eventually { provider.git != nil })
        #expect(provider.git?.installation.searchPath == saved)
        #expect(provider.searchPath?.path == saved)
        #expect(provider.isLooking)
        #expect(provider.survey == nil)
        // Nothing waits for the shell now, so it runs at utility priority.
        #expect(priorities.withLock { $0 } == [.utility])

        shell.answer()
        await settled(provider)
        // The shell said something else, so git was found again in that, which
        // the next launch starts from.
        #expect(searched.all == [saved, Self.searchPath])
        #expect(provider.git?.installation.searchPath == Self.searchPath)
        #expect(provider.searchPath?.path == Self.searchPath)
        #expect(defaults.string(forKey: GitPreferences.searchPathKey) == Self.searchPath)
        #expect(provider.survey == Self.survey)
    }

    @Test func theSamePathFromTheShellFindsNothingAgain() async {
        defer { AgentTestSupport.remove(defaults, named: name) }
        defaults.set(Self.searchPath, forKey: GitPreferences.searchPathKey)
        let provider = provider()
        await settled(provider)
        let log = provider.git?.log
        #expect(searched.all == [Self.searchPath])
        #expect(asked.all == [nil])
        #expect(provider.git?.log === log)
        #expect(provider.survey == Self.survey)
    }

    @Test func keepsLastLaunchsPathWhenTheShellSaysNothing() async {
        defer { AgentTestSupport.remove(defaults, named: name) }
        defaults.set(Self.searchPath, forKey: GitPreferences.searchPathKey)
        // The shell didn't answer, so the `PATH` is the one Roga started with.
        let provider = provider(shell: { _ in ("/usr/bin:/bin:/usr/sbin:/sbin", false) })
        await settled(provider)
        #expect(searched.all == [Self.searchPath])
        #expect(provider.searchPath?.path == Self.searchPath)
        #expect(provider.searchPath?.fromLoginShell == true)
        #expect(defaults.string(forKey: GitPreferences.searchPathKey) == Self.searchPath)
    }

    @Test func lookingAgainWaitsForTheShell() async {
        defer { AgentTestSupport.remove(defaults, named: name) }
        defaults.set("/opt/old/bin:/usr/bin", forKey: GitPreferences.searchPathKey)
        let provider = provider()
        await settled(provider)
        provider.lookAgain()
        await settled(provider)
        // Look Again is for after something was installed, which the saved
        // `PATH` may not know about.
        #expect(searched.all == ["/opt/old/bin:/usr/bin", Self.searchPath, Self.searchPath])
    }

    @Test func usesTheGitSomeoneChoseBefore() async {
        defer { AgentTestSupport.remove(defaults, named: name) }
        defaults.set(Self.homebrew.executable, forKey: GitPreferences.programKey)
        let provider = provider()
        await settled(provider)
        #expect(provider.chosenPath == Self.homebrew.executable)
        #expect(provider.git?.installation.executable == Self.homebrew.executable)
        #expect(asked.all == [Self.homebrew.executable])
    }

    @Test func choosingAGitStoresItAndGoesOverToIt() async {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let provider = provider()
        await settled(provider)
        provider.choose(Self.homebrew.executable)
        #expect(provider.chosenPath == Self.homebrew.executable)
        #expect(GitPreferences.program(in: defaults) == Self.homebrew.executable)
        await settled(provider)
        #expect(provider.git?.installation.executable == Self.homebrew.executable)
        // Only the chosen git was asked, with the `PATH` already read.
        #expect(asked.all == [nil, Self.homebrew.executable])
    }

    @Test func goingBackToTheOneRogaFindsAsksNothing() async {
        defer { AgentTestSupport.remove(defaults, named: name) }
        defaults.set(Self.homebrew.executable, forKey: GitPreferences.programKey)
        let provider = provider()
        await settled(provider)
        provider.choose(nil)
        #expect(defaults.object(forKey: GitPreferences.programKey) == nil)
        await settled(provider)
        // The survey already has its version, and the gits passed over.
        #expect(provider.git?.installation.executable == "/usr/bin/git")
        #expect(provider.git?.installation.skipped == [.init(executable: Self.old.executable, version: Self.old.version)])
        #expect(asked.all == [Self.homebrew.executable])
    }

    @Test func aChosenGitRogaCantUseIsReportedAndNotPassedOver() async {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let provider = provider()
        await settled(provider)
        provider.choose("/opt/gone/git")
        await settled(provider)
        #expect(provider.git == nil)
        #expect(provider.failure == .configuredGitMissing("/opt/gone/git"))
        #expect(provider.chosenPath == "/opt/gone/git")
        // Choosing another puts it right.
        provider.choose(nil)
        await settled(provider)
        #expect(provider.git?.installation.executable == "/usr/bin/git")
        #expect(provider.failure == nil)
    }

    @Test func usesAGitOnlyTheSurveyFinds() async {
        defer { AgentTestSupport.remove(defaults, named: name) }
        // Launch's look finds nothing it can use, and the survey finds the
        // Command Line Tools' own git, which launch doesn't look for.
        let tools = FoundGit(executable: "/Library/Developer/CommandLineTools/usr/bin/git", version: GitVersion(major: 2, minor: 50, patch: 1))
        let survey = GitSurvey(searchPath: Self.searchPath, copies: [Self.old, tools], firstInPath: Self.old.executable)
        let provider = provider(survey: survey, finds: false)
        await settled(provider)
        #expect(provider.git?.installation.executable == tools.executable)
        #expect(provider.chosenPath == nil)
    }

    @Test func sayWhyWhenNoGitCanBeUsed() async {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let provider = provider(survey: GitSurvey(searchPath: Self.searchPath, copies: [Self.old], firstInPath: Self.old.executable), finds: false)
        await settled(provider)
        #expect(provider.git == nil)
        #expect(provider.failure == .unsupported([.init(executable: Self.old.executable, version: Self.old.version)], developerToolsMissing: false))
    }

    @Test func lookingAgainKeepsWhatItFoundUntilItsDone() async {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let provider = provider()
        await settled(provider)
        let log = provider.git?.log
        provider.lookAgain()
        // Nothing empties while it looks, so a window doesn't blink.
        #expect(provider.isLooking)
        #expect(provider.git != nil)
        #expect(provider.survey != nil)
        await settled(provider)
        // The same git again is the same `Git`, with its log.
        #expect(provider.git?.log === log)
    }

    // MARK: The menus

    @Test func gitsMenuChoosesAGitAndGoesBackForTheRecommendedOne() async throws {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let provider = provider()
        // Before Roga has looked, there's nothing to list.
        provider.setStateForTests(survey: .some(nil))
        #expect(ProgramMenu.git(provider) == nil)

        provider.setStateForTests(state: .ready(Git(installation: GitInstallation(executable: "/usr/bin/git", version: GitVersion(major: 2, minor: 54, patch: 0), searchPath: Self.searchPath))), survey: Self.survey)
        let menu = try #require(ProgramMenu.git(provider))
        #expect(menu.choices.map(\.executable) == [Self.old, Self.apples, Self.homebrew].map(\.executable))
        #expect(menu.checked == "/usr/bin/git")

        menu.choose(menu.choices[2])
        #expect(provider.chosenPath == Self.homebrew.executable)
        #expect(try #require(ProgramMenu.git(provider)).checked == Self.homebrew.executable)
        menu.choose(menu.choices[1])
        #expect(provider.chosenPath == nil)
        await settled(provider)
    }

    @Test func anAgentsMenuChoosesACopy() throws {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let agents = AgentTestSupport.provider(support: try AgentTestSupport.folder(), defaults: defaults, codexHome: try AgentTestSupport.folder())
        #expect(ProgramMenu.agent(.codex, agents: agents, choose: { _ in }) == nil)

        let homebrew = "/opt/homebrew/bin/codex"
        let app = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let survey = AgentSurvey(kind: .codex, copies: [
            .init(executable: homebrew, version: AgentVersion(major: 0, minor: 166)),
            .init(executable: app, version: AgentVersion(major: 0, minor: 167)),
        ], searchPath: "/opt/homebrew/bin", firstInPath: homebrew)
        agents.setStateForTests(lookups: [.codex: survey.lookup], surveys: [.codex: survey])

        var chosen: [String?] = []
        let menu = try #require(ProgramMenu.agent(.codex, agents: agents, choose: { chosen.append($0) }))
        #expect(menu.label == "Codex installations")
        #expect(menu.checked == app)
        menu.choose(menu.choices[0])
        // The recommended copy is stored as nothing, so Roga keeps choosing.
        menu.choose(menu.choices[1])
        #expect(chosen == [homebrew, nil])
        // There's no Don't use Codex: agents are on or off together
        // (decision 89).
    }

    // MARK: Agents, from what Roga already asked

    @Test func aCopyRogaAlreadyAskedNeedsNoNewLook() throws {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let homebrew = "/opt/homebrew/bin/codex"
        let old = "/usr/local/bin/codex"
        let skipped = SkippedAgent(kind: .codex, executable: old, reason: .tooOld(AgentVersion(major: 0, minor: 100)))
        let survey = AgentSurvey(kind: .codex, copies: [
            .init(executable: homebrew, version: AgentVersion(major: 0, minor: 166)),
            .init(executable: old, version: AgentVersion(major: 0, minor: 100), skipped: skipped),
        ])
        #expect(AgentProvider.lookup(.codex, program: nil, in: survey) == survey.lookup)
        #expect(AgentProvider.lookup(.codex, program: homebrew, in: survey) == .found(AgentInstallation(kind: .codex, executable: homebrew, version: AgentVersion(major: 0, minor: 166))))
        #expect(AgentProvider.lookup(.codex, program: old, in: survey) == .configuredUnusable(skipped))
        // One from somewhere else has to be asked for its version.
        #expect(AgentProvider.lookup(.codex, program: "/opt/tools/codex", in: survey) == nil)

        // Choosing one from the menu shows at once.
        let other = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let both = AgentSurvey(kind: .codex, copies: [
            .init(executable: homebrew, version: AgentVersion(major: 0, minor: 166)),
            .init(executable: other, version: AgentVersion(major: 0, minor: 167)),
        ])
        let agents = AgentTestSupport.provider(support: try AgentTestSupport.folder(), defaults: defaults, codexHome: try AgentTestSupport.folder())
        agents.setStateForTests(lookups: [.codex: both.lookup], surveys: [.codex: both])
        #expect(agents.installation(.codex)?.executable == other)
        defaults.set(homebrew, forKey: AgentPreferences.programKey(.codex))
        agents.reloadSettings()
        #expect(agents.installation(.codex)?.executable == homebrew)
        #expect(agents.surveys[.codex] == both)
    }

    // MARK: Settings

    @Test func settingsSaysWhenAChosenGitWaitsForTheNextLaunch() {
        let running = GitInstallation(executable: "/usr/bin/git", version: GitVersion(major: 2, minor: 54, patch: 0), searchPath: Self.searchPath)
        let chosen = GitInstallation(executable: "/opt/homebrew/bin/git", version: GitVersion(major: 2, minor: 52, patch: 0), searchPath: Self.searchPath)
        #expect(GitProgramSection.restartNotice(running: running, chosen: running) == nil)
        // Before any repository is opened, there's nothing to wait for.
        #expect(GitProgramSection.restartNotice(running: nil, chosen: chosen) == nil)
        #expect(GitProgramSection.restartNotice(running: running, chosen: nil) == nil)
        #expect(GitProgramSection.restartNotice(running: running, chosen: chosen) == "Restart Roga to use the selected Git installation. Currently using /usr/bin/git (2.54.0).")
    }

    @Test func anAgentsProgramButtonSaysWhereItsCopyIsFrom() {
        let found = AgentLookup.found(AgentInstallation(kind: .codex, executable: "/opt/homebrew/bin/codex", version: AgentVersion(major: 0, minor: 166)))
        #expect(AgentDetailPage.selectTitle(lookup: found, program: nil, home: "/Users/ada") == "Homebrew")
        #expect(AgentDetailPage.selectTitle(lookup: .configuredMissing("/Users/ada/bin/codex"), program: "/Users/ada/bin/codex", home: "/Users/ada") == "~/bin")
        #expect(AgentDetailPage.selectTitle(lookup: .notFound, program: nil, home: "/Users/ada") == "None")
    }
}
