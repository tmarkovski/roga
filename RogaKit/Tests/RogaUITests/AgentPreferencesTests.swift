import AgentEngine
import Foundation
import Testing
@testable import RogaUI

/// What's stored about agents: the defaults while nothing is, the difference
/// between an empty value and an absent one, custom agents, and how what
/// Settings kept before decision 89 is carried over.
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
        #expect(claude == AgentSettings(program: nil, model: "haiku", effort: "low"))
        let codex = AgentSettings.read(.codex, from: defaults)
        #expect(codex == AgentSettings(program: nil, model: "", effort: "low"))
        #expect(AgentPreferences.usesAgents(in: defaults))
        #expect(AgentPreferences.defaultAgent(in: defaults) == nil)
        #expect(AgentPreferences.customAgents(in: defaults).isEmpty)
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
        defaults.set(" /opt/codex/bin/codex ", forKey: AgentPreferences.programKey(.codex))
        defaults.set("gpt-6-astra", forKey: AgentPreferences.modelKey(.codex))
        defaults.set("high", forKey: AgentPreferences.effortKey(.codex))
        let settings = AgentSettings.read(.codex, from: defaults)
        #expect(settings == AgentSettings(program: "/opt/codex/bin/codex", model: "gpt-6-astra", effort: "high"))
        // Claude Code's are its own.
        #expect(AgentSettings.read(.claude, from: defaults).program == nil)
    }

    @Test func anEmptyProgramIsLikeNone() {
        defer { clean() }
        defaults.set("", forKey: AgentPreferences.programKey(.claude))
        #expect(AgentSettings.read(.claude, from: defaults).program == nil)
    }

    @Test func theDefaultAgentIsStoredByWhatItIs() throws {
        defer { clean() }
        let id = try #require(UUID(uuidString: "0F6C0E1C-2A43-4E21-9C8E-7C1A2D3B4E5F"))
        #expect(AgentID.known(.codex).stored == "codex")
        #expect(AgentID.custom(id).stored == "custom.0F6C0E1C-2A43-4E21-9C8E-7C1A2D3B4E5F")
        for agent in [AgentID.known(.claude), .known(.codex), .custom(id)] {
            #expect(AgentID(stored: agent.stored) == agent)
            #expect(AgentID(rawValue: agent.rawValue) == agent)
        }
        // Something Roga doesn't know is no agent.
        #expect(AgentID(stored: "gemini") == nil)
        #expect(AgentID(stored: "custom.nope") == nil)
        defaults.set("gemini", forKey: AgentPreferences.defaultAgentKey)
        #expect(AgentPreferences.defaultAgent(in: defaults) == nil)
    }

    @Test func customAgentsAreKeptInTheOrderTheyWereAdded() {
        defer { clean() }
        let ollama = CustomAgent(name: "Ollama", command: "ollama run qwen2.5-coder:7b")
        let llm = CustomAgent(name: "", command: "llm -m gpt-4o-mini")
        AgentPreferences.setCustomAgents([ollama, llm], in: defaults)
        #expect(AgentPreferences.customAgents(in: defaults) == [ollama, llm])
        // One without a name goes by its command's first word.
        #expect(llm.shownName == "llm")
        #expect(llm.agent == CommitMessageAgent(name: "llm", command: "llm -m gpt-4o-mini"))
        AgentPreferences.setCustomAgents([], in: defaults)
        #expect(defaults.object(forKey: AgentPreferences.customAgentsKey) == nil)
        // What can't be read is none, rather than a crash.
        defaults.set(Data("not json".utf8), forKey: AgentPreferences.customAgentsKey)
        #expect(AgentPreferences.customAgents(in: defaults).isEmpty)
    }

    /// Each agent's old switch becomes Use agents, Generate's agent becomes the
    /// default, and both go, with what Settings no longer offers, so that
    /// nothing reads them again.
    @Test func theOldSwitchesBecomeUseAgentsAndTheDefault() {
        defer { clean() }
        func migrated(claude: Bool?, codex: Bool?, generate: String?, stored: String? = nil) -> (usesAgents: Bool?, defaultAgent: String?) {
            for kind in AgentKind.allCases { defaults.removeObject(forKey: AgentPreferences.legacyEnabledKey(kind)) }
            defaults.removeObject(forKey: AgentPreferences.legacyGenerateAgentKey)
            defaults.removeObject(forKey: AgentPreferences.defaultAgentKey)
            defaults.removeObject(forKey: AgentPreferences.usesAgentsKey)
            if let claude { defaults.set(claude, forKey: AgentPreferences.legacyEnabledKey(.claude)) }
            if let codex { defaults.set(codex, forKey: AgentPreferences.legacyEnabledKey(.codex)) }
            if let generate { defaults.set(generate, forKey: AgentPreferences.legacyGenerateAgentKey) }
            if let stored { defaults.set(stored, forKey: AgentPreferences.defaultAgentKey) }
            AgentPreferences.migrate(defaults)
            for kind in AgentKind.allCases { #expect(defaults.object(forKey: AgentPreferences.legacyEnabledKey(kind)) == nil) }
            #expect(defaults.object(forKey: AgentPreferences.legacyGenerateAgentKey) == nil)
            return (defaults.object(forKey: AgentPreferences.usesAgentsKey) as? Bool, defaults.string(forKey: AgentPreferences.defaultAgentKey))
        }
        #expect(migrated(claude: nil, codex: nil, generate: nil) == (nil, nil))
        #expect(migrated(claude: false, codex: false, generate: nil) == (false, nil))
        #expect(migrated(claude: false, codex: false, generate: "claude") == (false, nil))
        #expect(migrated(claude: false, codex: nil, generate: nil) == (nil, "codex"))
        #expect(migrated(claude: true, codex: false, generate: "codex") == (nil, "claude"))
        #expect(migrated(claude: true, codex: true, generate: "codex") == (nil, "codex"))
        #expect(migrated(claude: nil, codex: nil, generate: "codex") == (nil, "codex"))
        #expect(migrated(claude: true, codex: true, generate: nil) == (nil, nil))
        // A default chosen since wins.
        #expect(migrated(claude: true, codex: false, generate: nil, stored: "codex") == (nil, "codex"))
    }

    @Test func whatSettingsNoLongerOffersGoes() {
        defer { clean() }
        defaults.set(false, forKey: AgentPreferences.legacyShowsMarksKey)
        defaults.set("--verbose", forKey: AgentPreferences.legacyExtraArgumentsKey(.claude))
        defaults.set(120, forKey: AgentPreferences.legacyTimeLimitKey(.codex))
        AgentPreferences.migrate(defaults)
        #expect(defaults.object(forKey: AgentPreferences.legacyShowsMarksKey) == nil)
        #expect(defaults.object(forKey: AgentPreferences.legacyExtraArgumentsKey(.claude)) == nil)
        #expect(defaults.object(forKey: AgentPreferences.legacyTimeLimitKey(.codex)) == nil)
        // Turning the marks off didn't turn agents off.
        #expect(AgentPreferences.usesAgents(in: defaults))
    }

    @Test func emptyInstructionsStayEmpty() {
        defer { clean() }
        defaults.set("", forKey: AgentPreferences.instructionsKey)
        #expect(AgentPreferences.instructions(in: defaults) == "")
    }

    @Test func theKeysNameTheAgent() {
        #expect(AgentPreferences.usesAgentsKey == "useAgents")
        #expect(AgentPreferences.defaultAgentKey == "defaultAgent")
        #expect(AgentPreferences.customAgentsKey == "customAgents")
        #expect(AgentPreferences.programKey(.codex) == "agent.codex.program")
        #expect(AgentPreferences.modelKey(.claude) == "agent.claude.model")
        #expect(AgentPreferences.effortKey(.codex) == "agent.codex.effort")
        #expect(AgentPreferences.legacyEnabledKey(.claude) == "agent.claude.enabled")
        #expect(AgentPreferences.legacyGenerateAgentKey == "generateAgent")
        #expect(AgentPreferences.legacyShowsMarksKey == "agentsShowInSidebar")
        #expect(AgentPreferences.legacyExtraArgumentsKey(.claude) == "agent.claude.extraArguments")
        #expect(AgentPreferences.legacyTimeLimitKey(.codex) == "agent.codex.timeLimit")
    }

    @Test func pickersCallTheAgentsOwnDefaultDefault() {
        #expect(AgentKind.modelTitle("") == "Default")
        #expect(AgentKind.modelTitle("haiku") == "haiku")
        #expect(AgentKind.effortChoices.map(AgentKind.effortTitle) == ["Default", "Low", "Medium", "High"])
        #expect(AgentKind.claude.modelChoices == ["", "haiku", "sonnet", "opus"])
        #expect(AgentKind.codex.modelChoices == [""])
    }
}
