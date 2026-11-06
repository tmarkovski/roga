import GitCore
import GitRunner

/// What's staged in a worktree, read once and cut down to a size an agent can
/// read quickly, for writing a commit message (decision 41).
///
/// The list of files is always complete, so the agent sees the whole change
/// even when the patch can't show all of it. The patch leaves out files whose
/// text says little about the change, such as lockfiles, and then, only when
/// it's still longer than the budget, the ends of very long lines, then files
/// too long to show even in part, then hunks. Each place where something was
/// left out says so, so the agent doesn't have to guess.
public struct StagedChanges: Sendable, Hashable {
    public struct File: Sendable, Hashable {
        /// The file's path from the top of the repository, after the change.
        public var path: String
        /// Where a renamed file came from.
        public var oldPath: String?
        /// The letter git uses for the change, such as `M` or `R`.
        public var status: Character
        /// The lines added and removed, which are nil for a binary file.
        public var added: Int?
        public var deleted: Int?
        /// Why the patch doesn't show the file, or nil when it does.
        public var leftOut: LeftOut?
        /// How many of the file's hunks the patch leaves out for length. Its
        /// first hunk is always shown.
        public var hunksLeftOut: Int

        public init(
            path: String,
            oldPath: String? = nil,
            status: Character,
            added: Int? = nil,
            deleted: Int? = nil,
            leftOut: LeftOut? = nil,
            hunksLeftOut: Int = 0
        ) {
            self.path = path
            self.oldPath = oldPath
            self.status = status
            self.added = added
            self.deleted = deleted
            self.leftOut = leftOut
            self.hunksLeftOut = hunksLeftOut
        }

        /// What to tell the agent about how much of the file the patch shows,
        /// or nil when it shows all of it.
        public var note: String? {
            switch leftOut {
            case .lockfile: return "lockfile, not shown"
            case .generated: return "generated, not shown"
            case .binary: return "binary, not shown"
            case .tooLong: return "too long, not shown"
            case nil:
                guard hunksLeftOut > 0 else { return nil }
                return hunksLeftOut == 1 ? "1 hunk not shown" : "\(hunksLeftOut) hunks not shown"
            }
        }
    }

    /// Why a file's changes aren't in the patch.
    public enum LeftOut: Sendable, Hashable {
        /// A lockfile, such as `package-lock.json`, whose changes follow from
        /// another file's.
        case lockfile
        /// A file that a tool writes, such as an Xcode project or a minified
        /// script.
        case generated
        /// A file without lines.
        case binary
        /// A file whose changes didn't fit in the budget.
        case tooLong
    }

    public var files: [File]
    /// The patch, with left-out files and hunks taken out and a marker in
    /// brackets where each was.
    public var patch: String
    /// Whether anything was left out for length, rather than for what kind of
    /// file it is.
    public var isCut: Bool
    /// A hash of everything git printed for the staged changes, so that Roga
    /// can tell whether they changed while an agent was writing about them.
    public var digest: String

    public init(files: [File], patch: String, isCut: Bool, digest: String) {
        self.files = files
        self.patch = patch
        self.isCut = isCut
        self.digest = digest
    }
}

// MARK: - Reading

extension StagedChanges {
    /// The most patch Roga reads. Past this, it sends the list of files alone,
    /// which says more than an error would.
    static let readLimit = DiffLoader.patchLimit

    /// The longest a line of a hunk can be once the patch is over its budget.
    static let lineLimit = 256

    /// Variables that would change what git prints for a patch. `GIT_DIFF_OPTS`
    /// overrides `-U`, and the other two choose an external diff program. A
    /// command can't remove a variable from its environment, but git treats an
    /// empty one the same as one that isn't set.
    static let clearedVariables = ["GIT_DIFF_OPTS", "GIT_EXTERNAL_DIFF", "GIT_EXTERNAL_DIFF_TRUST_EXIT_CODE"]

    /// The command with `clearedVariables` set to empty strings.
    private static func clearingDiffVariables(_ command: GitCommand) -> GitCommand {
        var command = command
        for name in clearedVariables {
            command.environment[name] = ""
        }
        return command
    }

