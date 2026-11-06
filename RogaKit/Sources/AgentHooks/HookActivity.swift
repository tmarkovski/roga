import Foundation

extension HookHelper {
    /// The parts of a tool's input that its line is made from. The rest of
    /// the input, and all of the tool's output, is never read.
    struct ToolInput: Hashable {
        /// The line Claude Code writes for people about a command or a
        /// subagent, as in "Run the test suite".
        var description: String?
        /// The file a tool reads or edits.
        var filePath: String?
        /// The page a tool fetches.
        var url: String?
        /// A shell's command, or the whole of a patch for `apply_patch`.
        var command: Command?

        /// Codex sends a command as one string or as a list of words.
        enum Command: Hashable {
            case line(String)
            case words([String])
        }

        init(description: String? = nil, filePath: String? = nil, url: String? = nil, command: Command? = nil) {
            self.description = description
            self.filePath = filePath
            self.url = url
            self.command = command
        }

        init(_ input: [String: Any]) {
            let command: Command? =
                if let line = (input["command"] ?? input["cmd"]) as? String {
                    .line(line)
                } else if let words = (input["command"] ?? input["cmd"]) as? [Any] {
                    .words(words.compactMap { $0 as? String })
                } else {
                    nil
                }
            self.init(
                description: input["description"] as? String,
                filePath: (input["file_path"] ?? input["notebook_path"]) as? String,
                url: input["url"] as? String,
                command: command
            )
        }

        /// The same fields, found by name in the first part of a payload the
        /// helper couldn't read as JSON. The hook's own fields come first and
        /// the tool's output last, so the first field of each name is the
        /// tool's input. A command that's a list of words can't be found this
        /// way, and neither can a field cut off by the end of the part.
        init(scanning bytes: ArraySlice<UInt8>) {
            func text(_ key: String) -> String? {
                Payload.firstString(named: key, in: bytes)
            }
            self.init(
                description: text("description"),
                filePath: text("file_path") ?? text("notebook_path"),
                url: text("url"),
                command: text("command").map(Command.line)
            )
        }
    }

    /// The short line that says what an agent is doing (decision 43), made
    /// here so that a prompt, a tool's input or its output never leaves the
    /// helper: only the line does.
    enum Activity {
        /// The longest line, in characters, so that one fits in a tooltip and
        /// an event stays well inside the socket's 8 KB buffer.
        static let characterLimit = 120
        /// The most bytes a line takes, for characters made of many parts.
        static let byteLimit = 480
        /// How much of a command is looked at for its program.
        static let commandLimit = 4096
        /// How much of a reply is looked at for its first line.
        static let replyLimit = 64 * 1024

        // MARK: Tools

        /// The line for a tool that's starting or asks to be allowed, or nil
        /// for the tools that only keep the agent's task list, which leave
        /// the line as it was.
        static func line(host: AgentHost, tool: String, input: ToolInput) -> String? {
            if let server = mcpServer(of: tool) {
                return shortened("Using \(server)")
            }
            switch tool {
            case "Bash" where host == .claude:
                return shortened(input.description) ?? command(input.command)
            case "Bash", "exec_command", "shell", "local_shell":
                return command(input.command)
            case "Read", "NotebookRead":
                return file("Reading", input.filePath)
            case "Edit", "MultiEdit", "Write", "NotebookEdit":
                return file("Editing", input.filePath)
            case "apply_patch":
                return patch(input.command)
            case "Grep", "Glob":
                return "Searching the code"
            case "Agent", "spawn_agent":
                return subagent(input.description)
            case "Task" where host == .claude:
                // What Claude Code called its Agent tool before 2.1.
                return subagent(input.description)
            case "WebFetch":
                return website(input.url).map { "Reading \($0)" } ?? "Reading a web page"
            case "WebSearch", "web_search":
                return "Searching the web"
            case "AskUserQuestion", "request_user_input":
                return "Asked a question"
            case "ExitPlanMode":
                return "Wants a plan approved"
            case "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TodoWrite", "TodoRead", "ToolSearch", "update_plan":
                return nil
            default:
                return shortened(tool)
            }
        }

        /// The server's name in an MCP tool's, as `github` in
        /// `mcp__github__create_issue`.
        static func mcpServer(of tool: String) -> String? {
            guard tool.hasPrefix("mcp__") else { return nil }
            let rest = tool.dropFirst(5)
            let server = rest.range(of: "__").map { rest[..<$0.lowerBound] } ?? rest
            return server.isEmpty ? nil : String(server)
        }

        private static func file(_ verb: String, _ path: String?) -> String {
            guard let name = path?.split(separator: "/").last, let line = shortened("\(verb) \(name)") else {
                return "\(verb) a file"
            }
            return line
        }

        private static func subagent(_ description: String?) -> String {
            shortened(description.map { "Subagent: \($0)" }) ?? "Running a subagent"
        }

