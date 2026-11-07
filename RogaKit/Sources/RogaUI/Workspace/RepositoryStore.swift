import Foundation
import os

/// The file that keeps the sidebar's repositories between launches,
/// `repositories.json` in Roga's folder in Application Support.
///
/// Window restoration can't keep them, because macOS closes windows without
/// saving them when an app quits, unless the user turned that off in System
/// Settings or quit with Option-Command-Q.
struct RepositoryStore {
    struct Contents: Codable, Equatable {
        var version = 1
        /// The repositories in the order the sidebar lists them.
        var repositories: [SavedRepository] = []
        /// The worktree selected last in any window, which a window shows
        /// when it opens without one of its own.
        var lastSelection: WorktreeSelection?
    }

    struct SavedRepository: Codable, Equatable {
        /// The repository's git directory, which all of its worktrees share.
        /// Worktrees aren't saved, because git lists them.
        var path: String
        /// A bookmark to the git directory, which finds it after the
        /// repository moves to another folder.
        var bookmark: Data?
        var isExpanded = true
        /// The linked worktrees it goes on showing while it's collapsed, by
        /// their folders.
        var keptWorktrees: [String]?
        /// Who owns the repository, from its remotes' URLs, with `origin`'s
        /// owner first. It's saved so that the groups are in their usual order at
        /// launch, and so that a repository on a disk that isn't mounted stays
        /// in its organization.
        var owner: String?
        /// The owners after the first, when its remotes have more than one.
        var moreOwners: [String]?
    }

    let file: URL

    /// The file in Roga's folder in Application Support.
    static var standard: RepositoryStore {
        let folder = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "roga")
        return RepositoryStore(file: folder.appending(path: "repositories.json"))
    }

    /// The file that keeps a file Roga couldn't read, so that saving doesn't
    /// overwrite it.
    var unreadableFile: URL {
        file.deletingLastPathComponent().appending(path: "repositories.unreadable.json")
    }

    /// Reads the file. A missing file means nothing has been saved yet. A
    /// file Roga can't read is moved aside, and Roga starts with an empty
    /// list.
    func load() -> Contents {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            return Contents()
        }
        do {
            return try JSONDecoder().decode(Contents.self, from: data)
        } catch {
            Self.log.error("Couldn't read \(file.path(percentEncoded: false), privacy: .public): \(error)")
            try? FileManager.default.removeItem(at: unreadableFile)
            try? FileManager.default.moveItem(at: file, to: unreadableFile)
            return Contents()
        }
    }

    /// Writes the file in one step, so that it's never left half written.
    func save(_ contents: Contents) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(contents)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            Self.log.error("Couldn't save \(file.path(percentEncoded: false), privacy: .public): \(error)")
        }
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "roga", category: "repositories")
}
