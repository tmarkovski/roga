# 52. Maximize or minimize the panels under history

Accepted on 2026-11-07.

## Context

The commit and diff panels share the middle of the window with history above them and the refs panel beside them. A long or wide diff, or a commit with many files, wants more room than the split gives, and dragging the line up and back loses the height the panels had. Going through history wants the opposite, with the panels out of the way. Until now, the line between them was the only way to change that, and it kept each side at least 100 points tall.

## Decision

**Two buttons at the right end of the diff panel's header**, the top right corner of what they act on, as in VS Code's and JetBrains' panels. Minimize uses Lucide's `panel-bottom-close`, from the family of the buttons for the sidebar and the refs panel, and Maximize uses `maximize-2`. While its size is on, each turns into Restore Panels, with `panel-bottom-open` and `minimize-2`, and keeps its place, so pressing the same button twice gets back to where it started. We didn't use chevrons, because Find's Previous and Next Match buttons already sit beside them with chevrons up and down. Tooltips and menus never say a bare Restore, which in a Git client reads as `git restore`.

**Maximized, the panels cover history and the refs panel, up to the title row,** and leave the sidebar. The refs panel hides rather than sitting under them, and asking for it, with Show Refs, its button or Switch Branch… from the branch's menu, puts the panels back first. The title row stays as it is, with history's count and Order menu.

**Minimized, they show only their headers,** 40 points tall, so their titles, the files' filter, Find and these buttons stay where they were, and history takes the rest.

**It's one setting for each window,** like whether the refs panel shows, so it stays from one worktree to the next and comes back when macOS restores the window. The heights someone dragged, for a commit and for uncommitted changes, stay as they were underneath and come back with Restore.

**View > Maximize Panels and Minimize Panels go a step at a time,** with Control-Command-Up Arrow and Control-Command-Down Arrow, the way the arrows point. Up from minimized puts the panels back, and up again maximizes them. While a step back is what an item does, it reads Restore Panels, and the item with no step left is off. The buttons go straight to their size instead, so Maximize from minimized maximizes.

**Dragging the line folds the panels down too.** Dragged below halfway between a header and the shortest panel, they minimize, and dragging a minimized panel's line up brings them back at the height the drag reaches.

**History and the panels stay in place underneath,** with no height, rather than being taken out, so that history's scrolling and selection and the diff's place are where they were when they come back.

## Consequences

- Reviewing a diff no longer costs the height someone set for the split.
- The diff panel's header holds two more buttons, 64 points. In the narrowest diff panel, 180 points, the file's path gives way to them. With Find open, they left the box too narrow to type in, so Find's Previous and Next Match buttons now give way below 240 points, since Return, Shift-Return and Command-G do the same. The buttons for the panels' size stay, so Restore Panels is always there.
- The refs panel can't show while the panels are maximized, and asking for it ends the maximized state, which could surprise someone who expected both.
- While the panels are maximized, history can't be clicked, so going to another commit means putting them back first.