    /// Reads what's staged in a worktree and cuts its patch down to `budget`
    /// bytes.
    ///
    /// The list of files and the patch come from two runs of `diff-index`,
    /// which is plumbing, so settings such as `diff.noprefix`, `diff.context`
    /// and `diff.external` don't change what it prints. They run side by side,
    /// so if something stages a file in between, the patch may not match the
    /// list. Sections of the patch are matched to files by their headers, and
    /// one that matches nothing is kept as it is.
    @concurrent
    static func load(
        in directory: String,
        amending: Bool,
        budget: Int,
        format: ObjectFormat,
        git: Git,
        limit: Int = readLimit
    ) async throws -> StagedChanges {
        let base = try await base(in: directory, amending: amending, format: format, git: git)

        // A `--` ends the revisions, so that a file named like one can't make
        // git ask which was meant.
        let list = clearingDiffVariables(
            GitCommand(["diff-index", "--cached", "-r", "-M"] + RawDiffParser.arguments + [base.hex, "--"], in: directory)
        )
        var patchCommand = GitCommand(
            ["diff-index", "--cached", "-r", "-M", "-p", "--no-color", "--no-ext-diff", "-U3", "--submodule=short", base.hex, "--"],
            in: directory
        )
        // The agent reads the paths in the patch's headers, so they're better
        // as they are than as octal escapes.
        patchCommand.configuration["core.quotePath"] = "false"
        let patch = clearingDiffVariables(patchCommand)

        async let listed = git.run(list).output
        async let patched = read(patch, git: git, limit: limit)
        let listOutput = try await listed
        let (patchOutput, isComplete) = try await patched

        let files: [DiffFile]
        do {
            files = try RawDiffParser.parse(listOutput)
        } catch {
            throw RepositoryError.unexpectedOutput(list, error.description)
        }
        var changes = cut(files: files, patch: isComplete ? patchOutput : nil, budget: budget)
        changes.digest = digest(of: listOutput, patchOutput)
        return changes
    }

    /// The commit the index is compared with: `HEAD`, or `HEAD`'s first parent
    /// when amending, so the message describes the whole amended commit. It's
    /// the empty tree when there's no such commit, before the first commit or
    /// when amending the first one.
    private static func base(in directory: String, amending: Bool, format: ObjectFormat, git: Git) async throws -> ObjectID {
        var command = GitCommand("rev-parse", "--verify", "--quiet", amending ? "HEAD^" : "HEAD", in: directory)
        command.successStatuses = [0, 1]
        return ObjectID(hex: try await git.text(command)) ?? format.emptyTree
    }

    /// Reads a patch up to `limit` bytes, and says whether it read all of it.
    /// Leaving the loop early stops git.
    private static func read(_ command: GitCommand, git: Git, limit: Int) async throws -> ([UInt8], Bool) {
        var output: [UInt8] = []
        for try await chunk in git.stream(command) {
            output.append(contentsOf: chunk)
            if output.count > limit { return (output, false) }
        }
        return (output, true)
    }

    /// The last `count` subjects on `HEAD`'s first-parent line, leaving out
    /// merges, whose subjects git writes rather than the author.
    ///
    /// `rev-list` is plumbing, so `log.showSignature` can't add lines, and
    /// `--ignore-missing` makes a branch without commits list nothing instead
    /// of failing. The `--` after `HEAD` stops git from refusing it as
    /// ambiguous when the top of the worktree holds a file or folder of that
    /// name. APFS ignores case by default, so a file named `head` is enough.
    @concurrent
    static func recentSubjects(in directory: String, count: Int, git: Git) async throws -> [String] {
        guard count > 0 else { return [] }
        let command = GitCommand(
            "rev-list", "--no-commit-header", "--format=%s", "--encoding=UTF-8", "--first-parent", "--no-merges",
            "--max-count=\(count)", "--ignore-missing", "HEAD", "--",
            in: directory
        )
        return try await git.text(command).split(separator: "\n").map(String.init)
    }