        /// The site's name, without `www.`.
        private static func website(_ url: String?) -> String? {
            guard let url, let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
            return shortened(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        }

        /// "Editing" and the patch's file, or how many others it changes too.
        /// A patch names each file on a line such as `*** Update File: <path>`.
        private static func patch(_ command: ToolInput.Command?) -> String {
            let text = switch command {
            case .line(let line): line
            case .words(let words): words.joined(separator: "\n")
            case nil: ""
            }
            var names: [Substring] = []
            for line in text.split(whereSeparator: \.isNewline) {
                for header in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(header) {
                    if let name = line.dropFirst(header.count).split(separator: "/").last, !names.contains(name) {
                        names.append(name)
                    }
                }
            }
            guard let first = names.first, let line = shortened("Editing \(first)") else { return "Editing files" }
            switch names.count {
            case 1: return line
            case 2: return shortened("Editing \(first) and 1 other file") ?? line
            default: return shortened("Editing \(first) and \(names.count - 1) other files") ?? line
            }
        }

        // MARK: Commands

        /// A command's program and the word after it, as in "git push" or
        /// "swift test", or "Running a command" when no program can be told.
        static func command(_ command: ToolInput.Command?) -> String {
            let program: String? = switch command {
            case .line(let line): program(ofLine: line)
            case .words(let words): program(ofWords: words)
            case nil: nil
            }
            return program ?? "Running a command"
        }

        /// The program in a line of shell: the first command that isn't
        /// setting up the shell, such as `cd … &&` or `export …;`.
        static func program(ofLine line: String, depth: Int = 0) -> String? {
            let segments = words(of: line.prefix(commandLimit))
            let chosen = segments.first { !isSetup($0) } ?? segments.first
            return chosen.flatMap { program(ofWords: $0, depth: depth) }
        }

        /// The program in one simple command, after any `VAR=value` before it.
        /// A shell with `-c` is looked through to the command it runs.
        ///
        /// Only the word right after the program is kept, and only when it
        /// looks like a subcommand, because an option's value can be a token
        /// or a password, as in `curl -u name:secret`. Git's own options
        /// before its subcommand are the one exception, since `git -C <path>`
        /// is common and its options are known.
        static func program(ofWords words: [String], depth: Int = 0) -> String? {
            var rest = words.drop { isAssignment($0) }
            // These run the command after them, unless an option comes first.
            while let first = rest.first, ["env", "time", "nohup"].contains(first) {
                let after = rest.dropFirst().drop { isAssignment($0) }
                guard let next = after.first, !next.hasPrefix("-") else { break }
                rest = after
            }
            guard let first = rest.first, let name = programName(first) else { return nil }
            rest = rest.dropFirst()
            if shells.contains(name), depth < 3 {
                var options = rest
                while let option = options.first, option.hasPrefix("-"), option != "-", option != "--" {
                    options = options.dropFirst()
                    if option == "-o" || option == "+o" {
                        options = options.dropFirst()
                    } else if !option.hasPrefix("--"), option.contains("c"), let script = options.first {
                        return program(ofLine: script, depth: depth + 1)
                    }
                }
            }
            if name == "git" {
                while let option = rest.first, option.hasPrefix("-") {
                    rest = rest.dropFirst(option == "-C" || option == "-c" ? 2 : 1)
                }
            }
            guard let next = rest.first, isSubcommand(next) else { return name }
            return "\(name) \(next)"
        }

        private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

        /// Commands that only set up the shell for the one that does the work.
        private static let setup: Set<String> = ["cd", "pushd", "popd", "export", "set", "unset", "source", ".", "ulimit", "umask"]

        private static func isSetup(_ words: [String]) -> Bool {
            guard let first = words.first(where: { !isAssignment($0) }) else { return true }
            return setup.contains(first)
        }

        /// Whether a word is `NAME=value`, which sets a variable for the
        /// command after it.
        private static func isAssignment(_ word: String) -> Bool {
            guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
            let name = word[..<equals]
            return name.first.map { $0 == "_" || $0.isASCII && $0.isLetter } == true
                && name.allSatisfy { $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) }
        }

