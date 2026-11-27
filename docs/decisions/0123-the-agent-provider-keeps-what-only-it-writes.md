# 123. The agent provider keeps what only it writes, without reading it back

Accepted on 2026-11-27.

## Context

`AgentProvider` holds the custom agents and the default agent, and writes each change to UserDefaults as it makes it. It also reads its settings again whenever it hears `UserDefaults.didChangeNotification` ([decision 118](0118-follow-a-changed-setting-without-making-another-thread-wait-for-the-main-thread.md)). Until now that included these two, and whenever what it read differed from what it held, it took what it read.

On the Release workflow's runner for v0.0.10, `customAgentsCanBeTheDefaultUntilTheyreDeleted` failed twice in one run. After `updateCustomAgent` renamed Ollama to Qwen, the provider still called it Ollama, and after `deleteCustomAgent` it still listed it. The runner was running 1,398 tests at once on three cores, and the test took 177 seconds. Locally it takes about a second and has never failed.

The test runs on the main actor and doesn't suspend between its writes, so nothing else ran in between. Each write posted the notification on the main thread, which ran `reloadSettings` before the write returned. So the only way the agent could come back is that those reloads read the custom agents from the defaults and got them as they were just after the add, and the provider took that over the list it held. The test's own read of the default agent at the end, which the add came before, gave nil, which also fits defaults that stopped where the add left them.

What made the defaults read back an older value on the runner isn't certain, because it never happened here:

- In more than 300,000 reads of keys that the same process had just written, by up to six processes at once with every core busy, each read gave back what had been written. That included suites named by paths, as the tests' are, and reads that went to cfprefsd for new content.
- Three runs of the whole RogaUI suite at the runner's width passed this test, after 68, 137 and 53 seconds: two with every core busy, and one with room for only 256 open files, as a process started by launchd has. Nothing in that run said it had run out of files.
- A write made while the process has no file descriptors to spare doesn't reach cfprefsd or the file, although the process goes on reading what it wrote. In one trial, cfprefsd still held the agent as added after the process had renamed and deleted it, which is just what the provider read on the runner. If the process later dropped its own copy of what it wrote, it would read what cfprefsd holds. Nothing tried here made it drop that copy, so this is one way the runner could have come to read an older value, not a proven one.

Whatever the cause, reading these two back could never bring in anything new. Nothing else in Roga writes them, and the notification is posted only for changes made in this process, so a read could only give back what the provider held already, or something older.

## Decision

**The provider reads the custom agents and the default agent once, when it starts, and never reads them again.** From then on it's what changes them, through `addCustomAgent`, `updateCustomAgent`, `deleteCustomAgent` and `setDefaultAgent`, and it writes each change without reading it back. Anything else that changes either asks the provider.

It still reads again whether Roga uses agents, and each agent's program, model and effort, because Settings, the sidebar and setup write those themselves.

## Consequences

- A read that falls behind can no longer undo a rename, a delete, or a change of the default agent. Before, the next change after one would also have written the older list back, bringing a deleted agent back for good.
- In the app it mattered most while someone typed a custom agent's name or command, because Settings stores each key press. A read that fell behind would have dropped what was typed, and the next key press would have stored that.
- A change to either key from outside the provider isn't followed until Roga starts again. Nothing makes one, and a `defaults write` from Terminal wasn't followed before either. `followsChangesToTheDefaultsByItself` now changes a model instead of the default agent.
- `keepsWhatItWroteWhenTheDefaultsReadBackSomethingOlder` gives the provider defaults that keep reading back the custom agents and the default agent as they were just after an add, as the runner's did, and changes another setting in between so that the provider reads its settings again. It failed with the provider that read them again.
- The settings the provider still reads again, like every `@AppStorage`, would follow defaults that fell behind. They have other writers, so the provider can't hold them itself.