    /// FNV-1a, which is enough to notice a change and needs no framework.
    /// Nothing depends on it for security.
    static func digest(of parts: [UInt8]...) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for part in parts {
            for byte in part {
                hash ^= UInt64(byte)
                hash = hash &* 0x100_0000_01b3
            }
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

// MARK: - Cutting

extension StagedChanges {
    /// Files named this are lockfiles, whose changes follow from a change to
    /// another file and say little about it.
    static let lockfileNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb", "Cargo.lock", "go.sum",
        "Gemfile.lock", "poetry.lock", "uv.lock", "composer.lock", "Podfile.lock", "Package.resolved", "flake.lock",
    ]

    /// Why a file's patch isn't worth showing, whatever its length, or nil
    /// when it is.
    static func kind(of file: DiffFile) -> LeftOut? {
        let name = String(file.name)
        if lockfileNames.contains(name) { return .lockfile }
        if name.hasSuffix(".pbxproj") || name.hasSuffix(".map") { return .generated }
        if let range = name.firstRange(of: ".min."), range.upperBound < name.endIndex { return .generated }
        if file.lines == nil, file.status != .other("U") { return .binary }
        return nil
    }


    /// Builds the staged changes from the files `diff-index --raw --numstat`
    /// listed and the patch `diff-index -p` printed, cutting the patch to
    /// `budget` bytes in the order research for decision 41 settled on:
    ///
    /// 1. Lockfiles, generated files and binary files become a line in the
    ///    patch that says they're left out, unless they're all that's staged.
    /// 2. Lines of hunks longer than `lineLimit` characters lose their ends.
    /// 3. Files that are too long even with only their first hunks are left
    ///    out whole, the longest first, until the rest could fit. A new file
    ///    has a single hunk, so this is the only way one that's too long can
    ///    make room. It comes before step 4, so that the other files don't
    ///    lose hunks they'd have room for once it's gone.
    /// 4. The file with the most hunks loses its last one, again and again,
    ///    until the patch fits, which step 3 made sure it can.
    ///
    /// Steps 2 to 4 happen only while the patch is longer than the budget.
    /// When even the lines that mark left-out files don't fit, the list of
    /// files is all there is.
    ///
    /// - Parameter patch: What git printed, or nil when it was too long to
    ///   read, which leaves the list of files alone.
    static func cut(files diffFiles: [DiffFile], patch: [UInt8]?, budget: Int) -> StagedChanges {
        var files = diffFiles.map { file in
            File(
                path: file.path,
                oldPath: file.oldPath,
                status: file.status.letter.first ?? "?",
                added: file.lines?.added,
                deleted: file.lines?.removed
            )
        }
        let kinds = diffFiles.map(kind(of:))
        // Someone who staged only a lockfile wants a message about it.
        let leavesOutKinds = kinds.contains(nil)

        guard let patch else {
            for index in files.indices {
                files[index].leftOut = leavesOutKinds ? kinds[index] ?? .tooLong : .tooLong
            }
            return StagedChanges(files: files, patch: "", isCut: true, digest: "")
        }

        var document = PatchDocument(bytes: patch)
        document.attribute(to: diffFiles)
        if leavesOutKinds {
            for index in files.indices {
                guard let kind = kinds[index] else { continue }
                files[index].leftOut = kind
                document.leaveOut(file: index, marker: "[\(files[index].note ?? "not shown")]")
            }
        }

        var isCut = false
        if document.size > budget {
            isCut = document.cutLongLines(to: lineLimit)
        }
        if document.size > budget {
            isCut = true
            for file in document.leaveOutLongestFiles(toFit: budget) {
                files[file].leftOut = .tooLong
            }
            guard document.smallestSize <= budget else {
                // Even the markers don't fit, so the list of files is all
                // there is.
                for index in files.indices where files[index].leftOut == nil {
                    files[index].leftOut = .tooLong
                }
                return StagedChanges(files: files, patch: "", isCut: true, digest: "")
            }
            document.dropHunks(toFit: budget)
            for (file, count) in document.hunksLeftOut() {
                files[file].hunksLeftOut = count
            }
        }
        return StagedChanges(files: files, patch: document.text, isCut: isCut, digest: "")
    }
}

/// A patch split into a section for each file, and each section into its
/// header and its hunks, so that parts of it can be left out.
///
/// Every length it needs is counted once, when it reads the patch, and kept
/// up to date as parts are left out, so cutting takes time in proportion to
/// the patch rather than to its hunks times their lines. A patch can be as
/// long as `StagedChanges.readLimit`, and someone who clicked Generate waits
/// on this.
struct PatchDocument {
    /// A line of the patch, without its newline: either a range of the bytes
    /// git printed, or text Roga wrote in its place.
    enum Line {
        case original(Range<Int>)
        case written([UInt8])

