import Foundation
import GitCore
import GitRunner

/// A repository found in a folder on this Mac.
public struct LocalClone: Sendable, Hashable, Identifiable {
    /// The clone's top folder, with symbolic links resolved, as git gives it.
    public var path: String
    /// Who owns it, from its remotes' URLs, with `origin`'s owner first.
    public var owners: [String]
    /// When its index last changed, which is about when someone last worked
    /// in it.
    public var lastUsed: Date?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, owners: [String] = [], lastUsed: Date? = nil) {
        self.path = path
        self.owners = owners
        self.lastUsed = lastUsed
    }
}

/// Finds the repositories that could be added to the sidebar, without opening
/// them (decision 16).
public enum LocalClones {
    /// How many git commands run at once. A folder can hold hundreds of clones.
    private static let concurrentCommands = 8

    /// Looks for clones in each folder and in the folders right inside it,
    /// but no deeper, and lists the latest used first.
    ///
    /// A linked worktree's `.git` is a file, so only a repository's main
    /// worktree counts. A bare repository doesn't, because it can't be told
    /// from any other folder without running git in every one of them.
    @concurrent
    public static func find(in folders: [String], git: Git) async -> [LocalClone] {
        var seen: Set<String> = []
        var candidates = folders.flatMap(self.candidates(in:)).filter { seen.insert($0).inserted }.makeIterator()
        var clones: [LocalClone] = []
        await withTaskGroup(of: LocalClone.self) { group in
            for _ in 0..<concurrentCommands {
                guard let path = candidates.next() else { break }
                group.addTask { await clone(at: path, git: git) }
            }
            for await clone in group {
                clones.append(clone)
                if let path = candidates.next() {
                    group.addTask { await Self.clone(at: path, git: git) }
                }
            }
        }
        return clones.sorted { first, second in
            if first.lastUsed != second.lastUsed { return (first.lastUsed ?? .distantPast) > (second.lastUsed ?? .distantPast) }
            return first.path < second.path
        }
    }

    /// Who owns the repository in a directory, from its remotes' URLs, with
    /// `origin`'s owner first.
    static func owners(in directory: String, git: Git) async throws -> [String] {
        RemoteAddress.owners(try await RefDetailsLoader.remoteURLs(git: git, in: directory))
    }

    private static func candidates(in folder: String) -> [String] {
        guard let resolved = realpath(folder, nil) else { return [] }
        defer { free(resolved) }
        let folder = String(cString: resolved)
        let children = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return ([folder] + children.sorted().map { folder + "/" + $0 }).filter(isClone)
    }

    private static func isClone(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// git can't always read a clone's configuration, such as one owned by
    /// someone else, and that only leaves it without an owner.
    private static func clone(at path: String, git: Git) async -> LocalClone {
        let owners = try? await Self.owners(in: path, git: git)
        return LocalClone(path: path, owners: owners ?? [], lastUsed: lastUsed(path))
    }

    private static func lastUsed(_ path: String) -> Date? {
        for file in ["index", "HEAD"] {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path + "/.git/" + file),
               let date = attributes[.modificationDate] as? Date
            {
                return date
            }
        }
        return nil
    }
}
