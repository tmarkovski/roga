import AgentEngine
import CoreGraphics
import Foundation
import GitRunner
import Testing
@testable import RogaUI

/// What Roga found on a made-up Mac, which the tests of setup's rows, menus
/// and words read: three gits with an old one first in `PATH`, three copies
/// of Claude Code and two of Codex.
private enum Found {
    static let home = "/Users/ada"
    static let searchPath = [
        "/usr/local/bin", "/usr/bin", "/bin", home + "/.local/bin",
        home + "/.nvm/versions/node/v25.5.0/bin", home + "/.nvm/versions/node/v20.12.2/bin", "/opt/homebrew/bin",
    ].joined(separator: ":")
    static let xcode = "/Applications/Xcode.app/Contents/Developer"

    static let oldGit = FoundGit(executable: "/usr/local/bin/git", version: GitVersion(major: 2, minor: 33, patch: 0))
    static let applesGit = FoundGit(executable: "/usr/bin/git", version: GitVersion(major: 2, minor: 54, patch: 0))
    static let toolsGit = FoundGit(executable: "/Library/Developer/CommandLineTools/usr/bin/git", version: GitVersion(major: 2, minor: 50, patch: 1))
    static let gits = GitSurvey(
        searchPath: searchPath,
        copies: [oldGit, applesGit, toolsGit],
        developerToolsFolder: xcode,
        firstInPath: "/usr/local/bin/git"
    )
    static let git = GitInstallation(executable: "/usr/bin/git", version: GitVersion(major: 2, minor: 54, patch: 0), searchPath: searchPath)

    static let claude = home + "/.local/bin/claude"
    static let claudeNode25 = home + "/.nvm/versions/node/v25.5.0/bin/claude"
    static let claudeNode20 = home + "/.nvm/versions/node/v20.12.2/bin/claude"
    static func tooOld(_ kind: AgentKind, _ executable: String, _ version: AgentVersion) -> AgentSurvey.Copy {
        AgentSurvey.Copy(executable: executable, version: version, skipped: SkippedAgent(kind: kind, executable: executable, reason: .tooOld(version)))
    }
    static let claudes = AgentSurvey(kind: .claude, copies: [
        AgentSurvey.Copy(executable: claude, version: AgentVersion(major: 2, minor: 1, patch: 318)),
        tooOld(.claude, claudeNode25, AgentVersion(major: 2, minor: 1, patch: 29)),
        tooOld(.claude, claudeNode20, AgentVersion(major: 2, minor: 0, patch: 15)),
    ], searchPath: searchPath, firstInPath: claude)

    static let homebrewCodex = "/opt/homebrew/bin/codex"
    static let chatGPTCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    static let codexes = AgentSurvey(kind: .codex, copies: [
        AgentSurvey.Copy(executable: homebrewCodex, version: AgentVersion(major: 0, minor: 166)),
        AgentSurvey.Copy(executable: chatGPTCodex, version: AgentVersion(major: 0, minor: 167, patch: 0, prerelease: "alpha.3.2")),
    ], searchPath: searchPath, firstInPath: homebrewCodex)
}

/// Where a copy of a program is from, in a word or two.
@Suite struct ProgramSourceTests {
    func source(_ executable: String, tools: String? = nil) -> ProgramSource {
        ProgramSource.of(executable, developerToolsFolder: tools, home: Found.home)
    }

    @Test func applesGitIsNamedAfterTheToolsItRuns() {
        #expect(source("/usr/bin/git", tools: Found.xcode) == ProgramSource(name: "Xcode", phrase: "from Xcode"))
        #expect(source("/usr/bin/git", tools: "/Applications/Xcode-beta.app/Contents/Developer").name == "Xcode-beta")
        #expect(source("/usr/bin/git", tools: "/Library/Developer/CommandLineTools") == ProgramSource(name: "Command Line Tools", phrase: "from the Command Line Tools"))
        #expect(source("/usr/bin/git").name == "Apple")
    }

    @Test func knownPlacesHaveNames() {
        #expect(source("/Library/Developer/CommandLineTools/usr/bin/git").name == "Command Line Tools")
        #expect(source("/opt/homebrew/bin/git") == ProgramSource(name: "Homebrew", phrase: "from Homebrew"))
        #expect(source(Found.chatGPTCodex) == ProgramSource(name: "ChatGPT app", phrase: "from the ChatGPT app"))
        #expect(source(Found.claudeNode25) == ProgramSource(name: "nvm, Node 25", phrase: "from nvm's Node 25"))
        #expect(source("/Applications/Xcode.app/Contents/Developer/usr/bin/git").name == "Xcode")
    }

