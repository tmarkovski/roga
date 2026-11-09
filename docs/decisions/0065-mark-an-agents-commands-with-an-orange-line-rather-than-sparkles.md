# 65. Mark an agent's commands with an orange line, rather than sparkles

Accepted on 2026-11-09, and built the same day. This replaces the sparkles that [decision 41](0041-agents-status-from-their-hooks-and-messages-from-their-clis.md), [decision 60](0060-resolve-conflicts-in-the-diff-panel.md) and [decision 63](0063-ask-an-agent-to-fix-what-git-refused.md) used for what an agent does. Everything else about those stays as decided.

## Context

Roga runs people's own agents to write commit messages, resolve conflicts and fix what git refused, and that's one of the things that sets it apart. Those commands carried Lucide's sparkles, which have become the sign of an app that was generated, so Roga's best feature looked like everyone's least considered one.

We drew six replacements next to the sparkles on the Agent actions page of the design canvas: a thin orange line, that line with a light running around it, the sidebar's ring as a symbol, a shell prompt, the agent's name as half of the button, and a soft orange wash. The generator is in [`docs/design/agent-actions`](../design/agent-actions).

## Decision

**The words say who does it, and a thin orange line says it's an agent.** Generate with Claude, Resolve with Claude and Fix with Claude have no icon. Each has a one-point line in the brand's orange at about half strength, which stands still and turns gray when the button can't be pressed. Fix with Claude is a new kind of dialog button, a secondary one with that line.

**A light runs around the line once when the pointer arrives.** It's one color, the brand's orange with a brighter front, and it never moves at rest. An animated glowing border is the sparkle's closest relative, especially in a gradient of purple and pink, so it's kept to the moment someone is about to press the button.

**While an agent works, the light runs around what it's working on rather than around the button**, so it says where the work is happening. Those are the message box, each unresolved conflict in view, and, while Roga waits for an agent to answer, along the top of the dialog's command block. The buttons step aside during the work, as they already did. The conflict's outline scrolls with the text.

**The sidebar's ring and blue dot replace the spinners and the sparkles for working and finished**, in the line under the message box and the strip above a conflicted file, so there's no new symbol to learn. The blue dot means what it does in the sidebar: it finished, and you haven't looked yet.

**With words in the box, the button says Rewrite.** It used to be sparkles alone, and with no icon it needs a word. Its tooltip and VoiceOver label still name the agent.

**Menus stay as they are.** A menu's row can't carry a line, and the words already say "with Claude Code".

**Core Animation plays all of it**, as it does the sidebar's ring ([decision 46](0046-turn-the-ring-of-an-agent-at-work.md)), so neither SwiftUI nor the main thread does anything for each frame. The light stops while its window can't be seen. For someone who asked for less motion, the line brightens and stays still.

The sparkles are gone from the icons, so that they aren't reached for again.

## Consequences

- `DiffUI` knows nothing about agents. `DiffTextController` asks its owner to make what goes around a conflict, and places those views around the whole section, line numbers included.
- A long way around keeps a short light that moves a little slower, up to four seconds a lap, or a conflict's outline would have a light as long as the window.
- `Palette.action` still means what a click would run right now, which an agent's button does, so it stays orange rather than getting a hue of its own.
- The light's front has a soft glow, which the render server draws for each frame while an agent works. Generating and resolving end within their time limits, so it isn't something that plays for hours as the ring can.

## Alternatives considered

- **The line alone**, with no motion. It's the quietest, but nothing says that an agent is at work on the box itself.
- **The sidebar's ring as the symbol, with a dot in the middle at rest.** A quarter of a ring that doesn't move reads as stuck, which is why decision 46 made it turn, and with a dot it looks like a radio button at this size.
- **A shell prompt and the command's name in monospace.** It's the most literal way to say "on your machine", but `claude` in monospace reads like code in the middle of a sentence.
- **The agent's name as half of the button.** It suits the commit box's chooser, but Resolve and Fix have nothing to choose.
- **A soft orange wash.** It reads as a tag or as something already selected.
- **The agents' own logos.** Settings already went without them, and Claude's is a starburst.
