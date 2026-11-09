import AgentEngine
import Foundation
import GitRunner

/// Where a copy of a program is from, in a word or two, since several copies
/// of git or of an agent differ mostly in who put them there.
///
/// `name` goes on a row's button and in its menu, as in "Xcode", and `phrase`
/// goes in a sentence, as in "Git 2.54.0 from Xcode".
nonisolated struct ProgramSource: Equatable {
    var name: String
    var phrase: String

    /// - Parameters:
    ///   - developerToolsFolder: The folder Apple's git runs its git from, as
    ///     `xcode-select -p` prints it, which says whether `/usr/bin/git` is
    ///     Xcode's or the Command Line Tools'.
    ///   - home: The home folder, which shows as `~`.
    static func of(_ executable: String, developerToolsFolder: String? = nil, home: String = NSHomeDirectory()) -> ProgramSource {
        if executable == GitInstallation.developerToolsGit {
            guard let developerToolsFolder else { return ProgramSource(name: "Apple", phrase: "from Apple") }
            return tools(in: developerToolsFolder + "/")
        }
        if executable.hasPrefix(GitInstallation.commandLineToolsFolder + "/") {
            return ProgramSource(name: "Command Line Tools", phrase: "from the Command Line Tools")
        }
        if let app = appName(in: executable) {
            if app.hasPrefix("Xcode") { return ProgramSource(name: app, phrase: "from \(app)") }
            return ProgramSource(name: "\(app) app", phrase: "from the \(app) app")
        }
        if executable.hasPrefix("/opt/homebrew/") {
            return ProgramSource(name: "Homebrew", phrase: "from Homebrew")
        }
        if let node = nodeVersion(in: executable) {
            return ProgramSource(name: "nvm, Node \(node)", phrase: "from nvm's Node \(node)")
        }
        let folder = abbreviated((executable as NSString).deletingLastPathComponent, home: home)
        return ProgramSource(name: folder, phrase: "in \(folder)")
    }

    /// Which developer tools a folder belongs to.
    private static func tools(in path: String) -> ProgramSource {
        if path.hasPrefix(GitInstallation.commandLineToolsFolder + "/") {
            return ProgramSource(name: "Command Line Tools", phrase: "from the Command Line Tools")
        }
        let app = appName(in: path) ?? "Xcode"
        return ProgramSource(name: app, phrase: "from \(app)")
    }

    /// The app a path is inside, without `.app`, as in ChatGPT.
    private static func appName(in path: String) -> String? {
        path.split(separator: "/").first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }

    /// The major version of the Node that nvm keeps a path under.
    private static func nodeVersion(in path: String) -> String? {
        guard let marker = path.range(of: "/.nvm/versions/node/v") else { return nil }
        let major = path[marker.upperBound...].prefix(while: \.isNumber)
        return major.isEmpty ? nil : String(major)
    }

    /// A path with the home folder as `~`.
    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Whether a program's folder is one of the folders of a `PATH`.
    static func isInPath(_ executable: String, searchPath: String) -> Bool {
        let folder = ExecutableSearch.standardized((executable as NSString).deletingLastPathComponent)
        return searchPath.split(separator: ":").contains { ExecutableSearch.standardized(String($0)) == folder }
    }
}

extension ExecutableSearch {
    /// A folder's path without a trailing slash, so that two spellings of one
    /// folder in a `PATH` compare equal without asking the file system.
    nonisolated static func standardized(_ folder: String) -> String {
        folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
    }
}

/// A copy of a program in its row's menu: where it's from, its version and
/// path, and why Roga would or wouldn't run it.
nonisolated struct ProgramChoice: Equatable, Identifiable {
    enum Tag: Equatable {
        /// The one Roga uses when nobody chose.
        case recommended
        case tooOld
        /// It didn't say its version, or can't be run.
        case unusable
        /// Chosen with Choose Another…, from somewhere Roga doesn't look.
        case chosen

        var title: String {
            switch self {
            case .recommended: "Recommended"
            case .tooOld: "Too old"
            case .unusable: "Can't use"
            case .chosen: "Chosen by you"
            }
        }

        /// Whether it's a reason Roga can't use the copy, which is amber.
        var isWarning: Bool {
            self == .tooOld || self == .unusable
        }
    }

    var executable: String
    var source: String
    var version: String?
    var tag: Tag?
    /// The path, with the home folder as `~`.
    var path: String
    var why: String
    /// Whether Roga could run it.
    var canChoose = true

    var id: String { executable }

    /// All of it in words, for VoiceOver.
    var spoken: String {
        [[source, version].compactMap(\.self).joined(separator: " "), tag?.title, path, why]
            .compactMap(\.self)
            .joined(separator: ", ")
    }
}