        var count: Int {
            switch self {
            case .original(let range): range.count
            case .written(let bytes): bytes.count
            }
        }
    }

    struct Section {
        /// The lines before the first hunk, starting with `diff --git`.
        var header: [Line]
        var hunks: [[Line]] = []
        /// Each hunk's length in bytes, newlines included.
        var hunkSizes: [Int] = []
        /// How many of `hunks` are kept, from the first.
        var keptHunks = 0
        /// The length of the header, and of the hunks that are kept.
        var headerSize: Int
        var keptSize = 0
        /// The file in the list this section is about, or nil when its header
        /// matched none of them.
        var file: Int?
        /// Whether a marker has taken the place of everything after the first
        /// line of the header.
        var isLeftOut = false
        /// The marker for a left-out file, or nil.
        var marker: [UInt8]?

        init(header line: Range<Int>) {
            header = [.original(line)]
            headerSize = line.count + 1
        }

        /// Adds a line that starts a hunk.
        mutating func startHunk(_ line: Range<Int>) {
            hunks.append([.original(line)])
            hunkSizes.append(line.count + 1)
            keptHunks += 1
            keptSize += line.count + 1
        }

        /// Adds a line to the last hunk, or to the header before the first.
        mutating func append(_ line: Range<Int>) {
            guard !hunks.isEmpty else {
                header.append(.original(line))
                headerSize += line.count + 1
                return
            }
            hunks[hunks.count - 1].append(.original(line))
            hunkSizes[hunks.count - 1] += line.count + 1
            keptSize += line.count + 1
        }

        /// Puts `line` in the place of a hunk's line.
        mutating func replace(line index: Int, ofHunk hunk: Int, with line: Line) {
            let change = line.count - hunks[hunk][index].count
            hunks[hunk][index] = line
            hunkSizes[hunk] += change
            if hunk < keptHunks { keptSize += change }
        }

        mutating func dropLastHunk() {
            keptHunks -= 1
            keptSize -= hunkSizes[keptHunks]
        }

        /// The section's length in bytes, as the patch now shows it.
        var size: Int {
            if isLeftOut {
                guard let first = header.first else { return 0 }
                return first.count + 1 + (marker.map { $0.count + 1 } ?? 0)
            }
            return headerSize + keptSize + PatchDocument.hunkMarkerSize(leavingOut: hunks.count - keptHunks)
        }

        /// The section's length once it's down to its first hunk, which is as
        /// short as dropping hunks can make it.
        var smallestSize: Int {
            guard !isLeftOut, hunks.count > 1 else { return size }
            return headerSize + hunkSizes[0] + PatchDocument.hunkMarkerSize(leavingOut: hunks.count - 1)
        }
    }

    let bytes: [UInt8]
    var sections: [Section] = []
    /// The sections about each file in the list, by the file's index.
    private var sectionsOfFile: [Int: [Int]] = [:]
    /// The patch's length in bytes, kept up to date as parts are left out.
    private(set) var size = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        var start = 0
        while start < bytes.count {
            let end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.count
            let line = start..<end
            start = end + 1
            if Self.startsSection(bytes[line]) || sections.isEmpty {
                // git starts every section with a header, so a first line
                // that isn't one doesn't happen, but it's kept rather than
                // lost.
                sections.append(Section(header: line))
            } else if bytes[line].starts(with: "@@".utf8) {
                // Every line inside a hunk starts with a space, a plus, a minus
                // or a backslash, so this is always a new hunk.
                sections[sections.count - 1].startHunk(line)
            } else {
                sections[sections.count - 1].append(line)
            }
        }
        size = sections.reduce(0) { $0 + $1.size }
    }

    private static func startsSection(_ line: ArraySlice<UInt8>) -> Bool {
        line.starts(with: "diff --git ".utf8) || line.starts(with: "* Unmerged path ".utf8)
    }