    @Test func anywhereElseIsItsFolderWithTheHomeFolderShort() {
        #expect(source(Found.claude) == ProgramSource(name: "~/.local/bin", phrase: "in ~/.local/bin"))
        #expect(source("/usr/local/bin/git") == ProgramSource(name: "/usr/local/bin", phrase: "in /usr/local/bin"))
        #expect(ProgramSource.abbreviated("/Users/ada", home: Found.home) == "~")
        #expect(ProgramSource.abbreviated("/Users/adam/bin", home: Found.home) == "/Users/adam/bin")
    }

    @Test func aProgramIsInPathWhenItsFolderIs() {
        #expect(ProgramSource.isInPath("/usr/bin/git", searchPath: "/usr/local/bin:/usr/bin/:/bin"))
        #expect(!ProgramSource.isInPath("/opt/homebrew/bin/git", searchPath: "/usr/local/bin:/usr/bin"))
    }
}

/// The copies in a program's menu, and what each says.
@Suite struct ProgramChoicesTests {
    @Test func gitsSayWhichIsRecommendedAndWhyRogaCantUseTheOld() {
        let choices = ProgramChoices.git(Found.gits, chosenPath: nil, current: Found.git, failure: nil, home: Found.home)
        #expect(choices.map(\.source) == ["/usr/local/bin", "Xcode", "Command Line Tools"])
        #expect(choices.map(\.version) == ["2.33.0", "2.54.0", "2.50.1"])
        #expect(choices.map(\.tag) == [.tooOld, .recommended, nil])
        #expect(choices.map(\.canChoose) == [false, true, true])
        #expect(choices[0].why == "Your terminal runs this one, but Roga needs 2.44 or later.")
        #expect(choices[1].why == "The first Git in your PATH that's new enough.")
        #expect(choices[2].why == "Not in your PATH.")
        #expect(choices[1].spoken == "Xcode 2.54.0, Recommended, /usr/bin/git, The first Git in your PATH that's new enough.")
    }

    @Test func theFirstGitInPathIsTheOneATerminalRuns() {
        var survey = Found.gits
        survey.copies = [Found.applesGit, Found.oldGit]
        survey.firstInPath = "/usr/bin/git"
        let choices = ProgramChoices.git(survey, chosenPath: nil, current: Found.git, failure: nil, home: Found.home)
        #expect(choices[0].why == "Your terminal runs this one too.")
        #expect(choices[1].why == "Roga needs 2.44 or later.")
    }

    @Test func aGitFromSomewhereElseGoesFirstAndSaysWhetherRogaCanUseIt() {
        let chosen = "/opt/tools/bin/git"
        let current = GitInstallation(executable: chosen, version: GitVersion(major: 2, minor: 47, patch: 0), searchPath: Found.searchPath)
        let used = ProgramChoices.git(Found.gits, chosenPath: chosen, current: current, failure: nil, home: Found.home)
        #expect(used.count == 4)
        #expect(used[0] == ProgramChoice(executable: chosen, source: "/opt/tools/bin", version: "2.47.0", tag: .chosen, path: chosen, why: "From somewhere Roga doesn't look by itself."))

        let missing = ProgramChoices.git(Found.gits, chosenPath: chosen, current: nil, failure: .configuredGitMissing(chosen), home: Found.home)
        #expect(missing[0].tag == .unusable)
        #expect(missing[0].why == "Roga can't find or run it.")
        #expect(!missing[0].canChoose)

        let old = ProgramChoices.git(
            Found.gits, chosenPath: chosen, current: nil,
            failure: .configuredGitUnsupported(.init(executable: chosen, version: GitVersion(major: 2, minor: 30, patch: 0))),
            home: Found.home
        )
        #expect(old[0].tag == .tooOld)
        #expect(old[0].version == "2.30.0")
    }

    @Test func aGitRogaFoundIsListedOnceWhenItsTheChosenOne() {
        let choices = ProgramChoices.git(Found.gits, chosenPath: Found.toolsGit.executable, current: nil, failure: nil, home: Found.home)
        #expect(choices.count == 3)
    }

