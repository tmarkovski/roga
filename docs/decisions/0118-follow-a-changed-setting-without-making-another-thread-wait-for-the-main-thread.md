# 118. Follow a changed setting without making another thread wait for the main thread

Accepted on 2026-11-27.

## Context

Two models on the main actor follow a setting as it changes: `BranchModel` reads again whether the house plays, and `AgentProvider` reads again which agents Roga uses. Each heard `UserDefaults.didChangeNotification` through an observer added with `queue: .main`. Notification center runs such an observer by adding it to the main operation queue, and the thread that posted the notification waits there until the main thread has run it.

AppKit's text classes register defaults of their own the first time they're used. `NSParagraphArbitrator` does it from `+initialize`, so the thread that first lays out text holds the lock that the Objective-C runtime keeps while a class starts up, and posts the notification from inside it. `DiffMetrics` measures its baseline with an `NSLayoutManager`, and it isn't on the main actor, so a diff's metrics can be the first text laid out away from the main thread.

When that happened while the main thread was laying out text of its own, both threads stopped. The other thread waited for the main thread to run the observer, and the main thread waited for the class to finish starting up, which needed the other thread to go on. In the tests, measuring a dialog's height lays out the `CommandBlock` in it, and every test process starts with AppKit's text classes unused, so the full test run could hang. In one run, 88 of `BranchModelTests`' 126 tests never finished, and the `@MainActor` suites that ran after them, such as `RepositoryListTests` and `WorktreeDeletionModelTests`, timed out behind them. The app lays out text on the main thread as soon as its window opens, so it would most likely have started the class up there first, but nothing made sure of that.

One test also waited for the main actor in a loop of `Task.yield()`. While the main thread was stuck, that loop never ended, and a time limit can't stop it, since it never checks whether it's been cancelled. In one run it kept a core busy for 30 minutes.

## Decision

**A model on the main actor follows a setting through `DefaultsChanges.observe`, never through an observer on the main queue.** `DefaultsChanges` hears the notification on whichever thread posted it. On the main thread it runs the model's closure right away, so a change made there is followed before the change returns, as before. On any other thread it asks the main actor to run the closure later and returns at once, so the thread that changed the defaults never waits for the main thread. `BranchModel` and `AgentProvider` both use it.

Observers of notifications that AppKit only posts on the main thread, such as `NSApplication.willTerminateNotification` and `didBecomeActiveNotification`, keep `queue: .main`, because no other thread waits for them.

**A test that waits for the main actor gives up.** It waits through `AgentTestSupport.eventually`, which stops after a few seconds and fails the test, rather than in a loop that only ends when the condition is met.

## Consequences

- The RogaUI suite no longer hangs when a diff's metrics are measured during a test that lays out text.
- A setting changed on another thread is followed a moment later, once the main thread is free, rather than before the change returns. The two models read the setting again when they hear of the change, so that's the only difference.
- `DefaultsChangesTests` changes the defaults from another thread while the main thread waits, and fails if the change doesn't come back within five seconds. It failed that way with the observer on the main queue.
- A model that later follows a setting uses `DefaultsChanges` too. An observer of any other notification that another thread might post doesn't use `queue: .main` either, for the same reason.
