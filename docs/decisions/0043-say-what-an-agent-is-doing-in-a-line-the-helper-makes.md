# 43. Say what an agent is doing, in a line the helper makes

Accepted on 2026-11-06. Partly supersedes [decision 41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md): its helper "never forwards a prompt or a tool's input", and now it forwards a short line about what the agent is doing, made from a tool's input or from the agent's reply. The marks' tooltip and the worktree menu's line say it. The rest of decision 41 still holds. This is the first step that [issue 27](https://github.com/tmarkovski/yaga/issues/27) proposes.

## Context

The marks said that an agent was working, waiting or finished, but never what it was doing. Someone with agents in three worktrees had to go to each terminal to see which one was running the tests and which one wanted to push. The hooks already say. Claude Code's `Bash` comes with a line that Claude writes for people, as in "Run the test suite", the file tools name their file, a subagent comes with a description, and `Stop` carries the agent's whole reply. Issue 27 lists what each agent's events carry, from a capture of every event of a Claude Code 2.1.318 session and from the schemas that Codex generates for its hooks.

Decision 41 kept all of that inside the helper, for two reasons. A tool's input can hold anything, such as a whole file being written or a token in a command. And an event has to fit in the socket's 8 KB buffer at once, so that the agent never waits on Roga.

## Decision

**The helper makes one short line from an event, and sends only that,** as the event's `activity`. It's made where the input already is, on the Mac, and goes only to Roga's socket, like the rest of the event. The prompt the person typed and the output of every tool are still never read.

| Tool | Line |
| --- | --- |
| Claude Code's `Bash` | the `description` Claude wrote for it, as "Run the test suite", or the program when there's none |
| Codex's `Bash`, `exec_command` and `shell` | the program and the word after it, as "git push" or "swift test" |
| `Read` | "Reading" and the file's name, without its folder |
| `Edit`, `MultiEdit`, `Write`, `NotebookEdit`, and Codex's `apply_patch` | "Editing" and the file's name, and for a patch of several files how many others, as "Editing HookHelper.swift and 2 other files" |
| `Grep`, `Glob` | "Searching the code" |
| `Agent`, and Codex's `spawn_agent` | "Subagent: " and its description |
| `WebFetch` / `WebSearch` | "Reading" and the site's name / "Searching the web" |
| MCP tools, named `mcp__<server>__<tool>` | "Using" and the server's name |
| `AskUserQuestion` and Codex's `request_user_input` / `ExitPlanMode` | "Asked a question" / "Wants a plan approved" |
| `TaskCreate`, `TaskUpdate`, `TaskGet`, `TaskList`, `TodoWrite`, `ToolSearch`, and Codex's `update_plan` | no line, so the one before stays |
| Anything else | the tool's name |

The tools with no line only keep the agent's task list or load its other tools. In the captured session they were 16 of its 22 tool calls, and each would have replaced what the agent was doing with something it does between steps.

A line comes with `PreToolUse` and `PermissionRequest`, so it's made before the tool runs, and never from the `PostToolUse` that carries the tool's output. `Stop` comes with the first line of `last_assistant_message` that has a letter or a digit in it, with code blocks skipped and the Markdown taken off: the marks of quotes, headings and list items, links as their text, emphasis, code marks and HTML tags. A subagent's events come with no line.

**A command is cut down to its program, and never sent whole,** because a command can hold a token, as `curl -u me:secret …` or `TOKEN=… gh …` can. The helper reads the start of the command as the shell would, with its quotes. It skips the commands that only set up the shell, such as `cd … &&`, `export …;` and `source …`, and any `VAR=value` before the program, and looks through `bash -c` and `env`. Then it keeps the program's name, without its folder, and the word right after it, but only when that word looks like a subcommand or a file's name: lowercase letters, digits, dots and dashes, and no more than 24 characters. It never skips an option to find that word, because an option's value can be the secret, so `curl -u me:secret https://…` is just "curl". Git is the one exception, since `git -C <path>` is common and git's own options are known. When no program can be told, as in `$(which git) push`, the line is "Running a command". Codex's `PermissionRequest` can carry a description too, but Codex doesn't promise one for every tool, so its commands always show their program.

Claude's description of a command, a subagent's description and the reply's first line are the agent's own words, and they can say anything, including what's in a file. They're what the agent already shows the person in its own window, and they're cut short like every line.

**Every line is one line of at most 120 characters,** and at most 480 bytes, for characters made of many parts. Longer text is cut at a word where it can be, and ends with an ellipsis. With a folder of up to 4 KB and the rest of its fields, an event stays under 8 KB.

**When a payload is too big to read as JSON,** the helper already looks for the common fields in its first 64 KB, and it makes the line from what it finds there in the same way. The tool's name is enough for most lines, and a file's path comes before what's written to it, so a huge `Write` still says which file. A command or a reply that doesn't end within that part gives nothing, so the command is "Running a command" and the reply has no line.

**`AgentSessions` keeps the latest line for each session,** under the same rule as its phase, so a late event never replaces a newer line. A tool that starts or asks to be allowed brings its line. A tool that has finished leaves its line until the next one starts, so the tooltip doesn't flicker between a tool and nothing, and the task list's tools leave it too. A question is the exception: once `AskUserQuestion`, `ExitPlanMode` or Codex's `request_user_input` has finished, it has been answered, and "Asked a question" no longer holds while the agent works on, so its end clears the line. So does `PermissionDenied`, since the agent goes on without the tool it wanted. `Stop` brings the reply's line. A new turn, a new session, `StopFailure` and Codex's `Interrupt` clear it, and so does an answer from `claude agents --json` that changes the phase, since that answer says nothing about what the agent is doing. A subagent's own events never change the line, because its parent's "Subagent: …" already says what's going on.

**The tooltip and the worktree menu say it when one session is behind the mark:**

| | Tooltip | Worktree menu |
| --- | --- | --- |
| Working | Claude Code is working: Run the test suite, for 6 minutes | Claude Code: Run the test suite · 6 min |
| Waiting to be allowed | Codex is waiting for you to allow: git push, for 2 minutes | Codex needs your OK: git push · 2 min |
| Waiting for an answer | Claude Code is waiting for you: Wants a plan approved, for 2 minutes | Claude Code: Wants a plan approved · 2 min |
| Finished | Claude Code finished: Added the activity line to the tooltip | Claude Code finished |

The lines read as different parts of speech, "Run the test suite", "git push" and "Editing notes.txt", so each comes after a colon rather than inside a sentence. The menu now names the agent where decision 41 said "Agent", as in "Claude Code working · 6 min" before a session has a line, because the menu also has Roga's own lines, such as "Rebasing main · 2 conflicts", and a bare "git push · 6 min" could read as something Roga is doing. The menu leaves out a finished agent's reply, because its line is short and the worktree's folder follows it. A line of 120 characters is still too long for the menu's row, so when the row can't hold all of it, only the agent's words are cut short, at their end, and everything else on the line stays whole: how long, Roga's own parts, such as "Rebasing main · 2 conflicts" and "↑2", and enough of the folder to show the end of its name. Otherwise a long line would push those off the row, and could hide a worktree's conflicts. Until a session has a line, as before its first tool starts, the tooltip's words are decision 41's. So are the words for several sessions behind one mark, in the tooltip and the menu, as in "2 agents are working" and "2 agents working · 6 min", since one line can't speak for all of them. VoiceOver reads the line as part of the row, as it reads the mark.

The line is kept apart from what the marks are drawn from, since it changes with nearly every tool an agent starts. Only the rows that show a mark read it, so a new line redraws those rows and leaves the rest of the sidebar alone.

**The plugin doesn't change.** Its hooks, its events and its version stay as they were, because Codex ties its trust to a hash of the plugin's files, and any change would make people trust the hooks again.

## Consequences

- The program is a guess from a command's first words. A command run through a script or an alias shows the script or the alias, and one with an option before its subcommand shows only its program, as "npx" for `npx -y prettier`.
- The word after a program can be a file's name, as in "cat notes.txt". The file tools send a file's name anyway.
- Codex's lines weren't checked against a live session, because Codex runs only the hooks it has been told to trust. They follow its hooks' docs and generated schemas, and a tool named some other way shows its name.
- Task progress, plan mode, and tokens and cost wait, with the Work view, as issue 27 lists under Later.
