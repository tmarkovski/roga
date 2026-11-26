import Foundation
import GitCore
import GitRunner
import Synchronization

/// A repository to clone from a URL into a folder on this Mac, as the clone form
/// in Add Repositories puts it together (decision 113).
public struct CloneRequest: Sendable, Hashable {
    /// Where the repository is, as the person gave it.
    public var url: String
    /// The folder the clone goes in.
    public var folder: String
    /// The name of the folder the clone makes in `folder`.
    public var name: String
    /// Whether it clones the repository's submodules too. git's
    /// `submodule.recurse` setting doesn't apply to `git clone`, so without
    /// this a repository with submodules arrives with their folders empty.
    public var recursesSubmodules: Bool

    public init(url: String, folder: String, name: String, recursesSubmodules: Bool = true) {
        self.url = url
        self.folder = folder
        self.name = name
        self.recursesSubmodules = recursesSubmodules
    }

    /// The folder the clone makes.
    public var destination: String {
        (folder as NSString).appendingPathComponent(name)
    }

    /// The arguments after `git`. `--progress` has git say how far along it is
    /// even though it isn't writing to a terminal, and the URL comes after
    /// `--end-of-options`, so that one starting with `-` can't be read as an
    /// option.
    public var arguments: [String] {
        ["clone", "--progress"] + (recursesSubmodules ? ["--recurse-submodules"] : []) + ["--end-of-options", url, destination]
    }

    /// What's in the way of cloning, which the form says before Clone can be
    /// pressed.
    public enum Problem: Sendable, Hashable {
        /// There's no URL yet.
        case noURL
        /// There's no name for the clone's folder.
        case noName
        /// The name has a slash, or is `.` or `..`, so it isn't one folder in
        /// `folder`.
        case nameIsNotAFolder
        /// Something is already at `destination`.
        case destinationExists
    }

    /// What's in the way of cloning, or nil when nothing is. It looks at the
    /// disk for `destination`, which is quick.
    public var problem: Problem? {
        if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noURL }
        if name.isEmpty { return .noName }
        if name.contains("/") || name == "." || name == ".." { return .nameIsNotAFolder }
        if FileManager.default.fileExists(atPath: destination) { return .destinationExists }
        return nil
    }

    /// The name git gives a clone's folder when it isn't given one: the last
    /// part of the URL's path without `.git`, as in `linux` for
    /// `git@github.com:torvalds/linux.git`. It's empty when the URL has no path.
    public static func name(fromURL url: String) -> String {
        var path = Substring(url.trimmingCharacters(in: .whitespacesAndNewlines))
        if let scheme = path.firstRange(of: "://") {
            // The host alone isn't a name.
            let rest = path[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return "" }
            path = rest[slash...]
        }
        for _ in 0..<2 {
            while path.hasSuffix("/") { path = path.dropLast() }
            if path.hasSuffix(".git") { path = path.dropLast(4) }
        }
        guard let last = path.split(whereSeparator: { $0 == "/" || $0 == ":" }).last else { return "" }
        return String(last)
    }
}

/// How far along a clone is, from what `git clone --progress` writes to
/// standard error.
public struct CloneProgress: Sendable, Hashable {
    /// What git is doing, in lowercase, as in `receiving objects`, or nil
    /// before it says.
    public var step: String?
    /// How far through `step` it is, from 0 to 100, for a step that says.
    public var percent: Int?
    /// The path of the submodule git is cloning, as in `vendor/lib`, once it
    /// has moved on to the submodules.
    public var submodule: String?

    public init(step: String? = nil, percent: Int? = nil, submodule: String? = nil) {
        self.step = step
        self.percent = percent
        self.submodule = submodule
    }
}

/// Reads what `git clone --progress` writes to standard error a chunk at a
/// time. git ends each update of a step with a carriage return, so that a
/// terminal writes the next over it, and ends a step with a line break.
public struct CloneProgressReader: Sendable {
    /// The folder the clone makes, which tells its own `Cloning into` from a
    /// submodule's.
    let destination: String
    /// What's arrived since the last carriage return or line break.
    private var pending: [UInt8] = []
    public private(set) var progress = CloneProgress()

    public init(destination: String) {
        self.destination = destination
    }

    /// Reads a chunk, and returns the progress when it changed.
    public mutating func read(_ bytes: [UInt8]) -> CloneProgress? {
        let before = progress
        for byte in bytes {
            if byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n") {
                take(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(byte)
            }
        }
        return progress == before ? nil : progress
    }

    private mutating func take(_ line: String) {
        if let step = Self.step(line) {
            progress.step = step.name
            progress.percent = step.percent
        } else if let folder = Self.cloningInto(line) {
            let prefix = destination.hasSuffix("/") ? destination : destination + "/"
            if folder == destination {
                progress = CloneProgress()
            } else {
                progress = CloneProgress(submodule: folder.hasPrefix(prefix) ? String(folder.dropFirst(prefix.count)) : folder)
            }
        }
    }

    /// A line of progress, as in `Receiving objects:  42% (520/1234)` or
    /// `remote: Enumerating objects: 1234, done.`: its step in lowercase, and
    /// how far through it git is when it says.
    static func step(_ line: String) -> (name: String, percent: Int?)? {
        var text = Substring(line)
        if text.hasPrefix("remote: ") { text = text.dropFirst("remote: ".count) }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let name = text[..<colon]
        // A step's name is words, starting with a capital, which leaves out
        // `fatal:`, `warning:` and anything with a URL in it.
        guard let first = name.first, first.isUppercase, name.allSatisfy({ $0.isLetter || $0 == " " }) else { return nil }
        let rest = text[text.index(after: colon)...].drop { $0 == " " }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let percent = rest.dropFirst(digits.count).first == "%" ? Int(digits) : nil
        return (name.lowercased(), percent)
    }

    /// The folder in `Cloning into '/Users/me/git/api'...`.
    static func cloningInto(_ line: String) -> String? {
        let start = "Cloning into '"
        let end = "'..."
        guard line.hasPrefix(start), line.hasSuffix(end), line.count >= start.count + end.count else { return nil }
        return String(line.dropFirst(start.count).dropLast(end.count))
    }

    /// What git said, without its lines of progress, for the refusal dialog.
    public static func messages(in errorOutput: String) -> String {
        errorOutput
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "remote:" && step($0) == nil }
            .joined(separator: "\n")
    }
}

/// Runs `git clone` (decision 113).
public enum Cloning {
    /// Clones the repository, and passes how far along it is to `progress` as
    /// git says, on a queue of its own.
    ///
    /// It uses the person's own credential helpers and SSH setup, as Pull and
    /// Push do. Nothing can answer a prompt for a credential, so one that
    /// needs asking for fails, and git says why.
    ///
    /// - Throws: `GitError` when git refuses, with what it said and without its
    ///   lines of progress, or `CancellationError` when the task is cancelled,
    ///   which stops git and waits for it to exit. git deletes the folder it
    ///   was making either way.
    @concurrent
    public static func run(_ request: CloneRequest, git: Git, progress: @escaping @Sendable (CloneProgress) -> Void) async throws {
        let command = GitCommand(request.arguments, in: request.folder)
        let reader = Mutex(CloneProgressReader(destination: request.destination))
        do {
            _ = try await git.run(command) { bytes in
                if let changed = reader.withLock({ $0.read(bytes) }) { progress(changed) }
            }
        } catch GitError.failed(let command, let status, let errorOutput) {
            throw GitError.failed(command, status, errorOutput: CloneProgressReader.messages(in: errorOutput))
        }
    }
}
