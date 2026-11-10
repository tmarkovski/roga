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

    let defaults: UserDefaults
    let name: String
    let asked = Asked()

    init() {
        (defaults, name) = AgentTestSupport.defaults()
    }

    /// A provider whose `PATH` and gits are made up. Locating with no chosen
    /// path finds Apple's, and a chosen one is found when it's one of
    /// `usable`.
    func provider(survey: GitSurvey = GitProviderTests.survey, finds: Bool = true, usable: [FoundGit] = [apples, homebrew]) -> GitProvider {
        let asked = asked
        let (apples, old) = (Self.apples, Self.old)
        return GitProvider(defaults: defaults, finding: GitProvider.Finding(
            searchPath: { (survey.searchPath, true) },
            locate: { configured, searchPath in
                asked.add(configured)
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
        #expect(menu.skip == nil)

        menu.choose(menu.choices[2])
        #expect(provider.chosenPath == Self.homebrew.executable)
        #expect(try #require(ProgramMenu.git(provider)).checked == Self.homebrew.executable)
        menu.choose(menu.choices[1])
        #expect(provider.chosenPath == nil)
        await settled(provider)
    }

    @Test func anAgentsMenuChoosesACopyOrNotToUseTheAgent() throws {
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
        var skipped = 0
        let menu = try #require(ProgramMenu.agent(.codex, agents: agents, isOn: true, choose: { chosen.append($0) }, skip: { skipped += 1 }))
        #expect(menu.label == "Every Codex Roga found")
        #expect(menu.checked == app)
        #expect(menu.skip?.title == "Don't Use Codex")
        #expect(menu.skip?.isOn == false)
        menu.choose(menu.choices[0])
        // The recommended copy is stored as nothing, so Roga keeps choosing.
        menu.choose(menu.choices[1])
        #expect(chosen == [homebrew, nil])
        menu.skip?.action()
        #expect(skipped == 1)

        // An agent that's off has the check on not using it.
        let off = try #require(ProgramMenu.agent(.codex, agents: agents, isOn: false, choose: { _ in }, skip: {}))
        #expect(off.skip?.isOn == true)
        // Settings has a switch for that, so its menu doesn't offer it.
        #expect(try #require(ProgramMenu.agent(.codex, agents: agents, choose: { _ in })).skip == nil)
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
        #expect(GitProgramSection.restartNotice(running: running, chosen: chosen) == "Roga goes over to this Git the next time it opens. Until then it runs /usr/bin/git, which is 2.54.0.")
    }

    @Test func anAgentsProgramButtonSaysWhereItsCopyIsFrom() {
        let found = AgentLookup.found(AgentInstallation(kind: .codex, executable: "/opt/homebrew/bin/codex", version: AgentVersion(major: 0, minor: 166)))
        #expect(AgentDetailPage.selectTitle(lookup: found, program: nil, home: "/Users/ada") == "Homebrew")
        #expect(AgentDetailPage.selectTitle(lookup: .configuredMissing("/Users/ada/bin/codex"), program: "/Users/ada/bin/codex", home: "/Users/ada") == "~/bin")
        #expect(AgentDetailPage.selectTitle(lookup: .notFound, program: nil, home: "/Users/ada") == "None")
    }
}