    @Test func claudesSayWhichATerminalRunsAndWhichAreTooOld() {
        let choices = ProgramChoices.agent(Found.claudes, program: nil, lookup: Found.claudes.lookup, home: Found.home)
        #expect(choices.map(\.source) == ["~/.local/bin", "nvm, Node 25", "nvm, Node 20"])
        #expect(choices.map(\.tag) == [.recommended, .tooOld, .tooOld])
        #expect(choices[0].why == "Your terminal runs this one too.")
        #expect(choices[1].why == "Roga needs 2.1.169 or later.")
        #expect(choices[1].version == "2.1.29")
        #expect(choices[0].path == "~/.local/bin/claude")
    }

    @Test func codexRecommendsTheNewestAndSaysWhichATerminalRuns() {
        let choices = ProgramChoices.agent(Found.codexes, program: nil, lookup: Found.codexes.lookup, home: Found.home)
        #expect(choices.map(\.source) == ["Homebrew", "ChatGPT app"])
        #expect(choices.map(\.tag) == [nil, .recommended])
        #expect(choices[0].why == "Your terminal runs this one.")
        #expect(choices[1].why == "The newest copy, which new models need.")
    }

    @Test func aCopyThatDidntAnswerSaysHow() {
        func why(_ reason: SkippedAgent.Reason, terminal: Bool = false) -> String {
            ProgramChoices.reason(SkippedAgent(kind: .codex, executable: "/x/codex", reason: reason), terminalRunsIt: terminal).1
        }
        #expect(why(.noVersion(status: nil, errorOutput: "")) == "It couldn't be started.")
        #expect(why(.noVersion(status: .exited(0), errorOutput: "")) == "It didn't print a version Roga could read.")
        #expect(why(.noVersion(status: .exited(3), errorOutput: "")) == "It stopped before saying its version.")
        #expect(why(.timedOut) == "It didn't say its version within 5 seconds.")
        #expect(why(.timedOut, terminal: true) == "Your terminal runs this one, but it didn't say its version within 5 seconds.")
        #expect(why(.tooOld(AgentVersion(major: 0, minor: 100))) == "Roga needs 0.131.0 or later.")
    }

    @Test func anAgentFromSomewhereElseGoesFirst() {
        let chosen = "/opt/tools/codex"
        let found = AgentLookup.found(AgentInstallation(kind: .codex, executable: chosen, version: AgentVersion(major: 0, minor: 150)))
        let choices = ProgramChoices.agent(Found.codexes, program: chosen, lookup: found, home: Found.home)
        #expect(choices.count == 3)
        #expect(choices[0].tag == .chosen)
        #expect(choices[0].version == "0.150.0")

        let missing = ProgramChoices.agent(Found.codexes, program: chosen, lookup: .configuredMissing(chosen), home: Found.home)
        #expect(missing[0].tag == .unusable)
        #expect(!missing[0].canChoose)
    }
}

/// What a program's row says in each state.
@Suite struct ProgramRowContentTests {
    @Test func gitsRowSaysWhichGitAndWhereItsFrom() {
        let row = ProgramRowContent.git(state: .ready(Git(installation: Found.git)), survey: Found.gits, home: Found.home)
        #expect(row == ProgramRowContent(name: "Git", version: "2.54.0", status: .detected, line: "/usr/bin/git", select: .menu("Xcode")))
        #expect(row.spoken == "Git 2.54.0 detected. /usr/bin/git")
        // Until Roga has the list, there's no menu to open.
        #expect(ProgramRowContent.git(state: .ready(Git(installation: Found.git)), survey: nil, home: Found.home).select == .none)
        #expect(ProgramRowContent.git(state: .locating, survey: nil, home: Found.home).line == "Looking…")
    }

    @Test func gitsRowSaysWhyRogaCantUseAChosenGit() {
        let missing = ProgramRowContent.git(state: .failed(.configuredGitMissing(Found.home + "/bin/git")), survey: Found.gits, home: Found.home)
        #expect(missing.status == .warning("Not found"))
        #expect(missing.line == "Roga can't find or run ~/bin/git, which you chose.")
        #expect(missing.tone == .warn)
        #expect(missing.select == .menu("~/bin"))

        let old = ProgramRowContent.git(
            state: .failed(.configuredGitUnsupported(.init(executable: "/usr/local/bin/git", version: GitVersion(major: 2, minor: 33, patch: 0)))),
            survey: Found.gits,
            home: Found.home
        )
        #expect(old.version == "2.33.0")
        #expect(old.status == .warning("Too old"))

        let none = ProgramRowContent.git(state: .failed(.notFound(developerToolsMissing: true)), survey: Found.gits, home: Found.home)
        #expect(none.select == .choose)
        #expect(none.isDimmed)
    }

