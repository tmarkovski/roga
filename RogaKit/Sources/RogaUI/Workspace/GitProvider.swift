import Foundation
import GitRunner
import Observation

/// Where Roga keeps what people chose about git, in UserDefaults.
enum GitPreferences {
    /// The git someone chose, as a path. While it's absent, Roga finds git
    /// itself, and uses the first one it can.
    static let programKey = "gitProgram"

    /// The git someone chose, or nil for the one Roga finds.
    static func program(in defaults: UserDefaults = .standard) -> String? {
        let path = defaults.string(forKey: programKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }
}

/// Finds the git that Roga runs, when Roga launches, and every other git on
/// this Mac, which setup and Settings list. Every window uses the same one.
///
/// Someone can choose another git in setup or in Settings. The provider goes
/// over to it at once, but what's already running keeps the git it started
/// with: the repositories in the sidebar are opened with one git and keep it
/// until Roga quits, so a git chosen in Settings takes over the next time
/// Roga opens.
@Observable
public final class GitProvider {
    public nonisolated enum State: Sendable {
        case locating
        case ready(Git)
        case failed(GitInstallationError)
    }

    /// How the provider finds things, which tests replace, so that none of
    /// them reads the login shell or runs a real git.
    nonisolated struct Finding: Sendable {
        var searchPath: @Sendable () async -> (searchPath: String, fromLoginShell: Bool) = {
            await GitInstallation.readSearchPath()
        }
        var locate: @Sendable (_ configuredPath: String?, _ searchPath: String) async -> Result<GitInstallation, GitInstallationError> = { configuredPath, searchPath in
            do throws(GitInstallationError) {
                return .success(try await GitInstallation.locate(configuredPath: configuredPath, searchPath: searchPath))
            } catch {
                return .failure(error)
            }
        }
        var survey: @Sendable (_ searchPath: String) async -> GitSurvey = { await GitInstallation.survey(searchPath: $0) }
    }

    public private(set) var state = State.locating
    /// Every git Roga found, once it has looked. It's kept while Roga looks
    /// again, so that a list of them doesn't empty and fill.
    private(set) var survey: GitSurvey?
    /// The git someone chose, or nil for the one Roga finds.
    private(set) var chosenPath: String?
    /// The `PATH` Roga searches, once it has read it, and whether the login
    /// shell said it. Setup shows it as the first thing Roga looks at.
    private(set) var searchPath: (path: String, fromLoginShell: Bool)?
    /// Whether Roga is looking: at launch, after Look Again, and for the
    /// moment it takes to ask a newly chosen git for its version.
    private(set) var isLooking = true

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let finding: Finding
    /// Which look is the latest, so an older one that finishes later doesn't
    /// replace what it found.
    @ObservationIgnored private var generation = 0

    public convenience init() {
        self.init(defaults: .standard, finding: Finding())
    }

    init(defaults: UserDefaults, finding: Finding) {
        self.defaults = defaults
        self.finding = finding
        chosenPath = GitPreferences.program(in: defaults)
        look()
    }

    public var git: Git? {
        if case .ready(let git) = state { git } else { nil }
    }

    /// Why Roga can't use any git, when it can't.
    var failure: GitInstallationError? {
        if case .failed(let error) = state { error } else { nil }
    }

    /// Looks for git again, as Look Again does after someone installs one. It
    /// reads the login shell's `PATH` again too, since an installer may have
    /// changed it. What Roga found before stays until this look is done.
    func lookAgain() {
        look()
    }

    /// Makes `path` the git Roga runs, from now on, or goes back to the one
    /// Roga finds when it's nil. A git Roga can't use is kept all the same,
    /// and `state` says why it can't, since a git someone chose is used or
    /// reported and never passed over for another (decision 3).
    func choose(_ path: String?) {
        let path = path.flatMap { $0.isEmpty ? nil : $0 }
        if let path {
            defaults.set(path, forKey: GitPreferences.programKey)
        } else {
            defaults.removeObject(forKey: GitPreferences.programKey)
        }
        chosenPath = path
        guard let survey else {
            look()
            return
        }
        // The `PATH` is the one already read, so this only asks one git for
        // its version, or none when it's the one Roga finds.
        generation += 1
        let generation = generation
        isLooking = true
        Task {
            let located = await self.locate(chosen: path, in: survey)
            guard self.generation == generation else { return }
            apply(located)
            isLooking = false
        }
    }

    private func look() {
        generation += 1
        let generation = generation
        let chosen = chosenPath
        isLooking = true
        Task {
            let (searchPath, fromLoginShell) = await finding.searchPath()
            guard self.generation == generation else { return }
            self.searchPath = (searchPath, fromLoginShell)
            // Git first, since every window waits for it, and then the rest.
            var located = await finding.locate(chosen, searchPath)
            guard self.generation == generation else { return }
            apply(located)
            var survey = await finding.survey(searchPath)
            survey.readFromLoginShell = fromLoginShell
            guard self.generation == generation else { return }
            self.survey = survey
            if case .failure = located, chosen == nil, survey.recommended != nil {
                // The survey looks in one more place than launch does, the
                // Command Line Tools' own folder.
                located = await locate(chosen: nil, in: survey)
                guard self.generation == generation else { return }
                apply(located)
            }
            isLooking = false
        }
    }

    /// The chosen git, or the one the survey recommends, with its version read.
    private func locate(chosen: String?, in survey: GitSurvey) async -> Result<GitInstallation, GitInstallationError> {
        if let chosen {
            return await finding.locate(chosen, survey.searchPath)
        }
        guard let recommended = survey.recommended, let version = recommended.version else {
            return await finding.locate(nil, survey.searchPath)
        }
        let skipped = survey.copies
            .prefix { $0.executable != recommended.executable }
            .map { GitInstallation.SkippedGit(executable: $0.executable, version: $0.version) }
        return .success(GitInstallation(executable: recommended.executable, version: version, searchPath: survey.searchPath, skipped: skipped))
    }

    private func apply(_ located: Result<GitInstallation, GitInstallationError>) {
        switch located {
        case .success(let installation):
            // The same git again keeps its command log and whatever else
            // holds on to it.
            if case .ready(let git) = state, git.installation == installation { return }
            state = .ready(Git(installation: installation))
        case .failure(let error):
            state = .failed(error)
        }
    }

    // MARK: Tests

    /// Puts the provider in a state, for tests of what views show in it,
    /// without finding or running anything.
    func setStateForTests(
        state: State? = nil,
        survey: GitSurvey?? = nil,
        chosenPath: String?? = nil,
        isLooking: Bool = false,
        hasSearchPath: Bool = true
    ) {
        generation += 1
        self.isLooking = isLooking
        if let state { self.state = state }
        if let survey { self.survey = survey }
        if let chosenPath { self.chosenPath = chosenPath }
        searchPath = hasSearchPath ? (self.survey?.searchPath ?? "/usr/bin:/bin", true) : nil
    }
}
