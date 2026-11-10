#if DEBUG
import AgentEngine
import AgentHooks
import Foundation
import GitRunner

/// A made-up Mac for Xcode's previews, like the one setup's tests use: three
/// gits with an old one first in `PATH`, three copies of Claude Code of which
/// two are too old, and two of Codex. Its folders are in the real home
/// folder, so that they show with a `~` the way the app shows them.
///
/// Nothing in a preview runs these programs, whether or not they're there.
nonisolated enum PreviewMac {
    static let home = NSHomeDirectory()
    static let searchPath = [
        "/usr/local/bin", "/usr/bin", "/bin", home + "/.local/bin",
        home + "/.nvm/versions/node/v25.5.0/bin", home + "/.nvm/versions/node/v20.12.2/bin", "/opt/homebrew/bin",
    ].joined(separator: ":")
    static let xcode = "/Applications/Xcode.app/Contents/Developer"

    /// How long looking takes, so that Look Again shows Looking… for a moment.
    static let lookTime = Duration.milliseconds(700)

    /// UserDefaults of the previews' own, emptied for each preview, so that
    /// what one chooses never reaches Roga's settings or the next preview.
    static func defaults() -> UserDefaults {
        let name = "sh.roga.previews"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Git

    /// An old git first in `PATH`, Xcode's, and the Command Line Tools'.
    static let gits: GitSurvey = {
        var survey = GitSurvey(
            searchPath: searchPath,
            copies: [
                FoundGit(executable: "/usr/local/bin/git", version: GitVersion(major: 2, minor: 33, patch: 0)),
                FoundGit(executable: "/usr/bin/git", version: GitVersion(major: 2, minor: 54, patch: 0)),
                FoundGit(executable: "/Library/Developer/CommandLineTools/usr/bin/git", version: GitVersion(major: 2, minor: 50, patch: 1)),
            ],
            developerToolsFolder: xcode,
            firstInPath: "/usr/local/bin/git"
        )
        survey.readFromLoginShell = true
        return survey
    }()

    /// No git at all, since nobody installed the developer tools.
    static let noGits: GitSurvey = {
        var survey = GitSurvey(searchPath: searchPath, copies: [], developerToolsMissing: true)
        survey.readFromLoginShell = true
        return survey
    }()

    /// The git Roga runs from these, as `GitProvider` picks it: the chosen
    /// one, or the one the survey recommends.
    static func locate(_ chosen: String?, in survey: GitSurvey) -> Result<GitInstallation, GitInstallationError> {
        if let chosen {
            // Only a git on the list answers. Its menu doesn't offer one
            // that's too old.
            guard let version = survey.copies.first(where: { $0.executable == chosen })?.version else {
                return .failure(.configuredGitMissing(chosen))
            }
            return .success(GitInstallation(executable: chosen, version: version, searchPath: survey.searchPath))
        }
        guard let recommended = survey.recommended, let version = recommended.version else {
            return .failure(.notFound(developerToolsMissing: survey.developerToolsMissing))
        }
        let skipped = survey.copies
            .prefix { $0.executable != recommended.executable }
            .map { GitInstallation.SkippedGit(executable: $0.executable, version: $0.version) }
        return .success(GitInstallation(executable: recommended.executable, version: version, searchPath: survey.searchPath, skipped: skipped))
    }

    // MARK: Agents

    static let claude = home + "/.local/bin/claude"
    static let homebrewCodex = "/opt/homebrew/bin/codex"

    static let surveys: [AgentKind: AgentSurvey] = [
        .claude: AgentSurvey(kind: .claude, copies: [
            AgentSurvey.Copy(executable: claude, version: AgentVersion(major: 2, minor: 1, patch: 318)),
            tooOld(.claude, home + "/.nvm/versions/node/v25.5.0/bin/claude", AgentVersion(major: 2, minor: 1, patch: 29)),
            tooOld(.claude, home + "/.nvm/versions/node/v20.12.2/bin/claude", AgentVersion(major: 2, minor: 0, patch: 15)),
        ], searchPath: searchPath, firstInPath: claude),
        .codex: AgentSurvey(kind: .codex, copies: [
            AgentSurvey.Copy(executable: homebrewCodex, version: AgentVersion(major: 0, minor: 166)),
            AgentSurvey.Copy(
                executable: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                version: AgentVersion(major: 0, minor: 167, patch: 0, prerelease: "alpha.3.2")
            ),
        ], searchPath: searchPath, firstInPath: homebrewCodex),
    ]

    /// Neither agent anywhere.
    static let noAgents: [AgentKind: AgentSurvey] = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map {
        ($0, AgentSurvey(kind: $0, copies: [], searchPath: searchPath))
    })

    private static func tooOld(_ kind: AgentKind, _ executable: String, _ version: AgentVersion) -> AgentSurvey.Copy {
        AgentSurvey.Copy(executable: executable, version: version, skipped: SkippedAgent(kind: kind, executable: executable, reason: .tooOld(version)))
    }

    /// The commands Install runs in each agent Roga found, written out the
    /// way the Hooks screen shows them: a copy a terminal runs by its name,
    /// and any other by its path.
    static func installCommands(_ surveys: [AgentKind: AgentSurvey]) -> [AgentKind: [ProgramCommand]] {
        let installer = HookInstaller(
            programs: Programs(searchPath: searchPath),
            supportFolder: HookSocket.supportFolder(bundleIdentifier: HookSocket.defaultBundleIdentifier)
        )
        return surveys.compactMapValues { survey in
            guard case .found(let installation) = survey.lookup else { return nil }
            let runsByName = installation.executable == survey.firstInPath
            return installer.installCommands(survey.kind, executable: runsByName ? survey.kind.executableName : installation.executable)
        }
    }
}
#endif