        /// A program's name without its folder, or nil when the word isn't
        /// one, as with `$(which git)`.
        private static func programName(_ word: String) -> String? {
            guard let name = word.split(separator: "/").last, name.count <= 40, !name.hasPrefix("-"),
                name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) })
            else { return nil }
            return String(name)
        }

        /// Whether a word looks like a subcommand, as `push` or `test`, or a
        /// file's name, rather than a value: lowercase letters and digits,
        /// with dots and dashes, and short.
        private static func isSubcommand(_ word: String) -> Bool {
            guard let first = word.first, first.isASCII, first.isLowercase, word.count <= 24 else { return false }
            return word.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") }
        }

        /// The words of a line of shell, as a list of simple commands: split
        /// where `&&`, `||`, `|`, `;`, `&`, a parenthesis or a new line comes
        /// between them, with quotes and backslashes taken off. A comment
        /// ends at the end of its line.
        static func words(of line: Substring) -> [[String]] {
            var segments: [[String]] = []
            var segment: [String] = []
            var word = ""
            var inWord = false
            var quote: Character?
            var characters = line.makeIterator()
            var pending: Character?

            func endWord() {
                if inWord { segment.append(word) }
                word = ""
                inWord = false
            }
            func endSegment() {
                endWord()
                if !segment.isEmpty { segments.append(segment) }
                segment = []
            }
            func next() -> Character? {
                if let character = pending {
                    pending = nil
                    return character
                }
                return characters.next()
            }

            while let character = next() {
                if let open = quote {
                    if character == open {
                        quote = nil
                    } else if open == "\"", character == "\\", let escaped = next() {
                        if !"\"\\$`".contains(escaped) { word.append("\\") }
                        word.append(escaped)
                    } else {
                        word.append(character)
                    }
                    continue
                }
                switch character {
                case "'", "\"":
                    quote = character
                    inWord = true
                case "\\":
                    // A backslash before a new line joins the two lines.
                    if let escaped = next(), !escaped.isNewline {
                        word.append(escaped)
                        inWord = true
                    }
                case " ", "\t":
                    endWord()
                case _ where character.isNewline:
                    endSegment()
                case ";", "|", "(", ")":
                    endSegment()
                case "&":
                    // `2>&1` and `&>` are redirections, not the end of a command.
                    let following = next()
                    if word.hasSuffix(">") || word.hasSuffix("<") || following == ">" {
                        word.append(character)
                        inWord = true
                    } else {
                        endSegment()
                    }
                    if let following, following != "&" { pending = following }
                case "#" where !inWord:
                    while let skipped = next(), !skipped.isNewline {}
                    endSegment()
                default:
                    word.append(character)
                    inWord = true
                }
            }
            endSegment()
            return segments
        }

        // MARK: Replies

        /// The first line of an agent's reply that has words in it, with its
        /// Markdown taken off, as "Added the activity line to the tooltip"
        /// from `## Added the **activity line** to the tooltip`. Code blocks
        /// are skipped.
        static func firstLine(ofReply reply: String) -> String? {
            var inCode = false
            for line in reply.prefix(replyLimit).split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    inCode.toggle()
                    continue
                }
                guard !inCode else { continue }
                let plain = withoutMarkdown(trimmed)
                if plain.contains(where: { $0.isLetter || $0.isNumber }) {
                    return shortened(plain)
                }
            }
            return nil
        }

        /// One line of Markdown as plain text: without the marks of a quote,
        /// a heading or a list item, with links as their text, and without
        /// emphasis, code marks or HTML tags.
        static func withoutMarkdown(_ line: String) -> String {
            var text = line
            for (pattern, template) in markdown {
                text = pattern.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
                )
            }
            return text
        }

        private static let markdown: [(NSRegularExpression, String)] = [
            // Quotes, headings, list items and task boxes, at the start.
            (#"^(?:\s*>)+\s*"#, ""),
            (#"^#{1,6}\s+"#, ""),
            (#"^(?:[-*+]|\d{1,9}[.)])\s+(?:\[[ xX]\]\s+)?"#, ""),
            // Images and links become their text.
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\[[^\]]*\]"#, "$1"),
            (#"<(https?://[^>\s]+)>"#, "$1"),
            (#"</?[A-Za-z][^>]*>"#, ""),
            // Emphasis and code marks, but not the underscores inside a name.
            (#"\*\*|__|~~|`"#, ""),
            (#"(?<![\w*])[*_]+(?=\S)|(?<=\S)[*_]+(?![\w*])"#, ""),
        ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

        // MARK: Shortening

        /// Text as one line of at most `characterLimit` characters and
        /// `byteLimit` bytes, cut at a word where it can be and ended with an
        /// ellipsis, or nil when there's nothing in it.
        static func shortened(_ text: String?) -> String? {
            guard let text else { return nil }
            // A little more than fits, so that a long text costs no more.
            let considered = text.prefix(characterLimit * 4)
            let isCut = considered.endIndex != text.endIndex
            var line = considered.split { $0.isWhitespace || isControl($0) }.joined(separator: " ")
            guard !line.isEmpty else { return nil }
            if line.count > characterLimit || isCut {
                var cut = line.prefix(characterLimit - 1)
                if line.count >= characterLimit, let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) <= 20 {
                    cut = cut[..<space]
                }
                while let last = cut.last, last.isWhitespace || ",;:.-–—(".contains(last) {
                    cut.removeLast()
                }
                line = cut + "…"
            }
            if line.utf8.count > byteLimit {
                var scalars = String.UnicodeScalarView()
                var bytes = 0
                for scalar in line.unicodeScalars {
                    bytes += String(scalar).utf8.count
                    if bytes > byteLimit - "…".utf8.count { break }
                    scalars.append(scalar)
                }
                line = String(scalars) + "…"
            }
            return line
        }

        private static func isControl(_ character: Character) -> Bool {
            character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
    }
}
