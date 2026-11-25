import Foundation
import GitCore
import RepositoryEngine
import SwiftUI
import ThemeUI

/// What the window says about who a repository's commits go out as
/// (decision 103): the tooltip on the title row's person (decision 105), where
/// each setting comes from, and what's wrong.
struct IdentityWords {
    let identity: CommitIdentity
    /// Where git keeps the user's global config, to tell a file that it
    /// includes from the file itself.
    var globalFiles = GlobalConfigFiles()

    /// Who commits go out as, then where that comes from, then how they're
    /// signed or what would go wrong, on three lines.
    var tooltip: String {
        [who, from(capitalized: true), signing].joined(separator: "\n")
    }

    /// What VoiceOver reads for the identity.
    var spoken: String {
        [who, signing].joined(separator: ", ")
    }

    /// The name and the email, as git writes them into a commit.
    var who: String {
        let name = identity.shownName
        guard let email = identity.shownEmail else {
            return name.map { "\($0), with no email" } ?? "No name or email"
        }
        return name.map { "\($0) <\(email)>" } ?? "<\(email)>"
    }

    /// Where the email comes from, or the name when there's no email.
    func from(capitalized: Bool) -> String {
        guard let origin = (identity.email ?? identity.name)?.origin else {
            return capitalized ? "Nothing in git's config says who commits are from" : "not set"
        }
        let words = Self.origin(origin, globalFiles: globalFiles)
        return capitalized ? words.prefix(1).uppercased() + words.dropFirst() : words
    }

    /// How commits are signed, or what would go wrong with one made now.
    var signing: String {
        switch identity.problem {
        case .noEmail:
            return "git would refuse to commit, or make an email up from your login and this Mac's name."
        case .noSigningKey:
            return "Signing with SSH is on, but no key is set, so a commit would stop at signing."
        case nil:
            guard identity.signs else { return "Not signed" }
            return ["Signed with \(identity.format.title)", identity.key].compactMap(\.self).joined(separator: " · ")
        }
    }

    /// Where a setting comes from, in lowercase, as the popover writes it
    /// under each field.
    static func origin(_ origin: ConfigOrigin, globalFiles: GlobalConfigFiles) -> String {
        switch origin.scope {
        case .global, .system:
            guard let file = origin.file else { return "from git's config" }
            let shown = globalFiles.abbreviated(file)
            if origin.scope == .global, !globalFiles.paths.contains(file), let including = globalFiles.shownFile {
                return "from \(shown), which \(including) includes"
            }
            return "from \(shown)"
        case .local:
            return "this repository's own"
        case .worktree:
            return "this worktree's own"
        case .command:
            return "from git's environment"
        case .unknown:
            return "from git's config"
        }
    }

    /// What a repository's second line in the sidebar says when a commit
    /// would go wrong.
    static func rowWords(_ problem: CommitIdentity.Problem) -> String {
        switch problem {
        case .noEmail: "No email for commits"
        case .noSigningKey: "Signing needs a key"
        }
    }

    /// What VoiceOver reads on a repository's row, when the row says
    /// anything about who its commits go out as.
    static func spoken(_ exception: IdentityException) -> String {
        switch exception {
        case .problem(let problem): rowWords(problem)
        case .someoneElse(let identity): "Commits as \(identity.shownEmail ?? identity.shownName ?? "someone else")"
        }
    }

    /// What the box says at its top when a commit would go wrong.
    static func problem(_ problem: CommitIdentity.Problem) -> (title: String, detail: String) {
        switch problem {
        case .noEmail:
            ("No email to commit with", "git would refuse to commit, or make one up from your login and this Mac's name.")
        case .noSigningKey:
            ("Signing is on, but there's no key", "SSH signing needs user.signingkey, so the commit would stop at signing.")
        }
    }
}

/// The tint that the person of an identity takes, one of the graph's lane
/// colors picked by the email, so that a work identity and a personal one
/// look different wherever they show.
enum IdentityTint {
    /// One of the theme's lane colors, picked by the email.
    @MainActor static func color(for identity: CommitIdentity) -> Color? {
        guard let email = identity.shownEmail?.lowercased() else { return nil }
        let lanes = colored(ColorTheme.observed.colors.lanes)
        return Color(nsColor: lanes[Int(hash(email) % 1024) % lanes.count].color)
    }

    /// The lanes that have a color of their own. A lane that's nearly gray,
    /// as Monokai's Stone and Xcode's Slate are, would make someone else look
    /// like the global identity, whose person is gray. They're judged by
    /// their light values, so an email keeps its color in both appearances.
    static func colored(_ lanes: [ThemeColor]) -> [ThemeColor] {
        let colored = lanes.filter { ($0.light.usingColorSpace(.sRGB)?.saturationComponent ?? 0) >= 0.35 }
        return colored.isEmpty ? lanes : colored
    }

    /// FNV-1a, which gives an email the same color every time Roga runs, as
    /// Swift's own hashing doesn't.
    static func hash(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}

/// Where git keeps the user's global config: `~/.gitconfig`, and the
/// config in `~/.config/git`, which git reads before it, or the file
/// `GIT_CONFIG_GLOBAL` names instead of both.
struct GlobalConfigFiles: Equatable {
    var paths: [String]
    /// The home folder, which paths show as `~`.
    var home: String

    init(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        if let file = environment["GIT_CONFIG_GLOBAL"], !file.isEmpty {
            paths = [file]
            return
        }
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        paths = [home + "/.gitconfig", configHome + "/git/config"]
    }

    /// The file `git config --global` writes to, as a person would write it:
    /// the first of them that's there, or `~/.gitconfig` when neither is.
    var shownFile: String? {
        let file = paths.first { FileManager.default.fileExists(atPath: $0) } ?? paths.first
        return file.map(abbreviated)
    }

    /// A path with the home folder as `~`.
    func abbreviated(_ path: String) -> String {
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// The config files outside repositories that identities came from, with
/// when each last changed, so that coming back to Roga can tell whether
/// `~/.gitconfig` or a file it includes changed since. No session watches
/// them, since they aren't in any repository (decision 103).
struct IdentityFiles {
    /// When each file last changed, or nil when it wasn't there.
    private var dates: [String: Date?] = [:]

    init(globalFiles: GlobalConfigFiles = GlobalConfigFiles()) {
        for path in globalFiles.paths {
            dates[path] = Self.modificationDate(path)
        }
    }

    /// Starts keeping track of the files outside repositories that an
    /// identity's settings came from, such as one that `~/.gitconfig`
    /// includes for some folders.
    mutating func remember(_ identity: CommitIdentity) {
        let settings = [identity.name, identity.email, identity.signingKey, identity.signsCommits, identity.signingFormat, identity.defaultKeyCommand]
        for case let setting? in settings where setting.origin.scope == .global || setting.origin.scope == .system {
            guard let file = setting.origin.file, file.hasPrefix("/"), !dates.keys.contains(file) else { continue }
            dates[file] = Self.modificationDate(file)
        }
    }

    /// Whether any of the files changed, came or went since it last looked.
    func haveChanged() -> Bool {
        dates.contains { path, date in Self.modificationDate(path) != date }
    }

    /// Takes when each file changed as it is now.
    mutating func noteDates() {
        for path in dates.keys {
            dates[path] = Self.modificationDate(path)
        }
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
