/// Everything an agent is told about a commit it's asked to write a message
/// for (decision 41).
public struct CommitMessageRequest: Sendable, Hashable {
    /// The worktree's folder, which the agent runs in.
    public var worktree: String
    /// The repository's name, or nil to leave it out.
    public var repository: String?
    /// The worktree's branch, which in an agent's worktree often says what the
    /// work is, or nil when it isn't on one.
    public var branch: String?
    public var changes: CommitMessageInput
    /// The latest subjects on the branch, newest first, so the agent can match
    /// the repository's style.
    public var recentSubjects: [String]
    /// What's in the message box already, which the agent completes or
    /// corrects rather than replaces, or nil when it's empty.
    public var draft: String?
    /// The instructions for the message's style, which someone can edit in
    /// Settings. `CommitMessagePrompt.defaultStyle` is Roga's.
    public var style: String

    public init(
        worktree: String,
        repository: String? = nil,
        branch: String? = nil,
        changes: CommitMessageInput,
        recentSubjects: [String] = [],
        draft: String? = nil,
        style: String = CommitMessagePrompt.defaultStyle
    ) {
        self.worktree = worktree
        self.repository = repository
        self.branch = branch
        self.changes = changes
        self.recentSubjects = recentSubjects
        self.draft = draft
        self.style = style
    }

    /// The draft without the blank lines and spaces around it, or nil when
    /// that leaves nothing.
    public var trimmedDraft: String? {
        guard let draft else { return nil }
        let trimmed = CommitMessageText.trimmed(draft)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What's staged, as the agent sees it. It's a copy of RepositoryEngine's
/// `StagedChanges`, which AgentEngine can't import, so RogaUI converts one
/// into the other.
public struct CommitMessageInput: Sendable, Hashable {
    public struct File: Sendable, Hashable {
        public var path: String
        /// Where a renamed file came from.
        public var oldPath: String?
        /// The letter git uses for the change, such as `M` or `R`.
        public var status: Character
        /// The lines added and removed, which are nil for a binary file.
        public var added: Int?
        public var deleted: Int?
        /// How much of the file the patch leaves out, such as
        /// "lockfile, not shown", or nil when it shows all of it.
        public var note: String?

        public init(path: String, oldPath: String? = nil, status: Character, added: Int? = nil, deleted: Int? = nil, note: String? = nil) {
            self.path = path
            self.oldPath = oldPath
            self.status = status
            self.added = added
            self.deleted = deleted
            self.note = note
        }
    }

    /// Every staged file, including the ones the patch leaves out.
    public var files: [File]
    /// The patch, with a marker in brackets where something was left out.
    public var patch: String
    /// Whether anything was left out for length.
    public var isCut: Bool

    public init(files: [File], patch: String, isCut: Bool = false) {
        self.files = files
        self.patch = patch
        self.isCut = isCut
    }
}

/// Small pieces of text handling that the commit message files share.
enum CommitMessageText {
    /// The text without spaces, tabs and line breaks at either end.
    static func trimmed(_ text: some StringProtocol) -> String {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }), let last = text.lastIndex(where: { !$0.isWhitespace }) else {
            return ""
        }
        return String(text[first...last])
    }

    /// The text without spaces and tabs at its end.
    static func trimmedAtEnd(_ text: some StringProtocol) -> String {
        guard let last = text.lastIndex(where: { $0 != " " && $0 != "\t" }) else { return "" }
        return String(text[...last])
    }

    /// The text's lines, without their line breaks. Swift counts `\r\n` as one
    /// character, so it's a line break of its own.
    static func lines(_ text: some StringProtocol) -> [String] {
        String(text).split(omittingEmptySubsequences: false) { (character: Character) in
            character == "\n" || character == "\r\n"
        }.map(String.init)
    }

    /// The first line that isn't blank, trimmed, or nil when there's none.
    static func firstLine(_ text: some StringProtocol) -> String? {
        lines(text).lazy.map(trimmed).first { !$0.isEmpty }
    }
}
