import AgentEngine
import Foundation
import Testing
@testable import RogaUI

/// What's stored about agents: the defaults while nothing is, the difference
/// between an empty value and an absent one, and how extra arguments split.
@Suite(.timeLimit(.minutes(1)), .removesTemporaryFolders)
struct AgentPreferencesTests {
    let defaults: UserDefaults
    let name: String

    init() {
        (defaults, name) = AgentTestSupport.defaults()
    }

    private func clean() {
        AgentTestSupport.remove(defaults, named: name)
    }

    @Test func nothingStoredReadsAsRogasRecommendations() {
        defer { clean() }
        let claude = AgentSettings.read(.claude, from: defaults)
        #expect(claude == AgentSettings(isEnabled: true, program: nil, model: "haiku", effort: "low", extraArguments: [], timeLimit: .seconds(60)))
        let codex = AgentSettings.read(.codex, from: defaults)
        #expect(codex == AgentSettings(isEnabled: true, program: nil, model: "", effort: "low", extraArguments: [], timeLimit: .seconds(60)))
        #expect(AgentPreferences.showsMarks(in: defaults))
        #expect(AgentPreferences.showsGenerateButton(in: defaults))
        #expect(AgentPreferences.matchesStyle(in: defaults))
        #expect(AgentPreferences.instructions(in: defaults) == CommitMessagePrompt.defaultStyle)
    }

    @Test func anEmptyModelIsTheAgentsOwnDefaultRatherThanRogas() {
        defer { clean() }
        defaults.set("", forKey: AgentPreferences.modelKey(.claude))
        defaults.set("", forKey: AgentPreferences.effortKey(.claude))
        let settings = AgentSettings.read(.claude, from: defaults)
        #expect(settings.model == "")
        #expect(settings.effort == "")
        defaults.removeObject(forKey: AgentPreferences.modelKey(.claude))
        #expect(AgentSettings.read(.claude, from: defaults).model == "haiku")
    }

    @Test func readsWhatsStored() {
        defer { clean() }
        defaults.set(false, forKey: AgentPreferences.enabledKey(.codex))
        defaults.set(" /opt/codex/bin/codex ", forKey: AgentPreferences.programKey(.codex))
        defaults.set("gpt-6-astra", forKey: AgentPreferences.modelKey(.codex))
        defaults.set("high", forKey: AgentPreferences.effortKey(.codex))
        defaults.set("-c 'profile=work' --oss", forKey: AgentPreferences.extraArgumentsKey(.codex))
        defaults.set(120, forKey: AgentPreferences.timeLimitKey(.codex))
        let settings = AgentSettings.read(.codex, from: defaults)
        #expect(settings == AgentSettings(isEnabled: false, program: "/opt/codex/bin/codex", model: "gpt-6-astra", effort: "high", extraArguments: ["-c", "profile=work", "--oss"], timeLimit: .seconds(120)))
        // Claude Code's are its own.
        #expect(AgentSettings.read(.claude, from: defaults).isEnabled)
    }

    @Test func anEmptyProgramOrATimeLimitOfNothingIsLikeNone() {
        defer { clean() }
        defaults.set("", forKey: AgentPreferences.programKey(.claude))
        defaults.set(0, forKey: AgentPreferences.timeLimitKey(.claude))
        let settings = AgentSettings.read(.claude, from: defaults)
        #expect(settings.program == nil)
        #expect(settings.timeLimit == .seconds(60))
    }

    @Test func emptyInstructionsStayEmpty() {
        defer { clean() }
        defaults.set("", forKey: AgentPreferences.instructionsKey)
        #expect(AgentPreferences.instructions(in: defaults) == "")
    }

    @Test func theKeysNameTheAgent() {
        #expect(AgentPreferences.enabledKey(.claude) == "agent.claude.enabled")
        #expect(AgentPreferences.programKey(.codex) == "agent.codex.program")
        #expect(AgentPreferences.modelKey(.claude) == "agent.claude.model")
        #expect(AgentPreferences.effortKey(.codex) == "agent.codex.effort")
        #expect(AgentPreferences.extraArgumentsKey(.claude) == "agent.claude.extraArguments")
        #expect(AgentPreferences.timeLimitKey(.codex) == "agent.codex.timeLimit")
    }

    @Test func pickersCallTheAgentsOwnDefaultDefault() {
        #expect(AgentKind.modelTitle("") == "Default")
        #expect(AgentKind.modelTitle("haiku") == "haiku")
        #expect(AgentKind.effortChoices.map(AgentKind.effortTitle) == ["Default", "Low", "Medium", "High"])
        #expect(AgentKind.claude.modelChoices == ["", "haiku", "sonnet", "opus"])
        #expect(AgentKind.codex.modelChoices == [""])
    }

    // MARK: Splitting arguments

    @Test func splitsAtSpacesTabsAndNewLines() {
        #expect(AgentSettings.splitArguments("--verbose  --max-turns 2\t-x\n-y") == ["--verbose", "--max-turns", "2", "-x", "-y"])
        #expect(AgentSettings.splitArguments("") == [])
        #expect(AgentSettings.splitArguments("   ") == [])
    }

    @Test func quotesKeepSpaces() {
        #expect(AgentSettings.splitArguments("--append 'two words' \"and three more\"") == ["--append", "two words", "and three more"])
    }

    @Test func quotesJoinWhatsNextToThem() {
        #expect(AgentSettings.splitArguments("--settings='{\"a\": 1}'") == ["--settings={\"a\": 1}"])
        #expect(AgentSettings.splitArguments("-c model_reasoning_summary=\"none\"x") == ["-c", "model_reasoning_summary=nonex"])
    }

    @Test func emptyQuotesAreAnEmptyArgument() {
        #expect(AgentSettings.splitArguments("--tools '' -p") == ["--tools", "", "-p"])
        #expect(AgentSettings.splitArguments("\"\"") == [""])
    }

    @Test func aBackslashEscapesWhatFollows() {
        #expect(AgentSettings.splitArguments("a\\ b c") == ["a b", "c"])
        #expect(AgentSettings.splitArguments("\"say \\\"hi\\\" \\n\"") == ["say \"hi\" \\n"])
        // Single quotes take everything as it is.
        #expect(AgentSettings.splitArguments("'a\\b'") == ["a\\b"])
    }

    @Test func aBackslashBeforeANewLineJoinsTheLines() {
        // A shell drops both, in double quotes and out, as `sh` does here.
        #expect(AgentSettings.splitArguments("\"a\\\nb\"") == ["ab"])
        #expect(AgentSettings.splitArguments("c\\\nd") == ["cd"])
        // Between arguments it's nothing, rather than an empty one.
        #expect(AgentSettings.splitArguments("--x \\\n --y") == ["--x", "--y"])
        // Single quotes keep both.
        #expect(AgentSettings.splitArguments("'p\\\nq'") == ["p\\\nq"])
    }

    @Test func aQuoteThatIsntClosedRunsToTheEnd() {
        #expect(AgentSettings.splitArguments("--x 'one two") == ["--x", "one two"])
    }
}
