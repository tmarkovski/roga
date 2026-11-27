import AgentEngine
import Foundation

/// Where Roga keeps what people chose about agents, in UserDefaults
/// (decisions 41 and 89).
///
/// Every value has a default that holds while its key is absent, so views can
/// bind with `@AppStorage(AgentPreferences.modelKey(kind)) var model = kind.recommendedModel`
/// and show the default without anyone having chosen it. A model or an effort
/// that's an empty string is different from an absent one: it stands for the
/// agent's own default, which the pickers call Default, while an absent one
/// means Roga's recommendation.
enum AgentPreferences {
    /// Whether Roga uses agents at all: Generate, Resolve and Fix, the marks
    /// in the sidebar, and looking for agents. A Bool, on unless someone
    /// turned it off (decision 89).
    static let usesAgentsKey = "useAgents"
    /// The agent Generate, Resolve and Fix run, as `AgentID.stored`. While
    /// it's absent, or names an agent Roga can't run, they run the first
    /// agent Roga can.
    ///
    /// Only `AgentProvider` writes it, and it reads it only as it starts, so
    /// anything else that changes the default agent asks the provider
    /// (decision 123).
    static let defaultAgentKey = "defaultAgent"
    /// The agents someone added as commands, as JSON. Like the default agent,
    /// only `AgentProvider` writes them, and it reads them only as it starts.
    static let customAgentsKey = "customAgents"
    /// Whether Generate sends the repository's recent subjects, so that the
    /// message matches its style. A Bool, on unless someone turned it off.
    static let matchesStyleKey = "generateMatchesStyle"
    /// The instructions for the message's style. While it's absent, they're
    /// Roga's own, `CommitMessagePrompt.defaultStyle`.
    static let instructionsKey = "generateInstructions"

    /// The program someone chose for an agent, as a path. While it's absent,
    /// Roga finds the agent itself.
    static func programKey(_ kind: AgentKind) -> String { "agent.\(kind.rawValue).program" }
    /// The model Generate asks for. An empty string is the agent's own
    /// default, and an absent one is `AgentKind.recommendedModel`.
    static func modelKey(_ kind: AgentKind) -> String { "agent.\(kind.rawValue).model" }
    /// How hard the model thinks. An empty string is the agent's own default,
    /// and an absent one is `recommendedEffort`.
    static func effortKey(_ kind: AgentKind) -> String { "agent.\(kind.rawValue).effort" }

    /// The effort Roga recommends. A commit message doesn't need much
    /// thought, and low effort answers in a few seconds.
    static let recommendedEffort = "low"

    /// Whether Roga uses agents.
    static func usesAgents(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: usesAgentsKey) as? Bool ?? true
    }

    /// Whether Generate sends recent subjects.
    static func matchesStyle(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: matchesStyleKey) as? Bool ?? true
    }

    /// The instructions Generate sends.
    static func instructions(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: instructionsKey) ?? CommitMessagePrompt.defaultStyle
    }

    /// The default agent as stored, whether or not Roga can run it.
    static func defaultAgent(in defaults: UserDefaults = .standard) -> AgentID? {
        defaults.string(forKey: defaultAgentKey).flatMap(AgentID.init(stored:))
    }

    /// The custom agents, in the order they were added. What can't be read
    /// is none.
    static func customAgents(in defaults: UserDefaults = .standard) -> [CustomAgent] {
        guard let data = defaults.data(forKey: customAgentsKey) else { return [] }
        return (try? JSONDecoder().decode([CustomAgent].self, from: data)) ?? []
    }

    static func setCustomAgents(_ agents: [CustomAgent], in defaults: UserDefaults = .standard) {
        if agents.isEmpty {
            defaults.removeObject(forKey: customAgentsKey)
        } else if let data = try? JSONEncoder().encode(agents) {
            defaults.set(data, forKey: customAgentsKey)
        }
    }

    // MARK: Before decision 89

    /// Each agent's switch for whether Roga ran it, which Use agents
    /// replaced.
    static func legacyEnabledKey(_ kind: AgentKind) -> String { "agent.\(kind.rawValue).enabled" }
    /// The agent Generate ran, which the default agent replaced.
    static let legacyGenerateAgentKey = "generateAgent"
    /// Whether the sidebar showed agents' marks, which Use agents covers now.
    static let legacyShowsMarksKey = "agentsShowInSidebar"
    /// Arguments someone added after Roga's own, and how long Generate waited,
    /// which Settings no longer offers.
    static func legacyExtraArgumentsKey(_ kind: AgentKind) -> String { "agent.\(kind.rawValue).extraArguments" }
    static func legacyTimeLimitKey(_ kind: AgentKind) -> String { "agent.\(kind.rawValue).timeLimit" }
    /// Whether the commit box showed the Generate button, which follows Use
    /// agents now (decision 110).
    static let legacyShowsGenerateButtonKey = "generateShowsButton"

    /// Turns what Settings kept before decision 89 into Use agents and the
    /// default agent, and removes it, with the Generate button's switch that
    /// decision 110 took out. It changes nothing once it's gone, so it's safe
    /// to call at each launch.
    ///
    /// Both agents switched off means agents are off. Generate's agent stays
    /// the default while it was switched on, and with only one switched on,
    /// that one is. What's already stored the new way wins.
    static func migrate(_ defaults: UserDefaults = .standard) {
        let switches = AgentKind.allCases.compactMap { kind in
            (defaults.object(forKey: legacyEnabledKey(kind)) as? Bool).map { (kind: kind, isOn: $0) }
        }
        let generate = defaults.string(forKey: legacyGenerateAgentKey)
        let others = [legacyShowsMarksKey, legacyShowsGenerateButtonKey] + AgentKind.allCases.flatMap { [legacyExtraArgumentsKey($0), legacyTimeLimitKey($0)] }
        defer {
            for kind in AgentKind.allCases { defaults.removeObject(forKey: legacyEnabledKey(kind)) }
            defaults.removeObject(forKey: legacyGenerateAgentKey)
            for key in others { defaults.removeObject(forKey: key) }
        }
        guard !switches.isEmpty || generate != nil else { return }
        let on = AgentKind.allCases.filter { kind in switches.first { $0.kind == kind }?.isOn ?? true }
        if on.isEmpty {
            if defaults.object(forKey: usesAgentsKey) == nil { defaults.set(false, forKey: usesAgentsKey) }
            return
        }
        guard defaults.object(forKey: defaultAgentKey) == nil else { return }
        let picked = generate.flatMap(AgentKind.init(rawValue:))
        if let picked, on.contains(picked) {
            defaults.set(AgentID.known(picked).stored, forKey: defaultAgentKey)
        } else if on.count == 1, let only = on.first {
            defaults.set(AgentID.known(only).stored, forKey: defaultAgentKey)
        }
    }
}

