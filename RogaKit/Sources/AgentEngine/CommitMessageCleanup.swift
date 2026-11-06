/// Turns an agent's reply into a commit message (decision 41).
///
/// Models are asked for the message alone, but they still wrap it in code
/// fences or tags, announce it, label its parts, quote it, think out loud, or
/// sign it. Every Git client that asks a model for a message cleans up after
/// it in much the same way, and these are the rules they agree on. A reply is
/// never shortened, because the subject's character count already turns red
/// in the commit box, and lines that start with `#` stay, because
/// `git commit -F -` keeps them.
public enum CommitMessageCleanup {
    /// The cleaned message, or "" when nothing is left, which the writer
    /// treats as no reply.
    ///
    /// - Parameter draft: What was in the message box. A trailer such as
    ///   `Co-authored-by:` that the author wrote there is theirs, so it stays.
    public static func clean(_ reply: String, draft: String? = nil) -> String {
        var text = removingEscapes(reply)
        text = removingThinking(text)
        var lines = CommitMessageText.lines(text).map(CommitMessageText.trimmedAtEnd)
        lines = contentsOfLeadingFence(lines)
        lines = CommitMessageText.lines(unwrappingTags(lines.joined(separator: "\n")))
        lines = removingLeadIns(lines)
        lines = removingLabels(lines)
        lines = removingWrappingQuotes(lines)
        lines = removingAttribution(lines, draft: draft)
        return tidied(lines)
    }

    /// The message's first line, which is its subject.
    public static func subject(of message: String) -> String {
        CommitMessageText.lines(message).first.map(CommitMessageText.trimmed) ?? ""
    }

    // MARK: Terminal output

