import Foundation
import Testing
@testable import AgentHooks

typealias Activity = HookHelper.Activity
typealias ToolInput = HookHelper.ToolInput

/// The event the helper makes of a payload, without a process.
private func parsed(_ json: String, host: AgentHost = .claude, isWhole: Bool = true) throws -> HookEvent? {
    let payload = HookHelper.Payload(HookHelper.Input(bytes: Array(json.utf8), isWhole: isWhole))
    let invocation = try #require(HookHelper.Invocation(["hook", "--host", host.rawValue]))
    return HookHelper.event(for: invocation, payload: payload, process: nil, time: 1)
}

/// Payloads from a headless Claude Code 2.1.318 session, with their folders
/// shortened: it ran two commands, kept a task list, read and edited a file,
/// and ran a subagent that read it too.
private enum Captured {
    static let common = #""session_id":"b9ee12d0-5069-4d23-907b-213078febbef","transcript_path":"/Users/me/.claude/projects/-Users-me-w/b9ee12d0.jsonl","cwd":"/Users/me/w","scratchpad_dir":"/private/tmp/claude-501/s/scratchpad","prompt_id":"cb80e835-7d18-429c-ba2a-4e41789ac2bd","permission_mode":"acceptEdits""#
    static let bash = #"{\#(common),"effort":{"level":"medium"},"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la","description":"List files in current directory"},"tool_use_id":"toolu_01WSQxUzcqJkT8NvANXowBXj"}"#
    static let taskUpdate = #"{\#(common),"effort":{"level":"medium"},"hook_event_name":"PreToolUse","tool_name":"TaskUpdate","tool_input":{"taskId":"2","status":"completed"},"tool_use_id":"toolu_013BqeEEHZxh1DcJ3LJwQjHj"}"#
    static let read = #"{\#(common),"effort":{"level":"medium"},"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/Users/me/w/notes.txt"},"tool_use_id":"toolu_01TXTcaQzqEcabQbB7xRbYPv"}"#
    static let edit = #"{\#(common),"effort":{"level":"medium"},"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/Users/me/w/notes.txt","old_string":"line two","new_string":"line 2","replace_all":false},"tool_use_id":"toolu_014WL6nFPRhSUHP7WCeEfp2P"}"#
    static let agent = #"{\#(common),"effort":{"level":"medium"},"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Report notes.txt first line","prompt":"Read the file /Users/me/w/notes.txt and report back its first line, exactly as written.","subagent_type":"general-purpose"},"tool_use_id":"toolu_01"}"#
    static let subagentRead = #"{\#(common),"agent_id":"adc3c68454bede724","agent_type":"general-purpose","effort":{"level":"medium"},"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/Users/me/w/notes.txt","limit":1},"tool_use_id":"toolu_01XGQ42h8GGCoQzT5ziwHuaW"}"#
    static let postRead = #"{\#(common),"effort":{"level":"medium"},"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/Users/me/w/notes.txt"},"tool_response":{"type":"text","file":{"filePath":"/Users/me/w/notes.txt","content":"line one\nline two\n"}},"tool_use_id":"toolu_01TXTcaQzqEcabQbB7xRbYPv","duration_ms":3}"#
    static let stop = #"{\#(common),"effort":{"level":"medium"},"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done\n\nThe steps ran out of order at the start. I ran `ls -la` and `date` before making the todo list.","background_tasks":[]}"#
    static let subagentStop = #"{\#(common),"agent_id":"adc3c68454bede724","agent_type":"general-purpose","hook_event_name":"SubagentStop","stop_hook_active":false,"agent_transcript_path":"/t/agent.jsonl","last_assistant_message":"line one"}"#
    static let prompt = #"{\#(common),"hook_event_name":"UserPromptSubmit","prompt":"Run ls -la and date, then keep a todo list"}"#
}

@Suite
struct HookActivityTests {
    // MARK: - From payloads

    @Test func makesALineFromClaudeCodesRealPayloads() throws {
        #expect(try parsed(Captured.bash)?.activity == "List files in current directory")
        #expect(try parsed(Captured.read)?.activity == "Reading notes.txt")
        #expect(try parsed(Captured.edit)?.activity == "Editing notes.txt")
        #expect(try parsed(Captured.agent)?.activity == "Subagent: Report notes.txt first line")
        #expect(try parsed(Captured.stop)?.activity == "done")
        // The task list's own tools have no line, and leave the one before.
        #expect(try parsed(Captured.taskUpdate)?.activity == nil)
        // A subagent's tools don't change its parent's line, so they send none.
        #expect(try parsed(Captured.subagentRead)?.activity == nil)
        #expect(try parsed(Captured.subagentStop)?.activity == nil)
        // A tool that has finished, and a prompt, send none either.
        #expect(try parsed(Captured.postRead)?.activity == nil)
        #expect(try parsed(Captured.prompt)?.activity == nil)
    }