    /// What takes the place of the hunks a section leaves out.
    static func hunkMarker(leavingOut count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "[1 more hunk in this file not shown]" : "[\(count) more hunks in this file not shown]"
    }

    /// The marker's length in bytes with its newline, or 0 when there's none.
    static func hunkMarkerSize(leavingOut count: Int) -> Int {
        hunkMarker(leavingOut: count).map { $0.utf8.count + 1 } ?? 0
    }

    /// The patch's length once every section is down to its first hunk.
    var smallestSize: Int {
        sections.reduce(0) { $0 + $1.smallestSize }
    }

    /// Says which file each section is about, by comparing its first line with
    /// the header git prints for each file in the list. Both lists are in the
    /// same order. A file that changed from one kind of file to another, such
    /// as to a symbolic link, has two sections with the same header.
    mutating func attribute(to files: [DiffFile]) {
        let headers = files.map(Self.header(for:))
        var next = 0
        var last: Int?
        var lastSections = 0
        for index in sections.indices {
            guard case .original(let range) = sections[index].header[0] else { continue }
            let line = bytes[range]
            if let last, lastSections == 1, files[last].status == .typeChanged, line.elementsEqual(headers[last]) {
                sections[index].file = last
                sectionsOfFile[last, default: []].append(index)
                lastSections += 1
                continue
            }
            if let match = (next..<files.count).first(where: { line.elementsEqual(headers[$0]) }) {
                sections[index].file = match
                sectionsOfFile[match, default: []].append(index)
                last = match
                lastSections = 1
                next = match + 1
            }
        }
    }

    /// The first line git prints for a file's section of a patch, with
    /// `core.quotePath` off.
    static func header(for file: DiffFile) -> [UInt8] {
        if file.status == .other("U") {
            return Array("* Unmerged path ".utf8) + Array(file.path.utf8)
        }
        return Array("diff --git ".utf8) + quoted("a/" + (file.oldPath ?? file.path)) + [0x20] + quoted("b/" + file.path)
    }

    /// A path as git quotes it with `core.quotePath` off: in double quotes,
    /// with C escapes, when it holds a control character, a double quote or a
    /// backslash, and as it is otherwise (git's `quote_c_style`).
    static func quoted(_ path: String) -> [UInt8] {
        let bytes = Array(path.utf8)
        func mustQuote(_ byte: UInt8) -> Bool {
            byte < 0x20 || byte == 0x22 || byte == 0x5C || byte == 0x7F
        }
        guard bytes.contains(where: mustQuote) else { return bytes }
        var quoted: [UInt8] = [0x22]
        for byte in bytes {
            guard mustQuote(byte) else {
                quoted.append(byte)
                continue
            }
            quoted.append(0x5C)
            switch byte {
            case 0x07: quoted.append(UInt8(ascii: "a"))
            case 0x08: quoted.append(UInt8(ascii: "b"))
            case 0x09: quoted.append(UInt8(ascii: "t"))
            case 0x0A: quoted.append(UInt8(ascii: "n"))
            case 0x0B: quoted.append(UInt8(ascii: "v"))
            case 0x0C: quoted.append(UInt8(ascii: "f"))
            case 0x0D: quoted.append(UInt8(ascii: "r"))
            case 0x22, 0x5C: quoted.append(byte)
            default:
                quoted += [(byte >> 6) & 0o3, (byte >> 3) & 0o7, byte & 0o7].map { $0 + UInt8(ascii: "0") }
            }
        }
        quoted.append(0x22)
        return quoted
    }

    /// Replaces a file's sections with their first line and a marker. A file
    /// with two sections keeps only the first.
    mutating func leaveOut(file: Int, marker: String) {
        for (position, index) in (sectionsOfFile[file] ?? []).enumerated() {
            size -= sections[index].size
            sections[index].isLeftOut = true
            if position == 0 {
                sections[index].marker = Array(marker.utf8)
            } else {
                sections[index].header = []
                sections[index].marker = nil
            }
            size += sections[index].size
        }
    }