    @Test func anAgentsRowFollowsWhatRogaFoundAndWhetherItsUsed() {
        let found = ProgramRowContent.agent(.codex, lookup: Found.codexes.lookup, isOn: true, home: Found.home)
        #expect(found.version == "0.167.0-alpha.3.2")
        #expect(found.status == .detected)
        #expect(found.line == Found.chatGPTCodex)
        #expect(found.select == .menu("ChatGPT app"))

        // One that's off keeps its menu, to turn it back on.
        let off = ProgramRowContent.agent(.codex, lookup: Found.codexes.lookup, isOn: false, home: Found.home)
        #expect(off == ProgramRowContent(name: "Codex", line: ProgramRowContent.unused, tone: .plain, select: .menu("Not used"), isDimmed: true))

        let missing = ProgramRowContent.agent(.claude, lookup: .notFound, isOn: true, home: Found.home)
        #expect(missing.select == .choose)
        #expect(missing.isDimmed)
        // An agent Roga didn't find has nothing to turn off.
        #expect(ProgramRowContent.agent(.claude, lookup: .notFound, isOn: false, home: Found.home) == missing)

        #expect(ProgramRowContent.agent(.claude, lookup: nil, isOn: true, home: Found.home).select == .none)

        let old = SkippedAgent(kind: .claude, executable: Found.claudeNode25, reason: .tooOld(AgentVersion(major: 2, minor: 1, patch: 29)))
        let unusable = ProgramRowContent.agent(.claude, lookup: .unusable([old]), isOn: true, home: Found.home)
        #expect(unusable.status == .warning("Too old"))
        #expect(unusable.version == "2.1.29")
        #expect(unusable.select == .menu("nvm, Node 25"))
    }
}

/// Where setup is, what's answered, and what the answers store.
@Suite(.removesTemporaryFolders)
@MainActor
struct SetupModelTests {
    let defaults: UserDefaults
    let name: String

    init() {
        (defaults, name) = AgentTestSupport.defaults()
    }

    private func enabled(_ kind: AgentKind) -> Bool? {
        defaults.object(forKey: AgentPreferences.enabledKey(kind)) as? Bool
    }

    @Test func showsOnlyForSomeoneWithNoRepositories() {
        defer { AgentTestSupport.remove(defaults, named: name) }
        #expect(SetupModel(hasRepositories: false, defaults: defaults).isShowing)
        #expect(defaults.object(forKey: SetupModel.doneKey) == nil)

        // Someone with repositories was using Roga before setup existed, and
        // never sees it, even after removing them all.
        #expect(!SetupModel(hasRepositories: true, defaults: defaults).isShowing)
        #expect(!SetupModel(hasRepositories: false, defaults: defaults).isShowing)

        // Writing false shows it again, repositories or not.
        defaults.set(false, forKey: SetupModel.doneKey)
        #expect(SetupModel(hasRepositories: true, defaults: defaults).isShowing)
        // A launch argument arrives as a word.
        defaults.set("NO", forKey: SetupModel.doneKey)
        #expect(SetupModel(hasRepositories: true, defaults: defaults).isShowing)
        defaults.set("YES", forKey: SetupModel.doneKey)
        #expect(!SetupModel(hasRepositories: false, defaults: defaults).isShowing)
    }

    @Test func finishingStoresThatSetupIsOver() {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let setup = SetupModel(hasRepositories: false, defaults: defaults)
        setup.finish()
        #expect(!setup.isShowing)
        #expect(!SetupModel(hasRepositories: false, defaults: defaults).isShowing)
    }

    @Test func goesThroughEveryScreenAndBack() {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let setup = SetupModel(hasRepositories: false, defaults: defaults)
        let found: [AgentKind] = [.claude, .codex]
        #expect(setup.step == .welcome)
        #expect(setup.steps(found: found) == [.looking, .git, .agents, .hooks, .ready])
        setup.start()
        #expect(setup.step == .looking)
        #expect(!setup.goesBack)
        setup.next(found: found)
        setup.next(found: found)
        #expect(setup.step == .agents)
        setup.useAgents(found: found)
        #expect(setup.step == .hooks)
        setup.next(found: found)
        #expect(setup.step == .ready)
        // Ready is the last screen.
        setup.next(found: found)
        #expect(setup.step == .ready)
        setup.back(found: found)
        #expect(setup.step == .hooks)
        #expect(setup.goesBack)
        // Change beside what Git set goes back too, and Continue goes on.
        setup.go(to: .git)
        #expect(setup.step == .git)
        #expect(setup.goesBack)
        setup.next(found: found)
        #expect(!setup.goesBack)
        setup.back(found: found)
        setup.back(found: found)
        #expect(setup.step == .looking)
        // Back from the first of them is Welcome, which has nothing before it.
        setup.back(found: found)
        #expect(setup.step == .welcome)
        setup.back(found: found)
        #expect(setup.step == .welcome)
    }