    @Test func aCommandAskingToBeAllowedSaysWhatItWants() throws {
        let claude = try parsed(#"{"session_id":"s1","cwd":"/w","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push --force","description":"Force-push the branch"},"permission_suggestions":[]}"#)
        #expect(claude?.activity == "Force-push the branch")
        let codex = try parsed(#"{"session_id":"s2","turn_id":"t1","transcript_path":null,"cwd":"/w","hook_event_name":"PermissionRequest","model":"gpt-6-astra","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"cd /w && GIT_SSH_COMMAND='ssh -i key' git push origin main","description":"Push the branch"}}"#, host: .codex)
        #expect(codex?.activity == "git push")
    }

    // MARK: - Each tool

    @Test(arguments: [
        // Claude Code
        (AgentHost.claude, "Bash", ToolInput(description: "Run the test suite", command: .line("swift test")), "Run the test suite"),
        (.claude, "Bash", ToolInput(command: .line("swift test --filter HookActivityTests")), "swift test"),
        (.claude, "Read", ToolInput(filePath: "/Users/me/w/RogaKit/Sources/AgentHooks/HookHelper.swift"), "Reading HookHelper.swift"),
        (.claude, "Write", ToolInput(filePath: "/w/docs/notes.md"), "Editing notes.md"),
        (.claude, "MultiEdit", ToolInput(filePath: "/w/a.swift"), "Editing a.swift"),
        (.claude, "NotebookEdit", ToolInput(filePath: "/w/explore.ipynb"), "Editing explore.ipynb"),
        (.claude, "Edit", ToolInput(), "Editing a file"),
        (.claude, "Grep", ToolInput(), "Searching the code"),
        (.claude, "Glob", ToolInput(), "Searching the code"),
        (.claude, "Agent", ToolInput(description: "Find where hooks are parsed"), "Subagent: Find where hooks are parsed"),
        (.claude, "Task", ToolInput(description: "Find where hooks are parsed"), "Subagent: Find where hooks are parsed"),
        (.claude, "Agent", ToolInput(), "Running a subagent"),
        (.claude, "WebFetch", ToolInput(url: "https://www.swift.org/documentation/"), "Reading swift.org"),
        (.claude, "WebFetch", ToolInput(url: "not a url"), "Reading a web page"),
        (.claude, "WebSearch", ToolInput(), "Searching the web"),
        (.claude, "AskUserQuestion", ToolInput(), "Asked a question"),
        (.claude, "ExitPlanMode", ToolInput(), "Wants a plan approved"),
        (.claude, "mcp__github__create_issue", ToolInput(description: "A secret issue"), "Using github"),
        (.claude, "mcp__claude_ai_Gmail__search", ToolInput(), "Using claude_ai_Gmail"),
        (.claude, "Skill", ToolInput(), "Skill"),
        // Codex
        (.codex, "Bash", ToolInput(description: "Run the tests", command: .line("swift test")), "swift test"),
        (.codex, "exec_command", ToolInput(command: .words(["git", "push", "origin", "main"])), "git push"),
        (.codex, "exec_command", ToolInput(command: .words(["bash", "-lc", "cd RogaKit && swift test"])), "swift test"),
        (.codex, "exec_command", ToolInput(command: .words(["/bin/zsh", "-o", "pipefail", "-c", "git status | head"])), "git status"),
        (.codex, "shell", ToolInput(command: .words(["rg", "--files"])), "rg"),
        (.codex, "Bash", ToolInput(), "Running a command"),
        (.codex, "apply_patch", ToolInput(command: .line("*** Begin Patch\n*** Update File: RogaKit/Sources/AgentHooks/HookHelper.swift\n@@\n-old\n+new\n*** End Patch")), "Editing HookHelper.swift"),
        (.codex, "apply_patch", ToolInput(command: .line("*** Begin Patch\n*** Add File: a/new.swift\n+x\n*** Update File: b/old.swift\n*** Delete File: c/gone.swift\n*** End Patch")), "Editing new.swift and 2 other files"),
        (.codex, "apply_patch", ToolInput(command: .line("*** Begin Patch\n*** Update File: a.swift\n*** Update File: b.swift\n*** End Patch")), "Editing a.swift and 1 other file"),
        (.codex, "apply_patch", ToolInput(command: .line("garbage")), "Editing files"),
        (.codex, "spawn_agent", ToolInput(description: "Check the docs"), "Subagent: Check the docs"),
        (.codex, "request_user_input", ToolInput(), "Asked a question"),
        (.codex, "mcp__linear__get_issue", ToolInput(), "Using linear"),
        // Task is Claude's old name for subagents, and nothing in particular to Codex.
        (.codex, "Task", ToolInput(description: "Something"), "Task"),
    ])
    func makesALineForEachTool(host: AgentHost, tool: String, input: ToolInput, line: String) {
        #expect(Activity.line(host: host, tool: tool, input: input) == line)
    }

    @Test(arguments: ["TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TodoWrite", "ToolSearch", "update_plan"])
    func toolsThatKeepTheTaskListHaveNoLine(tool: String) {
        #expect(Activity.line(host: .claude, tool: tool, input: ToolInput(description: "Plan")) == nil)
        #expect(Activity.line(host: .codex, tool: tool, input: ToolInput()) == nil)
    }

    // MARK: - Commands

    @Test(arguments: [
        ("git push", "git push"),
        ("swift test --package-path RogaKit", "swift test"),
        ("cd /Users/me/w && swift test", "swift test"),
        ("cd /w; export PATH=/opt/bin:$PATH; npm run build", "npm run"),
        ("source .venv/bin/activate && pytest -q", "pytest"),
        ("GIT_TRACE=1 FOO='a b' git fetch --all", "git fetch"),
        ("env -u X make", "env"),
        ("env CI=1 uv run pytest", "uv run"),
        ("time swift build", "swift build"),
        ("git -C /Users/me/w --no-pager log --oneline", "git log"),
        ("git -c user.name=x commit -m 'Fix it'", "git commit"),
        ("/usr/bin/git status", "git status"),
        ("./scripts/release.sh 0.2.0", "release.sh"),
        ("bash -lc \"cd app && make test\"", "make test"),
        ("sh -c 'ls -la'", "ls"),
        ("bash scripts/check.sh", "bash"),
        ("cat notes.txt | head -5", "cat notes.txt"),
        ("swift test 2>&1 | tail -20", "swift test"),
        ("ls &> /dev/null && echo ok", "ls"),
        ("# just a comment\ngit status", "git status"),
        ("git \\\n  status", "git status"),
        ("cd /w", "cd"),
        ("cd w", "cd w"),
        // An option's value, a URL or anything with capitals or symbols in
        // it is never sent, since it can hold a token.
        ("curl -u me:hunter2 https://api.example.com", "curl"),
        ("curl https://api.example.com/?token=abc123", "curl"),
        ("echo $GITHUB_TOKEN", "echo"),
        ("export TOKEN=ghp_abcdef && gh pr create", "gh pr"),
        ("TOKEN=ghp_abcdef gh auth status", "gh auth"),
        ("mysql Hunter2Secret", "mysql"),
        ("deploy averyveryverylongsecretvalue1234567890", "deploy"),
        ("sleep 30", "sleep"),
    ])
    func findsTheProgramInAShellLine(command: String, program: String) {
        #expect(Activity.command(.line(command)) == program)
    }

    @Test func aCommandWithNoProgramSaysItRunsOne() {
        #expect(Activity.command(.line("$(which git) push")) == "Running a command")
        #expect(Activity.command(.line("   ")) == "Running a command")
        #expect(Activity.command(.words([])) == "Running a command")
        #expect(Activity.command(nil) == "Running a command")
    }

    @Test func splitsALineOfShellIntoCommands() {
        #expect(Activity.words(of: #"cd "my folder" && echo 'a  b' "c\"d" e\ f; ls"#) == [
            ["cd", "my folder"], ["echo", "a  b", #"c"d"#, "e f"], ["ls"],
        ])
        #expect(Activity.words(of: "a || b | c & d (e)") == [["a"], ["b"], ["c"], ["d"], ["e"]])
        #expect(Activity.words(of: "make 2>&1 >&2 &>log") == [["make", "2>&1", ">&2", "&>log"]])
        #expect(Activity.words(of: "echo 'unclosed") == [["echo", "unclosed"]])
        #expect(Activity.words(of: "x=\"\" y") == [["x=", "y"]])
    }

    @Test func looksAtOnlyTheStartOfAHugeCommand() {
        let heredoc = "cat > big.txt <<'EOF'\n" + String(repeating: "secret line\n", count: 100_000) + "EOF"
        #expect(Activity.command(.line(heredoc)) == "cat")
    }

    // MARK: - Replies

    @Test(arguments: [
        ("Added the activity line to the tooltip.", "Added the activity line to the tooltip."),
        ("\n\n  ## Added the **activity line** to the tooltip\n\nMore.", "Added the activity line to the tooltip"),
        ("> Quoted *emphasis* and _more_ here", "Quoted emphasis and more here"),
        ("- [x] Ran `swift test`, which passed", "Ran swift test, which passed"),
        ("1. First step", "First step"),
        ("See [the issue](https://github.com/x/y/issues/27) and ![logo](a.png)", "See the issue and logo"),
        ("Kept `snake_case_names` and 2 * 3 as they are", "Kept snake_case_names and 2 * 3 as they are"),
        ("<b>Bold</b> and <https://roga.sh>", "Bold and https://roga.sh"),
        ("---\n***\n| --- | --- |\n\nDone.", "Done."),
        ("```swift\nlet secret = 1\n```\nThe code above works.", "The code above works."),
        ("🎉\n\nAll tests pass", "All tests pass"),
    ])
    func takesTheFirstLineOfAReplyWithoutItsMarkdown(reply: String, line: String) {
        #expect(Activity.firstLine(ofReply: reply) == line)
    }

    @Test func aReplyWithNoWordsHasNoLine() {
        #expect(Activity.firstLine(ofReply: "") == nil)
        #expect(Activity.firstLine(ofReply: "\n  \n---\n") == nil)
        #expect(Activity.firstLine(ofReply: "```\nonly code\n```") == nil)
    }

    @Test func aLongReplyIsCutAtAWord() throws {
        let reply = "The subagent finished. It reports the first line of notes.txt as \"line one\", which matches what I read earlier. All seven steps are now complete."
        let line = try #require(Activity.firstLine(ofReply: reply))
        #expect(line == "The subagent finished. It reports the first line of notes.txt as \"line one\", which matches what I read earlier. All…")
        #expect(line.count <= Activity.characterLimit)
    }

    // MARK: - Shortening

    @Test func shortensToOneLine() throws {
        #expect(Activity.shortened("  Run\tthe\n\ntests \u{1B}[0m now ") == "Run the tests [0m now")
        #expect(Activity.shortened(" \n\t") == nil)
        #expect(Activity.shortened(nil) == nil)
        let exact = String(repeating: "a", count: Activity.characterLimit)
        #expect(Activity.shortened(exact) == exact)
        let word = String(repeating: "a", count: 200)
        #expect(Activity.shortened(word) == String(repeating: "a", count: Activity.characterLimit - 1) + "…")
        // Lots of space before a short ending still says it was cut.
        let spaced = "Start" + String(repeating: " ", count: 1000) + "end"
        #expect(Activity.shortened(spaced) == "Start…")
    }

    @Test func keepsALineToItsBytesToo() throws {
        let family = "👩‍👩‍👧‍👦"
        let line = try #require(Activity.shortened(String(repeating: family, count: 500)))
        #expect(line.utf8.count <= Activity.byteLimit)
        #expect(line.hasSuffix("…"))
        // One character can hold any number of combining marks.
        let piled = "a" + String(repeating: "\u{301}", count: 5000)
        #expect(try #require(Activity.shortened(piled)).utf8.count <= Activity.byteLimit)
    }

    // MARK: - Payloads too big to read

    @Test func aFileTooBigToReadStillSaysWhichFile() throws {
        let content = String(repeating: "x", count: 200_000)
        let json = #"{"session_id":"s1","cwd":"/w","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/w/big.txt","content":""# + content + #""}}"#
        let event = try #require(try parsed(String(json.prefix(100_000)), isWhole: false))
        #expect(event.event == "PreToolUse")
        #expect(event.activity == "Editing big.txt")
    }

    @Test func aPayloadTooBigToReadGivesWhatComesEarly() throws {
        // Claude writes a command before its description.
        let command = String(repeating: "echo x; ", count: 20_000)
        let bash = #"{"session_id":"s1","cwd":"/w","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":""# + command + #"","description":"Print many lines"}}"#
        #expect(try parsed(String(bash.prefix(300_000)), isWhole: false)?.activity == "Running a command")
        let agent = #"{"session_id":"s1","cwd":"/w","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"Read everything","prompt":""# + command + #""}}"#
        #expect(try parsed(String(agent.prefix(300_000)), isWhole: false)?.activity == "Subagent: Read everything")
        // A reply that doesn't end within the part that's looked at has no line.
        let stop = #"{"session_id":"s1","cwd":"/w","hook_event_name":"Stop","last_assistant_message":"Done.\n"# + command + #""}"#
        let stopped = try #require(try parsed(String(stop.prefix(300_000)), isWhole: false))
        #expect(stopped.event == "Stop")
        #expect(stopped.activity == nil)
        let short = #"{"session_id":"s1","cwd":"/w","hook_event_name":"Stop","last_assistant_message":"**Done.**\nMore","background_tasks":[1"#
        #expect(try parsed(short, isWhole: false)?.activity == "Done.")
    }
}
