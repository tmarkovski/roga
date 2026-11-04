import CommitGraph
import Darwin
import GitCore
import GitRunner

/// What came of bringing a repository's commit-graph files up to date.
public enum CommitGraphUpdate: Sendable, Hashable {
    /// The files have every commit that branches, remote branches and tags
    /// lead to, or the repository has no commits yet.
    case upToDate
    /// git wrote what the files were missing.
    case written
    /// Roga left the files alone.
    case skipped(Reason)

    /// Why Roga doesn't write commit-graph files in a repository.
    public enum Reason: Sendable, Hashable, CustomStringConvertible {
        case shallowClone
        case replaceRefs
        case grafts
        /// `core.commitGraph` is false.
        case turnedOffInGit
        case cannotWrite(folder: String)

        /// Why git wouldn't use the files. It doesn't in a shallow clone, or
        /// when replace refs or grafts change commits' parents, because the
        /// files have the parents the commits were made with.
        static func gitIgnoresFiles(in location: RepositoryLocation, refs: RefList) -> Reason? {
            if location.isShallow { return .shallowClone }
            if refs.refs.contains(where: { $0.name.hasPrefix("refs/replace/") }) { return .replaceRefs }
            if access(location.commonDirectory + "/info/grafts", F_OK) == 0 { return .grafts }
            return nil
        }

        /// Whether `core.commitGraph` is false, which also makes git ignore
        /// the files. git fails on a value that isn't a boolean, here and in
        /// every command that reads history.
        static func isTurnedOffInGit(git: Git, in directory: String, priority: GitCommand.Priority = .normal) async throws -> Bool {
            var read = GitCommand("config", "--type=bool", "--default", "true", "core.commitGraph", in: directory)
            read.priority = priority
            return try await git.text(read) == "false"
        }

        public var description: String {
            switch self {
            case .shallowClone: "git doesn't use commit-graph files in a shallow clone."
            case .replaceRefs: "git doesn't use commit-graph files in a repository with replace refs."
            case .grafts: "git doesn't use commit-graph files in a repository with grafts."
            case .turnedOffInGit: "core.commitGraph is false in this repository's git configuration."
            case .cannotWrite(let folder): "Roga can't write to \(folder)."
            }
        }
    }
}

/// Keeps a repository's commit-graph files up to date with `git commit-graph
/// write --reachable --split`, so that large repositories open quickly
/// (decision 6). git takes the locks it needs, so this is safe while the user
/// or an agent runs git.
///
/// `--reachable` follows refs, so it never stores what only a detached `HEAD`
/// reaches. History asks git for those few commits each time it loads.
///
/// git only writes changed-path filters when asked, or when the files already
/// have them, so Roga doesn't add them and doesn't take away a user's.
struct CommitGraphUpkeep: Sendable {
    let git: Git
    let location: RepositoryLocation
    let catFile: CatFileSession

    @concurrent
    func update() async throws -> CommitGraphUpdate {
        let refs = try await RefsLoader.load(git: git, in: location.commonDirectory, priority: .background)
        if let reason = CommitGraphUpdate.Reason.gitIgnoresFiles(in: location, refs: refs) { return .skipped(reason) }
        // git prints a warning and writes nothing when the setting is false,
        // so Roga asks first to be able to say why.
        if try await CommitGraphUpdate.Reason.isTurnedOffInGit(git: git, in: location.commonDirectory, priority: .background) {
            return .skipped(.turnedOffInGit)
        }
        guard try await needsWriting(refs) else { return .upToDate }
        if let folder = readOnlyFolder() { return .skipped(.cannotWrite(folder: folder)) }

        var write = GitCommand("commit-graph", "write", "--reachable", "--split", in: location.commonDirectory)
        write.priority = .background
        _ = try await git.run(write)
        return .written
    }

    /// Whether the files are missing a commit that a branch, remote branch or
    /// tag leads to. Files Roga can't read count as missing every commit,
    /// because git replaces those when it writes.
    private func needsWriting(_ refs: RefList) async throws -> Bool {
        let tips = refs.refs.filter { $0.kind != .other }.map(\.peeled)
        guard !tips.isEmpty else { return false }
        guard let graph = try? CommitGraph(objectsFolder: location.objectsFolder, format: location.format) else { return true }
        return try await !HistoryLoader.commitsMissing(from: graph, tips: tips, catFile: catFile).isEmpty
    }

    /// The folder git would have to write in, if it can't. git makes
    /// `objects/info` when it's missing, which takes writing to `objects`.
    private func readOnlyFolder() -> String? {
        let info = location.objectsFolder + "/info"
        let folder = access(info, F_OK) == 0 ? info : location.objectsFolder
        return access(folder, W_OK) == 0 ? nil : folder
    }
}