    @Test func hooksDropOutWhenNoAgentIsInUse() {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let setup = SetupModel(hasRepositories: false, defaults: defaults)
        #expect(setup.steps(found: []) == [.looking, .git, .agents, .ready])
        setup.setStateForTests(step: .agents)
        setup.dontUseAgents()
        #expect(setup.step == .ready)
        #expect(setup.steps(found: [.claude, .codex]) == [.looking, .git, .agents, .ready])
        #expect(setup.usable(found: [.claude, .codex]).isEmpty)
        // Back from Ready goes to Agents, since there's no Hooks.
        setup.back(found: [.claude, .codex])
        #expect(setup.step == .agents)
    }

    @Test func useAgentsStoresEachRowsSwitchAndLeavesOneNotFoundOn() {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let setup = SetupModel(hasRepositories: false, defaults: defaults)
        setup.setOn(.codex, false)
        // Nothing is stored until the screen is answered.
        #expect(enabled(.codex) == nil)
        #expect(setup.usable(found: [.claude, .codex]) == [.claude])
        setup.useAgents(found: [.claude, .codex])
        #expect(setup.usesAgents == true)
        #expect(enabled(.claude) == true)
        #expect(enabled(.codex) == false)
        #expect(setup.step == .hooks)

        // An agent Roga didn't find is used once it's installed.
        let other = SetupModel(hasRepositories: false, defaults: defaults)
        other.setOn(.codex, false)
        other.useAgents(found: [.claude])
        #expect(enabled(.codex) == true)
    }

    @Test func dontUseAgentsTurnsEveryAgentOffAndComingBackKeepsTheRows() {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let setup = SetupModel(hasRepositories: false, defaults: defaults)
        setup.setOn(.codex, false)
        setup.dontUseAgents()
        #expect(setup.usesAgents == false)
        #expect(enabled(.claude) == false)
        #expect(enabled(.codex) == false)
        // The rows are as they were left, so Use Agents asks about the same.
        #expect(setup.isOn == [.claude: true, .codex: false])
        setup.go(to: .agents)
        setup.useAgents(found: [.claude, .codex])
        #expect(enabled(.claude) == true)
        #expect(enabled(.codex) == false)
        #expect(setup.usable(found: [.claude, .codex]) == [.claude])
    }

    @Test func continuingWithNoAgentFoundLeavesTheSwitchesAlone() {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let setup = SetupModel(hasRepositories: false, defaults: defaults)
        setup.setStateForTests(step: .agents)
        setup.continueWithoutAgents()
        #expect(setup.usesAgents == nil)
        #expect(enabled(.claude) == nil)
        #expect(enabled(.codex) == nil)
        #expect(setup.step == .ready)
    }

    @Test func choosingACopyStoresItAndTurnsTheAgentOn() {
        defer { AgentTestSupport.remove(defaults, named: name) }
        let setup = SetupModel(hasRepositories: false, defaults: defaults)
        setup.setOn(.codex, false)
        setup.chooseProgram(.codex, "/opt/homebrew/bin/codex")
        #expect(defaults.string(forKey: AgentPreferences.programKey(.codex)) == "/opt/homebrew/bin/codex")
        #expect(setup.isOn[.codex] == true)
        // The one Roga finds is stored as nothing, so that Roga keeps
        // following its own rule.
        setup.chooseProgram(.codex, nil)
        #expect(defaults.object(forKey: AgentPreferences.programKey(.codex)) == nil)
    }

    @Test func startsFromWhatsStoredForEachAgent() {
        defer { AgentTestSupport.remove(defaults, named: name) }
        defaults.set(false, forKey: AgentPreferences.enabledKey(.codex))
        #expect(SetupModel(hasRepositories: false, defaults: defaults).isOn == [.claude: true, .codex: false])
    }
}