    /// Cuts every line of a hunk that's longer than `limit` characters, and
    /// says whether it cut any.
    mutating func cutLongLines(to limit: Int) -> Bool {
        var didCut = false
        for section in sections.indices where !sections[section].isLeftOut {
            for hunk in sections[section].hunks.indices {
                for index in sections[section].hunks[hunk].indices {
                    let line = sections[section].hunks[hunk][index]
                    // A character takes at least one byte, so a line with no
                    // more bytes than the limit is short enough.
                    guard line.count > limit, case .original(let range) = line else { continue }
                    let text = String(decoding: bytes[range], as: UTF8.self)
                    guard text.count > limit else { continue }
                    let cut = Line.written(Array((String(text.prefix(limit)) + " [rest of line cut]").utf8))
                    size -= sections[section].size
                    sections[section].replace(line: index, ofHunk: hunk, with: cut)
                    size += sections[section].size
                    didCut = true
                }
            }
        }
        return didCut
    }

    /// Drops the last kept hunk of the section with the most, again and again,
    /// until the patch fits in `budget` or every section is down to one hunk.
    /// Among sections with as many hunks, the longest goes first.
    ///
    /// Every section at the most hunks goes down by one before any goes lower,
    /// which is the same as always taking the section with the most. With the
    /// sections sorted by their hunks once, each round looks only at those
    /// that have reached it, so the work follows the hunks dropped rather than
    /// the rounds times the sections.
    mutating func dropHunks(toFit budget: Int) {
        guard size > budget else { return }
        let most = sections.indices
            .filter { !sections[$0].isLeftOut && sections[$0].keptHunks > 1 }
            .sorted { sections[$0].keptHunks > sections[$1].keptHunks || (sections[$0].keptHunks == sections[$1].keptHunks && $0 < $1) }
        guard let first = most.first else { return }
        var reached = 0
        for level in stride(from: sections[first].keptHunks, to: 1, by: -1) {
            while reached < most.count, sections[most[reached]].keptHunks >= level {
                reached += 1
            }
            let longestFirst = most[..<reached]
                .map { (index: $0, size: sections[$0].size) }
                .sorted { $0.size > $1.size || ($0.size == $1.size && $0.index < $1.index) }
            for (index, _) in longestFirst {
                size -= sections[index].size
                sections[index].dropLastHunk()
                size += sections[index].size
                if size <= budget { return }
            }
        }
    }

    /// How many hunks each file has left out, by the file's index.
    func hunksLeftOut() -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for section in sections where !section.isLeftOut {
            guard let file = section.file, section.keptHunks < section.hunks.count else { continue }
            counts[file, default: 0] += section.hunks.count - section.keptHunks
        }
        return counts
    }

    /// Leaves out whole files until the patch could fit in `budget` once
    /// every file is down to its first hunk, and returns them. The files that
    /// are longest even then go first, since they're the ones dropping hunks
    /// can't shrink.
    mutating func leaveOutLongestFiles(toFit budget: Int) -> [Int] {
        var smallest = smallestSize
        guard smallest > budget else { return [] }
        var sizes: [Int: Int] = [:]
        for section in sections where !section.isLeftOut {
            guard let file = section.file else { continue }
            sizes[file, default: 0] += section.smallestSize
        }
        var leftOut: [Int] = []
        for (file, before) in sizes.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }) {
            guard smallest > budget else { break }
            leaveOut(file: file, marker: "[too long, not shown]")
            smallest += (sectionsOfFile[file] ?? []).reduce(0) { $0 + sections[$1].smallestSize } - before
            leftOut.append(file)
        }
        return leftOut
    }

    /// The patch as text.
    var text: String {
        var output: [UInt8] = []
        output.reserveCapacity(size)
        func append(_ line: Line) {
            switch line {
            case .original(let range): output += bytes[range]
            case .written(let written): output += written
            }
            output.append(0x0A)
        }
        for section in sections {
            if section.isLeftOut {
                guard let first = section.header.first else { continue }
                append(first)
                if let marker = section.marker { append(.written(marker)) }
                continue
            }
            section.header.forEach(append)
            for hunk in section.hunks.prefix(section.keptHunks) {
                hunk.forEach(append)
            }
            if let marker = Self.hunkMarker(leavingOut: section.hunks.count - section.keptHunks) {
                append(.written(Array(marker.utf8)))
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}
