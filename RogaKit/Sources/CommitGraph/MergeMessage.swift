/// What a commit's message says about the branch it brought in, since git
/// doesn't record which branch a commit was made on. The forges each write
/// their own:
///
/// - GitHub: `Merge pull request #52 from owner/branch`, with the pull
///   request's title in the body. It can also be set to use the title as the
///   subject, followed by the number in parentheses, which is what a squashed
///   pull request looks like too.
/// - GitLab, and git itself: `Merge branch 'x' into 'main'`
/// - Bitbucket: `Merged in x (pull request #12)`
///
/// These are plain scans rather than regular expressions, because a replay
/// reads the message of every commit in its range.
struct MergeMessage: Hashable, Sendable {
    /// The branch's name, or nil when the message doesn't name one.
    var name: String?
    var pullRequest: Int?
    var title: String?

    init(subject: String, body: String) {
        var rest = subject[...]
        if rest.skip("Merge pull request #"), let number = rest.takeNumber(), rest.skip(" from ") {
            let owner = rest.take { $0 != "/" && !$0.isWhitespace }
            let hasSlash = rest.skip("/")
            let branch = rest.take { !$0.isWhitespace }
            if !owner.isEmpty, hasSlash, !branch.isEmpty {
                name = String(branch)
                pullRequest = number
                title = body.isEmpty ? nil : body
                return
            }
        }

        rest = subject[...]
        if rest.skip("Merged in ") {
            let branch = rest.take { !$0.isWhitespace }
            if !branch.isEmpty {
                name = String(branch)
                if rest.skip(" (pull request #"), let number = rest.takeNumber(), rest.skip(")") {
                    pullRequest = number
                }
                return
            }
        }

        if let branch = Self.namedBranch(in: subject) {
            name = branch
            return
        }

        if let squash = Self.squash(in: subject) {
            pullRequest = squash.number
            title = String(squash.title)
        }
    }

    /// The branch named by a message such as `Merge branch 'x'` or
    /// `Merge remote-tracking branch 'origin/x'`, without the `origin/`.
    static func namedBranch(in subject: String) -> String? {
        var rest = subject[...]
        guard rest.skip("Merge ") else { return nil }
        _ = rest.skip("remote-tracking ")
        guard rest.skip("branch '") else { return nil }
        let branch = rest.take { $0 != "'" }
        guard !branch.isEmpty, rest.skip("'") else { return nil }
        return withoutOrigin(branch)
    }

    /// The name of a branch as a merge's message would give it.
    static func withoutOrigin(_ name: some StringProtocol) -> String {
        name.hasPrefix("origin/") ? String(name.dropFirst("origin/".count)) : String(name)
    }

    /// Whether a commit is how a pull request landed: a merge of one, or a
    /// squash of one.
    static func landsPullRequest(_ subject: String) -> Bool {
        if subject.hasSuffix(")"), squash(in: subject) != nil { return true }
        var rest = subject[...]
        return rest.skip("Merge pull request #") && rest.first?.isDigit == true
    }

    /// The title and number of a subject that ends with ` (#12)`.
    static func squash(in subject: String) -> (title: Substring, number: Int)? {
        guard subject.hasSuffix(")"), let open = subject.lastIndex(of: "(") else { return nil }
        var rest = subject[open...]
        guard rest.skip("(#"), let number = rest.takeNumber(), rest == ")" else { return nil }
        let before = subject[..<open]
        return (before.hasSuffix(" ") ? before.dropLast() : before, number)
    }
}

private extension Character {
    var isDigit: Bool { isASCII && isNumber }
}

private extension Substring {
    /// Removes `prefix` from the front, and returns whether it was there.
    mutating func skip(_ prefix: String) -> Bool {
        guard hasPrefix(prefix) else { return false }
        removeFirst(prefix.count)
        return true
    }

    /// Removes the characters at the front that match, and returns them.
    mutating func take(while matches: (Character) -> Bool) -> Substring {
        let taken = prefix(while: matches)
        removeFirst(taken.count)
        return taken
    }

    /// Removes the digits at the front, and returns their value.
    mutating func takeNumber() -> Int? {
        let digits = take(while: \.isDigit)
        return Int(digits)
    }
}