/// What setup's screens say.
@Suite @MainActor struct SetupWordsTests {
    @Test func joinsNamesTheWayASentenceDoes() {
        #expect(SetupWords.and([]) == "")
        #expect(SetupWords.and(["A"]) == "A")
        #expect(SetupWords.and(["A", "B"]) == "A and B")
        #expect(SetupWords.and(["A", "B", "C"]) == "A, B and C")
    }

    @Test func lookingSaysWhatRogaFoundAsItFindsIt() {
        #expect(SetupWords.pathLook(nil, shell: "/bin/zsh") == .init(name: "Your PATH", state: .looking, detail: "Asking zsh…"))
        #expect(SetupWords.pathLook(("/usr/bin", true), shell: "/opt/homebrew/bin/fish").detail == "Read from your login shell, fish")
        #expect(SetupWords.pathLook(("/usr/bin", false), shell: "/bin/zsh").detail == "zsh didn't say, so Roga uses the one it started with")

        let ready = GitProvider.State.ready(Git(installation: Found.git))
        #expect(SetupWords.gitLook(state: .locating, survey: nil, isLooking: true, hasPath: false).state == .waiting)
        #expect(SetupWords.gitLook(state: ready, survey: nil, isLooking: true, hasPath: true).state == .looking)
        #expect(SetupWords.gitLook(state: ready, survey: Found.gits, isLooking: false, hasPath: true) == .init(name: "Git", state: .found, detail: "3 found · 2.54.0 from Xcode"))
        let failed = SetupWords.gitLook(state: .failed(.notFound(developerToolsMissing: true)), survey: GitSurvey(searchPath: "", copies: []), isLooking: false, hasPath: true)
        #expect(failed == .init(name: "Git", state: .missing, detail: "None found"))

        #expect(SetupWords.agentLook(.claude, lookup: nil, survey: nil, hasGit: false, gitFailed: true) == .init(name: "Claude Code", state: .waiting, detail: "After Git"))
        #expect(SetupWords.agentLook(.claude, lookup: nil, survey: nil, hasGit: true, gitFailed: false).state == .looking)
        #expect(SetupWords.agentLook(.claude, lookup: Found.claudes.lookup, survey: Found.claudes, hasGit: true, gitFailed: false).detail == "3 found · 2.1.318")
        // An agent that isn't installed isn't a problem.
        #expect(SetupWords.agentLook(.codex, lookup: .notFound, survey: AgentSurvey(kind: .codex, copies: []), hasGit: true, gitFailed: false) == .init(name: "Codex", state: .found, detail: "Not found"))
    }