/// An agent Roga can run: Claude Code or Codex, which Roga finds, or one
/// someone added as a command (decision 89).
enum AgentID: Hashable, Sendable {
    case known(AgentKind)
    case custom(UUID)

    /// How the default agent is stored: `claude`, `codex`, or `custom.` and
    /// the custom agent's ID.
    var stored: String {
        switch self {
        case .known(let kind): kind.rawValue
        case .custom(let id): "custom." + id.uuidString
        }
    }

    /// The agent that's stored, or nil for anything Roga doesn't know.
    init?(stored: String) {
        if let kind = AgentKind(rawValue: stored) {
            self = .known(kind)
        } else if stored.hasPrefix("custom."), let id = UUID(uuidString: String(stored.dropFirst("custom.".count))) {
            self = .custom(id)
        } else {
            return nil
        }
    }

    /// Claude Code or Codex, or nil for a custom agent.
    var kind: AgentKind? {
        if case .known(let kind) = self { kind } else { nil }
    }
}

/// Stored as `stored` says, so that Settings can keep the agent whose page
/// shows with `@AppStorage`.
extension AgentID: RawRepresentable {
    var rawValue: String { stored }

    init?(rawValue: String) {
        self.init(stored: rawValue)
    }
}

/// An agent someone added in Settings as a command, such as a local model
/// (decision 89). Roga runs the command in the shell with its instructions
/// and the data on standard input, and takes what it prints as its answer. It
/// has no hooks, no model or effort, and nothing for Roga to find.
struct CustomAgent: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var command: String

    init(id: UUID = UUID(), name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }

    /// The name without spaces around it, or the command's first word when
    /// there's no name.
    var shownName: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "Custom agent"
    }

    /// How Roga runs it.
    var agent: CommitMessageAgent {
        CommitMessageAgent(name: shownName, command: command.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// An agent as a run of Generate, Resolve or Fix names it: which one, so that
/// Try Again runs the same one, and what it's called.
struct NamedAgent: Hashable, Sendable {
    var id: AgentID
    /// As in Claude Code, or a custom agent's name.
    var name: String
    /// As in Resolve with Claude.
    var shortName: String

    init(id: AgentID, name: String, shortName: String) {
        self.id = id
        self.name = name
        self.shortName = shortName
    }

    init(_ kind: AgentKind) {
        self.init(id: .known(kind), name: kind.name, shortName: kind.shortName)
    }

    static let claude = NamedAgent(.claude)
    static let codex = NamedAgent(.codex)
}

extension AgentKind {
    /// The model Roga suggests for writing commit messages, where "" stands
    /// for the agent's own default. Claude Code's Haiku is fast and plenty for
    /// a message. Codex's models depend on the account, so Roga leaves the
    /// choice to Codex.
    var recommendedModel: String {
        switch self {
        case .claude: "haiku"
        case .codex: ""
        }
    }

    /// The models the pickers offer, with "" for the agent's own default
    /// first. Claude Code takes these aliases for its newest models. Codex's
    /// names change with the account, so it's Default or a name someone types.
    var modelChoices: [String] {
        switch self {
        case .claude: ["", "haiku", "sonnet", "opus"]
        case .codex: [""]
        }
    }

    /// The efforts the pickers offer, with "" for the agent's own default
    /// first. Both agents take the same three.
    static let effortChoices = ["", "low", "medium", "high"]

    /// What a picker calls a model: Default for the agent's own, and
    /// otherwise its name as the agent takes it.
    static func modelTitle(_ model: String) -> String {
        model.isEmpty ? "Default" : model
    }

    /// What a picker calls an effort: Default for the agent's own, and
    /// otherwise the word with a capital, such as Low.
    static func effortTitle(_ effort: String) -> String {
        effort.isEmpty ? "Default" : effort.prefix(1).uppercased() + effort.dropFirst()
    }
}

/// What's chosen for Claude Code or Codex, as UserDefaults has it, with each
/// default filled in.
struct AgentSettings: Equatable {
    /// The program someone chose, or nil for the one Roga finds.
    var program: String?
    /// The model, where "" is the agent's own default.
    var model: String
    /// The effort, where "" is the agent's own default.
    var effort: String

    static func read(_ kind: AgentKind, from defaults: UserDefaults) -> AgentSettings {
        let program = defaults.string(forKey: AgentPreferences.programKey(kind))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentSettings(
            program: program?.isEmpty == false ? program : nil,
            model: defaults.string(forKey: AgentPreferences.modelKey(kind)) ?? kind.recommendedModel,
            effort: defaults.string(forKey: AgentPreferences.effortKey(kind)) ?? AgentPreferences.recommendedEffort
        )
    }
}