/// The copies in a program's menu, from what Roga found.
nonisolated enum ProgramChoices {
    /// Every git Roga found, and the chosen one first when it's from
    /// somewhere Roga doesn't look.
    ///
    /// - Parameters:
    ///   - chosenPath: The git someone chose, or nil for the one Roga finds.
    ///   - current: The git Roga runs, which says a chosen git's version.
    ///   - failure: Why Roga can't use the chosen git, when it can't.
    static func git(
        _ survey: GitSurvey,
        chosenPath: String?,
        current: GitInstallation?,
        failure: GitInstallationError?,
        home: String = NSHomeDirectory()
    ) -> [ProgramChoice] {
        let recommended = survey.recommended?.executable
        let minimum = GitVersion.minimumSupported
        var choices = survey.copies.map { copy -> ProgramChoice in
            let isFirst = copy.executable == survey.firstInPath
            let isInPath = ProgramSource.isInPath(copy.executable, searchPath: survey.searchPath)
            let tag: ProgramChoice.Tag?
            let why: String
            if copy.isUsable {
                if copy.executable == recommended {
                    tag = .recommended
                    why = isFirst ? "Your terminal runs this one too."
                        : isInPath ? "The first Git in your PATH that's new enough."
                        : "Not in your PATH. Roga looks here after it."
                } else {
                    tag = nil
                    why = isInPath ? "Further along your PATH." : "Not in your PATH."
                }
            } else if copy.version != nil {
                tag = .tooOld
                why = (isFirst ? "Your terminal runs this one, but " : "") + "Roga needs \(minimum.major).\(minimum.minor) or later."
            } else {
                tag = .unusable
                why = isFirst ? "Your terminal runs this one, but it didn't say its version." : "It didn't say its version."
            }
            return ProgramChoice(
                executable: copy.executable,
                source: ProgramSource.of(copy.executable, developerToolsFolder: survey.developerToolsFolder, home: home).name,
                version: copy.version?.description,
                tag: tag,
                path: ProgramSource.abbreviated(copy.executable, home: home),
                why: why,
                canChoose: copy.isUsable
            )
        }
        if let chosenPath, !choices.contains(where: { $0.executable == chosenPath }) {
            var chosen = ProgramChoice(
                executable: chosenPath,
                source: ProgramSource.of(chosenPath, developerToolsFolder: survey.developerToolsFolder, home: home).name,
                tag: .chosen,
                path: ProgramSource.abbreviated(chosenPath, home: home),
                why: "From somewhere Roga doesn't look by itself."
            )
            switch failure {
            case .configuredGitMissing?:
                chosen.tag = .unusable
                chosen.why = "Roga can't find or run it."
                chosen.canChoose = false
            case .configuredGitUnsupported(let skipped)?:
                chosen.version = skipped.version?.description
                chosen.tag = skipped.version == nil ? .unusable : .tooOld
                chosen.why = skipped.version == nil ? "It didn't say its version." : "Roga needs \(minimum.major).\(minimum.minor) or later."
                chosen.canChoose = false
            default:
                if current?.executable == chosenPath { chosen.version = current?.version.description }
            }
            choices.insert(chosen, at: 0)
        }
        return choices
    }

    /// Every copy of an agent Roga found, and the chosen one first when it's
    /// from somewhere Roga doesn't look.
    ///
    /// - Parameters:
    ///   - program: The program someone chose, or nil for the one Roga finds.
    ///   - lookup: What looking for the agent came to, which says a chosen
    ///     program's version, or why Roga can't use it.
    static func agent(
        _ survey: AgentSurvey,
        program: String?,
        lookup: AgentLookup?,
        home: String = NSHomeDirectory()
    ) -> [ProgramChoice] {
        let kind = survey.kind
        let recommended = survey.recommended?.executable
        let usableCount = survey.usable.count
        var choices = survey.copies.map { copy -> ProgramChoice in
            let isFirst = copy.executable == survey.firstInPath
            let isInPath = ProgramSource.isInPath(copy.executable, searchPath: survey.searchPath)
            let tag: ProgramChoice.Tag?
            let why: String
            if let skipped = copy.skipped {
                (tag, why) = reason(skipped, terminalRunsIt: isFirst)
            } else if copy.executable == recommended {
                tag = .recommended
                why = kind.prefersNewest && usableCount > 1 ? "The newest copy, which new models need."
                    : isFirst ? "Your terminal runs this one too."
                    : isInPath ? "The first copy in your PATH that Roga can use."
                    : "Not in your PATH. It's where its installer puts it."
            } else {
                tag = nil
                why = isFirst ? "Your terminal runs this one." : isInPath ? "Further along your PATH." : "Not in your PATH."
            }
            return ProgramChoice(
                executable: copy.executable,
                source: ProgramSource.of(copy.executable, home: home).name,
                version: copy.version?.description,
                tag: tag,
                path: ProgramSource.abbreviated(copy.executable, home: home),
                why: why,
                canChoose: copy.isUsable
            )
        }
        if let program, !choices.contains(where: { $0.executable == program }) {
            var chosen = ProgramChoice(
                executable: program,
                source: ProgramSource.of(program, home: home).name,
                tag: .chosen,
                path: ProgramSource.abbreviated(program, home: home),
                why: "From somewhere Roga doesn't look by itself."
            )
            switch lookup {
            case .found(let installation)? where installation.executable == program:
                chosen.version = installation.version.description
            case .configuredMissing?:
                chosen.tag = .unusable
                chosen.why = "Roga can't find or run it."
                chosen.canChoose = false
            case .configuredUnusable(let skipped)?:
                (chosen.tag, chosen.why) = reason(skipped, terminalRunsIt: false)
                if case .tooOld(let version) = skipped.reason { chosen.version = version.description }
                chosen.canChoose = false
            default:
                break
            }
            choices.insert(chosen, at: 0)
        }
        return choices
    }

    /// Why Roga can't use a copy of an agent, without its path, which the
    /// menu shows on the line above.
    static func reason(_ skipped: SkippedAgent, terminalRunsIt: Bool) -> (ProgramChoice.Tag, String) {
        let lead = terminalRunsIt ? "Your terminal runs this one, but " : ""
        func sentence(_ words: String) -> String {
            lead.isEmpty ? words.prefix(1).uppercased() + words.dropFirst() : lead + words
        }
        switch skipped.reason {
        case .tooOld:
            return (.tooOld, sentence("Roga needs \(skipped.kind.minimumVersion) or later."))
        case .timedOut:
            let limit = AgentInstallation.probeTimeLimit.formatted(.units(allowed: [.seconds], width: .wide))
            return (.unusable, sentence("it didn't say its version within \(limit)."))
        case .noVersion(let status, _):
            switch status {
            case nil: return (.unusable, sentence("it couldn't be started."))
            case .exited(0)?: return (.unusable, sentence("it didn't print a version Roga could read."))
            default: return (.unusable, sentence("it stopped before saying its version."))
            }
        }
    }
}