    @Test func gitsHeadingAndNoteSayWhichGitAndWhatATerminalRuns() {
        // The heading leaves where the Git is from to its row, so that it's
        // as long whichever Git it is.
        #expect(SetupWords.gitHeading(Found.git) == "Roga will use Git 2.54.0")
        let tools = GitInstallation(executable: Found.toolsGit.executable, version: GitVersion(major: 2, minor: 50, patch: 1), searchPath: Found.searchPath)
        #expect(SetupWords.gitHeading(tools) == "Roga will use Git 2.50.1")
        #expect(SetupWords.gitNote(Found.gits, home: Found.home) == [
            "Roga found 3 Gits, and recommends the first one in your PATH that's new enough.",
            "Your terminal runs the one in /usr/local/bin, which is 2.33 and too old.",
        ])
        let one = GitSurvey(searchPath: "/usr/bin", copies: [Found.applesGit], developerToolsFolder: Found.xcode, firstInPath: "/usr/bin/git")
        #expect(SetupWords.gitNote(one, home: Found.home) == ["It's the only Git Roga found."])
        // One Roga finds outside PATH isn't the first in it.
        let outside = GitSurvey(searchPath: "/usr/local/bin", copies: [Found.oldGit, FoundGit(executable: "/opt/homebrew/bin/git", version: GitVersion(major: 2, minor: 52, patch: 0))], firstInPath: "/usr/local/bin/git")
        #expect(SetupWords.gitNote(outside, home: Found.home).first == "Roga found 2 Gits, and recommends the first one it can use, which isn't in your PATH.")
        #expect(SetupWords.gitNote(GitSurvey(searchPath: "", copies: [Found.oldGit]), home: Found.home).isEmpty)
    }

    @Test func withNoGitTheScreenOffersTheToolsOnlyWhenTheyreMissing() {
        let missing = SetupWords.noGit(found: 1, developerToolsMissing: true)
        #expect(missing.heading == "Roga needs Git 2.44 or newer")
        #expect(missing.sub.contains("the only one it found is older than that"))
        #expect(missing.offersTools)
        #expect(missing.say != nil)
        #expect(SetupWords.noGit(found: 0, developerToolsMissing: true).sub.contains("it didn't find one"))
        let installed = SetupWords.noGit(found: 2, developerToolsMissing: false)
        #expect(!installed.offersTools)
        #expect(installed.say == nil)
    }

    @Test func theAgentsQuestionNamesTheAgentsRogaWouldUse() {
        #expect(SetupWords.agentsHeading(found: [.claude, .codex], on: [.claude, .codex]) == "Use Claude Code and Codex in Roga?")
        #expect(SetupWords.agentsHeading(found: [.claude, .codex], on: [.claude]) == "Use Claude Code in Roga?")
        // With every row off, it asks about all of them again.
        #expect(SetupWords.agentsHeading(found: [.claude, .codex], on: []) == "Use Claude Code and Codex in Roga?")
        #expect(SetupWords.agentsHeading(found: [], on: []) == SetupWords.noAgentsHeading)
    }

    @Test func theHintCountsCopiesOnlyWhenThereAreSeveral() {
        #expect(SetupWords.copiesHint([(.claude, 3), (.codex, 2)]) == "Roga found 3 copies of Claude Code and 2 of Codex. Each menu lists them all.")
        #expect(SetupWords.copiesHint([(.claude, 1), (.codex, 2)]) == "Roga found 1 copy of Claude Code and 2 of Codex. Each menu lists them all.")
        #expect(SetupWords.copiesHint([(.codex, 2)]) == "Roga found 2 copies of Codex. The menu lists them all.")
        #expect(SetupWords.copiesHint([(.claude, 1), (.codex, 1)]) == nil)
        #expect(SetupWords.copiesHint([]) == nil)
    }

    @Test func aHooksRowSaysWhatTheAgentSaidAndWhatToDo() {
        #expect(SetupWords.hookRow(.claude, status: nil, work: nil) == .init(status: "Checking…", mark: .spinner))
        #expect(SetupWords.hookRow(.claude, status: .notInstalled, work: nil) == .init(status: "Not installed"))
        #expect(SetupWords.hookRow(.codex, status: .notInstalled, work: nil).aside == "asks you to trust the hooks before it runs them")
        #expect(SetupWords.hookRow(.claude, status: .installed, work: nil) == .init(status: "Installed", mark: .ok, notes: ["It works in the sessions you start from now on."]))

        let trust = SetupWords.hookRow(.codex, status: .needsTrust, work: nil)
        #expect(trust.status == "Waiting for your OK")
        #expect(trust.mark == .warn)
        #expect(trust.checksAgain)

        #expect(SetupWords.hookRow(.claude, status: .disabled, work: nil).status == "Turned off in Claude Code")
        // Claude Code takes another copy's hooks over, and Codex can't.
        #expect(!SetupWords.hookRow(.claude, status: .anotherCopy(folder: "/x/plugins"), work: nil).checksAgain)
        #expect(SetupWords.hookRow(.codex, status: .anotherCopy(folder: "/x/plugins"), work: nil).checksAgain)
        #expect(SetupWords.hookRow(.codex, status: .unknown("codex exited with status 2"), work: nil).notes == ["codex exited with status 2."])

        // While Install runs, that's all the row says.
        #expect(SetupWords.hookRow(.claude, status: .notInstalled, work: .installing) == .init(status: "Installing…", mark: .spinner))
        let failed = SetupWords.hookRow(.claude, status: .notInstalled, work: .failed(.install, "Marketplace 'roga' not found"))
        #expect(failed.status == "Not installed")
        #expect(failed.problems == ["Marketplace 'roga' not found"])
        #expect(failed.spoken == "Not installed. Marketplace 'roga' not found")
    }

    @Test func theHooksScreenOffersInstallOnlyWhereItCanWork() {
        typealias Phase = SetupWords.HooksPhase
        func phase(_ status: [AgentKind: HookStatus], work: [AgentKind: AgentProvider.HookWork] = [:], canInstall: Bool = true) -> Phase {
            SetupWords.hooksPhase(usable: [.claude, .codex], status: status, work: work, canInstall: canInstall)
        }
        #expect(phase([:]) == .checking)
        #expect(phase([.claude: .notInstalled]) == .checking)
        #expect(phase([.claude: .notInstalled, .codex: .notInstalled]) == .pending([.claude, .codex]))
        #expect(phase([.claude: .installed, .codex: .notInstalled]) == .pending([.codex]))
        #expect(phase([.claude: .notInstalled, .codex: .notInstalled], work: [.claude: .installing]) == .installing)
        #expect(phase([.claude: .installed, .codex: .needsTrust]) == .done)
        // Claude Code can take over another copy's hooks, and Codex can't.
        #expect(phase([.claude: .anotherCopy(folder: "/x"), .codex: .anotherCopy(folder: "/x")]) == .pending([.claude]))
        // A copy of Roga with no helper has nothing to install.
        #expect(phase([.claude: .notInstalled, .codex: .notInstalled], canInstall: false) == .done)
        // An agent that isn't in use isn't waited for.
        #expect(SetupWords.hooksPhase(usable: [.claude], status: [.claude: .installed], work: [:], canInstall: true) == .done)
    }

    @Test func readySaysWhatWasChosen() {
        let git = SetupWords.chosenGit(Found.git, developerToolsFolder: Found.xcode, home: Found.home)
        #expect(git == .init(mark: .ok, value: "Git 2.54.0 from Xcode", detail: "/usr/bin/git", detailIsPath: true))
        #expect(SetupWords.chosenGit(nil, developerToolsFolder: nil).mark == .warn)

        let found: [(kind: AgentKind, version: String)] = [(.claude, "2.1.318"), (.codex, "0.166.0")]
        #expect(SetupWords.chosenAgents(found: found, usable: [.claude, .codex], declined: false) == .init(mark: .ok, value: "Claude Code 2.1.318 and Codex 0.166.0"))
        #expect(SetupWords.chosenAgents(found: found, usable: [.claude], declined: false) == .init(mark: .ok, value: "Claude Code 2.1.318", detail: "Codex isn't used."))
        #expect(SetupWords.chosenAgents(found: found, usable: [], declined: true) == .init(mark: .off, value: "Not used", detail: "Roga hides its agent commands and the Generate button."))
        #expect(SetupWords.chosenAgents(found: [], usable: [], declined: false).value == "None found")
    }

    @Test func readySaysWhereTheHooksAreAndWhereTheyWait() {
        func hooks(_ status: [AgentKind: HookStatus]) -> SetupWords.Chosen {
            SetupWords.chosenHooks(usable: [.claude, .codex], status: status)
        }
        #expect(hooks([.claude: .installed, .codex: .installed]) == .init(mark: .ok, value: "Installed in Claude Code and Codex"))
        #expect(hooks([.claude: .installed, .codex: .needsTrust]) == .init(mark: .warn, value: "Installed in Claude Code and Codex", detail: "Codex is waiting for you to trust them."))
        #expect(hooks([.claude: .installed, .codex: .notInstalled]) == .init(mark: .ok, value: "Installed in Claude Code", detail: "Not installed in Codex."))
        #expect(hooks([.claude: .notInstalled, .codex: .notInstalled]) == .init(mark: .off, value: "Not installed", detail: "The sidebar won't show what your agents are doing."))
        #expect(SetupWords.chosenHooks(usable: [.codex], status: [.codex: .needsTrust]).detail == "It's waiting for you to trust them.")
    }
}

