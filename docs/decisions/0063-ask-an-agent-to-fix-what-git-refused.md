# 63. Ask an agent to fix what git refused

Accepted on 2026-11-08. This adds a button to the dialog for a refusal from [decision 29](0029-dialogs-that-say-what-happens-and-show-the-command.md), and it runs an agent the way [decision 41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md) and [decision 60](0060-resolve-conflicts-in-the-diff-panel.md) do.

## Context

When git refuses something Roga has no dialog of its own for, Roga shows the command and what git said, with an OK button, and that's the end of what it can do. Sometimes git's words are enough. Often they aren't, and the case that started this shows why. A pull failed in every client with `fatal: bad object HEAD`, followed by a line saying that `git status --porcelain=2` failed in a submodule under `prototypes/git-access/.build`. Nothing about those lines says that the index held a gitlink for a folder that's in `.gitignore`, that the folder was SwiftPM's clone made with `--shared`, or that its objects had gone. Working that out took reading the index, the ignore rules and `.gitmodules`, and the repair was one command that needed an option git only mentions after you've tried without it.

An agent can usually work that out, if someone gives it the facts. But an agent with tools, turned loose on a repository that's already broken, is the wrong thing to reach for from a button, and a command that a person hasn't read shouldn't run because a model wrote it.

## Decision

**A refusal offers Fix with Claude.** A dialog from `DialogContent.refusal` that has a git command to show also has a button named after the agent Generate runs, as **Fix with Claude** or **Fix with Codex**, when that agent can be used. It's secondary, beside OK, because most refusals are read and dismissed.

**Roga gathers the facts itself, with commands that can't change anything.** It sends the command that failed and all of what git said, then the output of read-only commands: `git version`, `git status --porcelain=v1 --branch --ignore-submodules=all`, `git rev-parse HEAD`, what `.gitmodules` lists, and for each path that git's words name, `git ls-files --stage`, `git check-ignore --verbose --no-index` and `git ls-tree -r --name-only HEAD`. These run with `--no-optional-locks`, as background reads do. They have to survive the breakage they're describing, which is why `git status` ignores submodules, and why a command that fails is reported as a fact rather than stopping the rest. `--no-index` matters because without it `git check-ignore` says nothing about a path that's in the index, and a path that's both in the index and ignored is exactly what this case needed someone to notice.

**The agent has no tools, so it can only answer.** It runs as Resolve with Claude does, with the fixed rules on the command line and the facts on standard input, in tagged blocks whose token is new for every request. Everything in those blocks can come from the repository, including file names and what hooks printed, so the rules say that it's data, and the tags stop it from closing its block and passing itself off as Roga's instructions. The agent replies with one to three sentences and the git commands it would run, each as a JSON array of its arguments after `git`.

**Nothing runs until someone presses Run.** The answer is its own dialog, because a sheet can't change size once it's open. It says what the agent said and shows the commands in the terminal block, where Copy works as usual. Return doesn't press Run. Run is ink when every command keeps everything, such as `git rm --cached` or `git reset` without `--hard`, and red when anything could lose work, so that takes a click or Command-Return. Roga assumes a command can lose work unless it knows otherwise. The commands run one after the other through `GitRunner`, as arrays of arguments, never through a shell. The first one that fails stops the rest, and the dialog says which.

**Roga offers Run only for commands it can check.** The prompt can ask an agent to behave, but what's sent to it can come from the repository, so the check is in Roga's code and doesn't depend on the agent. A command can run only when all of this is true:

- Its first argument is a subcommand, so nothing goes before it. That rules out `-c`, `-C`, `--git-dir`, `--work-tree`, `--exec-path` and `--config-env`.
- That subcommand is on a short list of ones that repair things: `add`, `am`, `branch`, `checkout`, `cherry-pick`, `clean`, `fetch`, `fsck`, `gc`, `merge`, `mv`, `prune`, `pull`, `rebase`, `remote`, `reset`, `restore`, `revert`, `rm`, `stash`, `submodule`, `switch`, `symbolic-ref`, `tag`, `update-index`, `update-ref` and `worktree`. Being built in also rules out aliases, because git won't let an alias replace a built-in command. `config` isn't on the list, because it can name a program for git to run later.
- `remote`, `submodule` and `worktree` are limited to the verbs that repair: `remote prune`, `submodule` with `absorbgitdirs`, `deinit`, `init`, `sync` or `update`, and `worktree` with `prune`, `remove`, `repair` or `unlock`. So `submodule foreach` can't run.
- No option can start another program or open an editor. That means `--exec`, `--upload-pack`, `--receive-pack`, `--strategy`, `--ext-diff`, `--textconv`, `--interactive`, `--edit` and `--patch`, among others, and the short forms for the subcommands where they mean that, such as `rebase -x` and `merge -s`. git accepts a long option cut short when that's unambiguous, as in `--upload-pa`, so the check does too.
- `fetch` and `pull` name a remote, not a URL or a transport such as `ext::`, which is another way of starting a program.

Anything else still shows, with Copy, and with a line that says why Roga won't run it. If one command in the list can't run, none of them are offered, because the later ones usually depend on the earlier ones.

Commands run with `GIT_EDITOR` and `GIT_SEQUENCE_EDITOR` set to `true`, so that a `git merge --continue` that would open an editor finishes instead of waiting for something nobody can see.

**It doesn't retry what failed.** The rules tell the agent to leave that out. Once the commands have run, the dialog says so and Roga looks at the repository again, and someone presses Pull themselves. That keeps one thing happening per press.

**When git refuses a suggestion, the agent can be asked again.** The first try with a real agent on the case above diagnosed it correctly and wrote `git rm --cached` without `-f`, which git refused. The dialog that says so offers Fix with Claude again, and that request includes what was tried and what git said about it, in a block of its own, along with facts gathered afresh. It's a press each time rather than a loop, so a person still reads every command before it runs.

## Consequences

- Roga now runs commands that a model chose. The boundary is the list above and a person reading them. The list says what can start a program, not what's wise, so `git clean -fdx` or `git reset --hard` can still be offered, in red.
- A repository's hooks still run for these commands, as they do for Roga's own. The check is about what a command's arguments can start.
- The agent sees only what Roga gathered, and it can't look further. If the facts don't explain a failure, it should say so and offer no commands, and it may still be wrong when it doesn't.
- It's the agent and model that Generate uses, as in decision 60, which may be a small model chosen for commit messages.
- It's offered in a worktree's window, for what the title row and the panels refuse, including a checkout. A failure while opening a repository or deleting a worktree from the sidebar shows the same refusal without the button, because there's no worktree's window for it to belong to. Those could follow.
- A refusal that Roga has its own dialog for, such as a conflict or a branch that has diverged, doesn't get the button, because those dialogs already say what can be done.
- git's words and the state of the worktree are sent to the agent's provider, which is what pressing the button is for. Nothing is sent before that.
