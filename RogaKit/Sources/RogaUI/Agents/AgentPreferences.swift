import AgentEngine
import Foundation

/// Where Roga keeps what people chose about agents, in UserDefaults
/// (decision 41).
///
/// Every value has a default that holds while its key is absent, so views can
/// bind with `@AppStorage(AgentPreferences.modelKey(kind)) var model = kind.recommendedModel`
/// and show the default without anyone having chosen it. A model or an effort
/// that's an empty string is different from an absent one: it stands for the
/// agent's own default, which the pickers call Default, while an absent one
/// means Roga's recommendation.
enum AgentPreferences {
    /// Whether the sidebar marks worktrees that agents work in. A Bool, on
    /// unless someone turned it off.
    static let showsMarksKey = "agentsShowInSidebar"
    /// Whether the commit box shows the Generate button. A Bool, on unless
    /// someone turned it off.
    static let showsGenerateButtonKey = "generateShowsButton"
    /// The agent Generate runs, as an `AgentKind` raw value. While it's absent,
    /// or names an agent that can't be used, Generate runs the first usable one.
    static let generateAgentKey = "generateAgent"
    /// Whether Generate sends the repository's recent subjects, so that the
    /// message matches its style. A Bool, on unless someone turned it off.
    static let matchesStyleKey = "generateMatchesStyle"
    /// The instructions for the message's style. While it's absent, they're
    /// Roga's own, `CommitMessagePrompt.defaultStyle`.
    static let instructionsKey = "generateInstructions"

    /// Whether Roga uses an agent at all. A Bool, on unless someone turned it off.
    static func enabledKey(_ kind: AgentKind) -> String { "agent.\(kind.rawValue).enabled" }
    /// The program someone chose for an agent, as a path. While it's absent,
    /// Roga finds the agent itself.
    static func programKey(_ kind: AgentKind) -> String { "agent.\(kind.rawValue).program" }
    /// The model Generate asks for. An empty string is the agent's own
    /// default, and an absent one is `AgentKind.recommendedModel`.
    static func modelKey(_ kind: AgentKind) -> String { "agent.\(kind.rawValue).model" }
    /// How hard the model thinks. An empty string is the agent's own default,
    /// and an absent one is `recommendedEffort`.
    static func effortKey(_ kind: AgentKind) -> String { "agent.\(kind.rawValue).effort" }
    /// Arguments someone added, as one string that's split the way a shell
    /// would split it. Empty while absent.
    static func extraArgumentsKey(_ kind: AgentKind) -> String { "agent.\(kind.rawValue).extraArguments" }
    /// How long Generate waits for the agent, in seconds, as an Int. 60 while
    /// absent.
    static func timeLimitKey(_ kind: AgentKind) -> String { "agent.\(kind.rawValue).timeLimit" }

    /// The effort Roga recommends. A commit message doesn't need much
    /// thought, and low effort answers in a few seconds.
    static let recommendedEffort = "low"
    /// The time limit while nobody has chosen one, in seconds.
    static let defaultTimeLimit = 60
    /// What the Time limit popup offers, in seconds.
    static let timeLimits = [30, 60, 120]

    /// Whether the sidebar shows agents' marks.
    static func showsMarks(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsMarksKey) as? Bool ?? true
    }

    /// Whether the commit box shows the Generate button.
    static func showsGenerateButton(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsGenerateButtonKey) as? Bool ?? true
    }

    /// Whether Generate sends recent subjects.
    static func matchesStyle(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: matchesStyleKey) as? Bool ?? true
    }

    /// The instructions Generate sends.
    static func instructions(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: instructionsKey) ?? CommitMessagePrompt.defaultStyle
    }
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

/// What's chosen for one agent, as UserDefaults has it, with each default
/// filled in.
struct AgentSettings: Equatable {
    /// Whether Roga uses the agent.
    var isEnabled: Bool
    /// The program someone chose, or nil for the one Roga finds.
    var program: String?
    /// The model, where "" is the agent's own default.
    var model: String
    /// The effort, where "" is the agent's own default.
    var effort: String
    /// The arguments someone added, already split.
    var extraArguments: [String]
    var timeLimit: Duration

    static func read(_ kind: AgentKind, from defaults: UserDefaults) -> AgentSettings {
        let program = defaults.string(forKey: AgentPreferences.programKey(kind))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = defaults.object(forKey: AgentPreferences.timeLimitKey(kind)) as? Int ?? AgentPreferences.defaultTimeLimit
        return AgentSettings(
            isEnabled: defaults.object(forKey: AgentPreferences.enabledKey(kind)) as? Bool ?? true,
            program: program?.isEmpty == false ? program : nil,
            model: defaults.string(forKey: AgentPreferences.modelKey(kind)) ?? kind.recommendedModel,
            effort: defaults.string(forKey: AgentPreferences.effortKey(kind)) ?? AgentPreferences.recommendedEffort,
            extraArguments: splitArguments(defaults.string(forKey: AgentPreferences.extraArgumentsKey(kind)) ?? ""),
            // A limit of nothing would stop every run at once.
            timeLimit: .seconds(seconds > 0 ? seconds : AgentPreferences.defaultTimeLimit)
        )
    }

    /// Splits what someone typed into arguments the way a shell would, without
    /// running anything: at spaces, tabs and new lines, with '…' taken as it
    /// is, and "…" and a backslash escaping what follows. Quotes join what's
    /// next to them, so `--x="a b"` is one argument, and `''` is an empty one.
    /// A backslash at the end of a line joins it to the next, outside single
    /// quotes, as a shell continues a line. A quote that isn't closed runs to
    /// the end.
    static func splitArguments(_ text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        // Whether there's an argument under way, which quotes start even when
        // they're empty.
        var isInArgument = false
        var characters = text.makeIterator()
        enum Quote { case none, single, double }
        var quote = Quote.none
        while let character = characters.next() {
            switch quote {
            case .single:
                if character == "'" { quote = .none } else { current.append(character) }
            case .double:
                if character == "\"" {
                    quote = .none
                } else if character == "\\", let next = characters.next() {
                    // In double quotes a backslash only escapes what a shell
                    // would treat specially there. Before a new line, both go.
                    if !"\"\\$`\n".contains(next) { current.append(character) }
                    if next != "\n" { current.append(next) }
                } else {
                    current.append(character)
                }
            case .none:
                if character.isWhitespace {
                    if isInArgument {
                        arguments.append(current)
                        current = ""
                        isInArgument = false
                    }
                } else if character == "'" {
                    quote = .single
                    isInArgument = true
                } else if character == "\"" {
                    quote = .double
                    isInArgument = true
                } else if character == "\\" {
                    // A new line after it joins the lines, so the two are
                    // nothing, and don't start an argument between others.
                    let next = characters.next()
                    if next != "\n" { isInArgument = true }
                    if let next, next != "\n" { current.append(next) }
                } else {
                    current.append(character)
                    isInArgument = true
                }
            }
        }
        if isInArgument { arguments.append(current) }
        return arguments
    }
}