/// What a program's row says: its name and version, whether Roga found it,
/// its path or a few words in the path's place, and what its button says.
nonisolated struct ProgramRowContent: Equatable {
    enum Status: Equatable {
        case none
        /// Roga ran it and read its version, which gets a green check.
        case detected
        /// Why Roga can't use it, in a word or two, in amber.
        case warning(String)
    }

    enum Tone: Equatable {
        /// A path, in the code font.
        case path
        case plain
        /// Something to do something about, in amber.
        case warn
    }

    /// What the row has at its right.
    enum Select: Equatable {
        /// Roga is still looking, so there's nothing to choose from.
        case none
        /// A button that opens the menu of copies, and says where the one in
        /// use is from.
        case menu(String)
        /// Choose…, which asks for a program, for when Roga found none.
        case choose
    }

    var name: String
    var version: String?
    var status = Status.none
    var line: String
    var tone = Tone.path
    var select = Select.none
    /// Whether the name is gray, because Roga doesn't use the program.
    var isDimmed = false

    /// All of it in words, for VoiceOver.
    var spoken: String {
        var words = [name]
        if let version { words.append(version) }
        switch status {
        case .none: break
        case .detected: words.append("detected")
        case .warning(let warning): words.append(warning.lowercased())
        }
        return words.joined(separator: " ") + ". " + line
    }

    static let looking = "Looking…"
    /// Under an agent someone chose not to use.
    static let unused = "Roga won't use it. Pick a copy from the menu to use it after all."

    /// The row for git.
    static func git(
        state: GitProvider.State,
        survey: GitSurvey?,
        home: String = NSHomeDirectory()
    ) -> ProgramRowContent {
        func source(_ executable: String) -> String {
            ProgramSource.of(executable, developerToolsFolder: survey?.developerToolsFolder, home: home).name
        }
        switch state {
        case .locating:
            return ProgramRowContent(name: "Git", line: looking, tone: .plain)
        case .ready(let git):
            let installation = git.installation
            return ProgramRowContent(
                name: "Git",
                version: installation.version.description,
                status: .detected,
                line: ProgramSource.abbreviated(installation.executable, home: home),
                // Until the survey is in, there's only this one to show.
                select: survey == nil ? .none : .menu(source(installation.executable))
            )
        case .failed(.configuredGitMissing(let path)):
            return ProgramRowContent(
                name: "Git",
                status: .warning("Not found"),
                line: "Roga can't find or run \(ProgramSource.abbreviated(path, home: home)), which you chose.",
                tone: .warn,
                select: .menu(source(path))
            )
        case .failed(.configuredGitUnsupported(let skipped)):
            return ProgramRowContent(
                name: "Git",
                version: skipped.version?.description,
                status: .warning(skipped.version == nil ? "No version" : "Too old"),
                line: ProgramSource.abbreviated(skipped.executable, home: home),
                select: .menu(source(skipped.executable))
            )
        case .failed(.unsupported(let skipped, let developerToolsMissing)):
            guard let first = skipped.first else { return noGit(developerToolsMissing: developerToolsMissing) }
            return ProgramRowContent(
                name: "Git",
                version: first.version?.description,
                status: .warning(first.version == nil ? "No version" : "Too old"),
                line: ProgramSource.abbreviated(first.executable, home: home),
                select: .menu(source(first.executable))
            )
        case .failed(.notFound(let developerToolsMissing)):
            return noGit(developerToolsMissing: developerToolsMissing)
        }
    }

    private static func noGit(developerToolsMissing: Bool) -> ProgramRowContent {
        ProgramRowContent(
            name: "Git",
            line: developerToolsMissing
                ? "Apple's Git comes with the Command Line Tools, which aren't installed."
                : "Roga didn't find Git on this Mac.",
            tone: .plain,
            select: .choose,
            isDimmed: true
        )
    }

    /// The row for an agent.
    ///
    /// - Parameter isOn: Whether Roga uses the agent. One that's off keeps
    ///   its menu, to turn it back on by picking a copy.
    static func agent(
        _ kind: AgentKind,
        lookup: AgentLookup?,
        isOn: Bool,
        home: String = NSHomeDirectory()
    ) -> ProgramRowContent {
        func source(_ executable: String) -> String {
            ProgramSource.of(executable, home: home).name
        }
        func path(_ executable: String) -> String {
            ProgramSource.abbreviated(executable, home: home)
        }
        switch lookup {
        case nil:
            return ProgramRowContent(name: kind.name, line: looking, tone: .plain)
        case .notFound?:
            return ProgramRowContent(
                name: kind.name,
                line: "Not found in your PATH, or where its installer puts it.",
                tone: .plain,
                select: .choose,
                isDimmed: true
            )
        default:
            break
        }
        guard isOn else {
            return ProgramRowContent(name: kind.name, line: unused, tone: .plain, select: .menu("Not used"), isDimmed: true)
        }
        switch lookup {
        case .found(let installation)?:
            return ProgramRowContent(
                name: kind.name,
                version: installation.version.description,
                status: .detected,
                line: path(installation.executable),
                select: .menu(source(installation.executable))
            )
        case .unusable(let skipped)?:
            guard let first = skipped.first else { return ProgramRowContent(name: kind.name, line: looking, tone: .plain) }
            return unusable(kind, first, home: home)
        case .configuredUnusable(let skipped)?:
            return unusable(kind, skipped, home: home)
        case .configuredMissing(let chosen)?:
            return ProgramRowContent(
                name: kind.name,
                status: .warning("Not found"),
                line: "Roga can't find or run \(path(chosen)), which you chose.",
                tone: .warn,
                select: .menu(source(chosen))
            )
        case .notFound?, nil:
            return ProgramRowContent(name: kind.name, line: looking, tone: .plain)
        }
    }

    private static func unusable(_ kind: AgentKind, _ skipped: SkippedAgent, home: String) -> ProgramRowContent {
        var version: String?
        var warning = "Can't use"
        if case .tooOld(let old) = skipped.reason {
            version = old.description
            warning = "Too old"
        }
        return ProgramRowContent(
            name: kind.name,
            version: version,
            status: .warning(warning),
            line: ProgramSource.abbreviated(skipped.executable, home: home),
            select: .menu(ProgramSource.of(skipped.executable, home: home).name)
        )
    }
}