    /// Removes ANSI escape sequences, such as colors, and carriage returns.
    static func removingEscapes(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            switch scalar {
            case "\u{1B}":
                skipEscape(&iterator)
            case "\r":
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Skips the rest of an escape sequence: a control sequence such as
    /// `ESC [ 1 ; 31 m`, an operating system command such as a window title,
    /// which ends in BEL or `ESC \`, or a single character after the escape.
    private static func skipEscape(_ iterator: inout String.UnicodeScalarView.Iterator) {
        guard let kind = iterator.next() else { return }
        switch kind {
        case "[":
            while let scalar = iterator.next(), !(0x40...0x7E).contains(scalar.value) {}
        case "]":
            while let scalar = iterator.next() {
                if scalar == "\u{07}" { return }
                if scalar == "\u{1B}" {
                    _ = iterator.next()
                    return
                }
            }
        default:
            return
        }
    }

    // MARK: Thinking

    /// The ways models mark the start and end of their reasoning: `<think>`
    /// and `<thinking>` blocks, and Ollama's `Thinking...` to
    /// `...done thinking.`.
    private static let thinkingMarks = [("<think>", "</think>"), ("<thinking>", "</thinking>"), ("Thinking...", "...done thinking.")]

    /// Removes the reasoning that models print before their answer, one block
    /// after another. A block counts only at the start of the reply, after
    /// blank space, because a message can mention the tags, as one about this
    /// very cleanup would. A block that never ends takes the rest of the reply
    /// with it, because whatever follows is still reasoning.
    static func removingThinking(_ text: String) -> String {
        var rest = Substring(text)
        while true {
            let start = rest.drop(while: \.isWhitespace)
            guard let (open, close) = thinkingMarks.first(where: { start.hasPrefix($0.0) }) else { return String(rest) }
            let inside = start.dropFirst(open.count)
            guard let end = inside.firstRange(of: close) else { return "" }
            rest = inside[end.upperBound...]
        }
    }

    // MARK: Fences and tags

    /// The contents of the reply's first fenced block, when the reply starts
    /// with one, perhaps after a line that introduces it. A fence further
    /// down belongs to the message, such as an example in its body.
    static func contentsOfLeadingFence(_ lines: [String]) -> [String] {
        guard let open = lines.firstIndex(where: { isFence(CommitMessageText.trimmed($0)) }) else { return lines }
        let before = lines[..<open].filter { !CommitMessageText.trimmed($0).isEmpty }
        guard before.isEmpty || (before.count == 1 && isLeadIn(before[before.startIndex])) else { return lines }
        let fence = String(CommitMessageText.trimmed(lines[open]).prefix(3))
        let rest = lines[(open + 1)...]
        let close = rest.firstIndex { CommitMessageText.trimmed($0) == fence } ?? lines.endIndex
        return Array(lines[(open + 1)..<close])
    }

    private static func isFence(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    /// The message inside tags: GitLens's `<summary>` and `<body>`, whose
    /// closing tags may be missing, or one pair of tags around the whole
    /// reply, such as Roga's own `<draft-…>` or a `<commit-message>`. Tags
    /// count only at the start, since a subject can mention one.
    static func unwrappingTags(_ text: String) -> String {
        var text = CommitMessageText.trimmed(text)
        if text.hasPrefix("<summary>"), let summary = contents(of: "summary", in: text, until: "<body>") {
            let body = contents(of: "body", in: text, until: nil) ?? ""
            return body.isEmpty ? summary : summary + "\n\n" + body
        }
        // A tag inside a tag, such as a draft block around a message block.
        for _ in 0..<2 {
            guard text.hasPrefix("<"), let end = text.firstIndex(of: ">") else { break }
            let name = text[text.index(after: text.startIndex)..<end]
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { break }
            let closing = "</\(name)>"
            guard text.hasSuffix(closing) else { break }
            text = CommitMessageText.trimmed(text[text.index(after: end)..<text.index(text.endIndex, offsetBy: -closing.count)])
        }
        return text
    }

    /// What's between `<name>` and `</name>`, or up to `until` or the end when
    /// the closing tag is missing.
    private static func contents(of name: String, in text: String, until stop: String?) -> String? {
        guard let open = text.firstRange(of: "<\(name)>") else { return nil }
        let rest = text[open.upperBound...]
        let end = rest.firstRange(of: "</\(name)>")?.lowerBound
            ?? stop.flatMap { rest.firstRange(of: $0)?.lowerBound }
            ?? rest.endIndex
        return CommitMessageText.trimmed(rest[..<end])
    }

    // MARK: Lead-ins and labels

    /// Words that only agree to the request, as a line of their own.
    private static let affirmations: Set<String> = ["sure", "certainly", "of course", "okay", "ok", "absolutely", "here you go", "here it is"]

    /// Whether a line only introduces the message, such as "Here's the commit
    /// message:" or "Sure!". A line that ends in a colon counts only when it
    /// talks about the message, because a subject can end in one too, as in
    /// "Fix three bugs in the parser:".
    static func isLeadIn(_ line: String) -> Bool {
        var trimmed = CommitMessageText.trimmed(line).lowercased()
        while trimmed.hasPrefix("*") { trimmed.removeFirst() }
        while trimmed.hasSuffix("*") { trimmed.removeLast() }
        if trimmed.hasSuffix(":") {
            let words = ["commit message", "message", "here is", "here's", "here are", "sure", "certainly", "suggested commit", "proposed commit"]
            return words.contains { trimmed.contains($0) }
        }
        while let last = trimmed.last, "!.,".contains(last) { trimmed.removeLast() }
        return affirmations.contains(trimmed) || affirmations.contains { trimmed.hasPrefix($0 + ", here") }
    }

    /// Drops up to two lines at the start that only introduce the message,
    /// when something follows them.
    static func removingLeadIns(_ lines: [String]) -> [String] {
        var lines = Array(lines.drop { CommitMessageText.trimmed($0).isEmpty })
        for _ in 0..<2 {
            guard let first = lines.first, isLeadIn(first),
                  lines.dropFirst().contains(where: { !CommitMessageText.trimmed($0).isEmpty })
            else { break }
            lines = Array(lines.dropFirst().drop { CommitMessageText.trimmed($0).isEmpty })
        }
        return lines
    }

    private static let subjectLabels = ["subject", "title", "summary", "commit message", "commit"]
    private static let bodyLabels = ["body", "description"]

    /// Drops labels such as `Subject:` from the start of the subject and
    /// `Body:` from the start of the body, with or without bold around them.
    static func removingLabels(_ lines: [String]) -> [String] {
        var lines = lines
        guard let subject = lines.indices.first(where: { !CommitMessageText.trimmed(lines[$0]).isEmpty }) else { return lines }
        if let rest = afterLabel(lines[subject], labels: subjectLabels) {
            if rest.isEmpty {
                // The subject is on the next line.
                lines.remove(at: subject)
                return removingLabels(lines)
            }
            lines[subject] = rest
        }
        if let body = lines.indices.first(where: { $0 > subject && !CommitMessageText.trimmed(lines[$0]).isEmpty }),
           let rest = afterLabel(lines[body], labels: bodyLabels) {
            if rest.isEmpty {
                lines.remove(at: body)
            } else {
                lines[body] = rest
            }
        }
        return lines
    }

    /// The rest of a line after one of the labels and its colon, or nil when
    /// it doesn't start with one.
    private static func afterLabel(_ line: String, labels: [String]) -> String? {
        var rest = Substring(CommitMessageText.trimmed(line))
        let bold = rest.hasPrefix("**")
        if bold { rest = rest.dropFirst(2) }
        for label in labels where rest.lowercased().hasPrefix(label + ":") {
            var after = rest.dropFirst(label.count + 1)
            if bold, after.hasPrefix("**") { after = after.dropFirst(2) }
            return CommitMessageText.trimmed(after)
        }
        if bold {
            for label in labels where rest.lowercased().hasPrefix(label + "**:") || rest.lowercased().hasPrefix(label + ":**") {
                return CommitMessageText.trimmed(rest.dropFirst(label.count + 3))
            }
        }
        return nil
    }

    // MARK: Quotes

    /// Pairs that wrap a whole message or subject when a model quotes it.
    private static let quotePairs: [(String, String)] = [
        ("\"", "\""), ("'", "'"), ("`", "`"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"), ("**", "**"),
    ]

    /// Removes quotes, backticks or bold around the whole message or around
    /// its subject. They count only when they don't also appear inside, so
    /// `` `a` becomes `b` `` keeps its backticks.
    static func removingWrappingQuotes(_ lines: [String]) -> [String] {
        let whole = CommitMessageText.trimmed(lines.joined(separator: "\n"))
        if let inner = unwrapped(whole), inner.contains("\n") {
            return CommitMessageText.lines(inner)
        }
        var lines = lines
        if let subject = lines.indices.first(where: { !CommitMessageText.trimmed(lines[$0]).isEmpty }),
           let inner = unwrapped(CommitMessageText.trimmed(lines[subject])) {
            lines[subject] = inner
        }
        return lines
    }

    /// The text inside a pair of quotes around all of it, which is empty for a
    /// pair with nothing inside.
    private static func unwrapped(_ text: String) -> String? {
        for (open, close) in quotePairs where text.count >= open.count + close.count && text.hasPrefix(open) && text.hasSuffix(close) {
            let inner = text.dropFirst(open.count).dropLast(close.count)
            guard inner.firstRange(of: open) == nil, inner.firstRange(of: close) == nil else { continue }
            return CommitMessageText.trimmed(inner)
        }
        return nil
    }

    // MARK: Attribution

    /// Drops trailers and lines that credit an AI or sign off for someone,
    /// which the rules ask the agent not to write: `Co-authored-by:`,
    /// `Signed-off-by:`, and "Generated with" lines. A line that's also in the
    /// draft is the author's own and stays.
    static func removingAttribution(_ lines: [String], draft: String?) -> [String] {
        let drafted = Set((draft.map(CommitMessageText.lines) ?? []).map(CommitMessageText.trimmed).filter { !$0.isEmpty })
        return lines.filter { line in
            let trimmed = CommitMessageText.trimmed(line)
            return drafted.contains(trimmed) || !isAttribution(trimmed)
        }
    }

    private static let trailers = ["co-authored-by:", "signed-off-by:", "assisted-by:", "generated-by:"]
    private static let aiNames = ["claude", "codex", "anthropic", "openai", "chatgpt", "gpt", "copilot", "gemini", "ai", "llm"]

    static func isAttribution(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        if trailers.contains(where: lowercased.hasPrefix) { return true }
        if line.hasPrefix("\u{1F916}") { return true }
        for verb in ["generated", "created", "written", "authored"] {
            for preposition in ["with", "by", "using"] where lowercased.hasPrefix("\(verb) \(preposition) ") {
                let words = lowercased.split { !$0.isLetter && !$0.isNumber }
                return words.contains { aiNames.contains(String($0)) }
            }
        }
        return false
    }

    // MARK: Whitespace

    /// Trims each line's end, drops blank lines at the start and the end,
    /// leaves one blank line between paragraphs and exactly one after the
    /// subject, and takes a period off the end of the subject, though not an
    /// ellipsis.
    static func tidied(_ lines: [String]) -> String {
        var paragraphs: [[String]] = [[]]
        for line in lines.map(CommitMessageText.trimmedAtEnd) {
            if line.isEmpty {
                if !paragraphs[paragraphs.count - 1].isEmpty { paragraphs.append([]) }
            } else {
                paragraphs[paragraphs.count - 1].append(line)
            }
        }
        paragraphs.removeAll(where: \.isEmpty)
        guard !paragraphs.isEmpty else { return "" }

        // The subject is one line, so anything right under it starts the body.
        var subject = CommitMessageText.trimmed(paragraphs[0].removeFirst())
        if paragraphs[0].isEmpty { paragraphs.removeFirst() }
        if subject.hasSuffix("."), !subject.hasSuffix("..") { subject.removeLast() }
        subject = CommitMessageText.trimmed(subject)
        let body = paragraphs.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
        if subject.isEmpty { return body }
        return body.isEmpty ? subject : subject + "\n\n" + body
    }
}
