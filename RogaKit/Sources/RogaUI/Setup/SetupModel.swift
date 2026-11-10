import AgentEngine
import Foundation
import Observation

/// What Roga asks the first time it runs: which git to use, whether to use
/// agents and which copies, whether to install their hooks, and updates.
/// Setup takes the whole window, and the window becomes the app when it's
/// done. Everything it sets is a setting that Settings shows later.
///
/// There's one for the whole app, so every window shows the same step. It
/// keeps where setup is and what was answered. What Roga found comes from
/// `GitProvider` and `AgentProvider`, and what's chosen goes to UserDefaults,
/// where they and Settings read it.
@MainActor @Observable
public final class SetupModel {
    /// The screens, in order. Hooks drops out when no agent is in use.
    enum Step: Int, CaseIterable, Comparable {
        case welcome
        case looking
        case git
        case agents
        case hooks
        case ready

        static func < (first: Step, second: Step) -> Bool {
            first.rawValue < second.rawValue
        }
    }

    /// Whether setup is over, as a Bool. While it's absent, setup shows only
    /// for someone with no repositories in the sidebar, since anyone who has
    /// some was using Roga before setup existed. Writing false, or starting
    /// Roga with `-setupDone NO`, shows it again.
    static let doneKey = "setupDone"

    /// Whether the windows show setup rather than the sidebar and a worktree.
    public private(set) var isShowing: Bool
    private(set) var step = Step.welcome
    /// Whether the last move went to an earlier screen, which says which
    /// side the new screen comes in from.
    private(set) var goesBack = false
    /// Whether to use agents, as answered on the Agents screen, or nil while
    /// nobody has answered, and when Roga found none to ask about.
    private(set) var usesAgents: Bool?
    /// Which agents the Agents screen leaves on. Don't Use Codex in its menu
    /// turns one off, and picking a copy turns it back on. It's kept apart
    /// from each agent's own switch, which Don't Use Agents turns off for all
    /// of them, so that coming back to the screen shows the rows as they
    /// were left.
    private(set) var isOn: [AgentKind: Bool]

    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameter hasRepositories: Whether the sidebar lists any, which
    ///   means Roga was in use before setup existed.
    public init(hasRepositories: Bool, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isOn = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map {
            ($0, defaults.object(forKey: AgentPreferences.enabledKey($0)) as? Bool ?? true)
        })
        // Read the way `@AppStorage` reads a Bool, so that a launch argument
        // counts too, which arrives as the word NO.
        if defaults.object(forKey: Self.doneKey) != nil {
            isShowing = !defaults.bool(forKey: Self.doneKey)
        } else {
            isShowing = !hasRepositories
            if hasRepositories { defaults.set(true, forKey: Self.doneKey) }
        }
    }

    // MARK: Steps

    /// The screens after Welcome, which the dots at the top stand for and
    /// the house runs along.
    ///
    /// - Parameter found: The agents Roga found.
    func steps(found: [AgentKind]) -> [Step] {
        [.looking, .git, .agents] + (usable(found: found).isEmpty ? [] : [.hooks]) + [.ready]
    }

    /// The found agents that the answers so far leave in use.
    func usable(found: [AgentKind]) -> [AgentKind] {
        guard usesAgents != false else { return [] }
        return found.filter { isOn[$0] != false }
    }

    /// From Welcome to the first screen.
    func start() {
        move(to: .looking)
    }

    /// The next screen, from one whose main button only goes on.
    func next(found: [AgentKind]) {
        let steps = steps(found: found)
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        move(to: steps[index + 1])
    }

    /// The screen before this one, which for the first of them is Welcome.
    func back(found: [AgentKind]) {
        let steps = steps(found: found)
        guard let index = steps.firstIndex(of: step) else { return }
        move(to: index > 0 ? steps[index - 1] : .welcome)
    }

    /// Goes back to a step, from Change beside what it set.
    func go(to step: Step) {
        move(to: step)
    }

    private func move(to next: Step) {
        goesBack = next < step
        step = next
    }

    // MARK: Agents

    /// Turns one agent off or back on, from its row's menu. Nothing is
    /// stored until the screen is answered.
    func setOn(_ kind: AgentKind, _ isOn: Bool) {
        self.isOn[kind] = isOn
    }

    /// Makes a copy the one Roga runs for an agent, or goes back to the one
    /// Roga finds when it's nil, and turns the agent on. The provider reads
    /// it from UserDefaults and looks again.
    func chooseProgram(_ kind: AgentKind, _ path: String?) {
        if let path {
            defaults.set(path, forKey: AgentPreferences.programKey(kind))
        } else {
            defaults.removeObject(forKey: AgentPreferences.programKey(kind))
        }
        isOn[kind] = true
    }

    /// Use Agents: each found agent's switch goes the way its row has it,
    /// and one Roga didn't find goes back to on, so that Roga uses it once
    /// it's installed.
    func useAgents(found: [AgentKind]) {
        usesAgents = true
        for kind in AgentKind.allCases {
            defaults.set(found.contains(kind) ? isOn[kind] != false : true, forKey: AgentPreferences.enabledKey(kind))
        }
        move(to: usable(found: found).isEmpty ? .ready : .hooks)
    }

    /// Don't Use Agents: every agent's switch goes off, found or not, so that
    /// one installed later isn't used until someone turns it on in Settings.
    func dontUseAgents() {
        usesAgents = false
        for kind in AgentKind.allCases {
            defaults.set(false, forKey: AgentPreferences.enabledKey(kind))
        }
        move(to: .ready)
    }

    /// Continue, when Roga found no agent. Nobody was asked, so the switches
    /// stay as they are, and an agent installed later is used.
    func continueWithoutAgents() {
        usesAgents = nil
        move(to: .ready)
    }

    // MARK: Finishing

    /// Open Roga: setup is over, and the windows show the app.
    func finish() {
        defaults.set(true, forKey: Self.doneKey)
        isShowing = false
    }

    // MARK: Tests

    /// Puts setup at a step with answers given, for tests of what its screens
    /// show.
    func setStateForTests(step: Step? = nil, usesAgents: Bool?? = nil, isOn: [AgentKind: Bool]? = nil) {
        if let step { self.step = step }
        if let usesAgents { self.usesAgents = usesAgents }
        if let isOn { self.isOn = isOn }
    }
}