/// Where a row's menu opens.
@Suite struct ProgramMenuPlacementTests {
    let menu = CGSize(width: 404, height: 300)
    let container = CGSize(width: 1120, height: 800)

    @Test func opensUnderItsButtonWithTheirRightEdgesInLine() {
        let button = CGRect(x: 760, y: 200, width: 96, height: 30)
        #expect(ProgramMenuPlacement.origin(button: button, menu: menu, in: container) == CGPoint(x: 452, y: 236))
    }

    @Test func opensOverItsButtonWhenTheresNoRoomUnderIt() {
        let button = CGRect(x: 760, y: 600, width: 96, height: 30)
        #expect(ProgramMenuPlacement.origin(button: button, menu: menu, in: container) == CGPoint(x: 452, y: 294))
        // With no room over it either, under it is where it's expected.
        let small = CGSize(width: 1120, height: 320)
        #expect(ProgramMenuPlacement.origin(button: CGRect(x: 760, y: 150, width: 96, height: 30), menu: menu, in: small).y == 186)
    }

    @Test func staysInsideWhatItsDrawnOver() {
        let narrow = CGSize(width: 420, height: 800)
        #expect(ProgramMenuPlacement.origin(button: CGRect(x: 300, y: 100, width: 90, height: 30), menu: menu, in: narrow).x == 8)
    }
}
