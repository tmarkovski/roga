# 84. Headers show no counts

Accepted on 2026-11-15. This changes [decision 53](0053-organizations-as-groups-in-the-list-and-add-and-settings-at-the-top.md), whose header for the sidebar's list said how many repositories it has, and the refs panel's sections, whose headers have said how many rows each has since the panel was built.

## Context

The sidebar's header and the refs panel's headers put their counts in different places. **Repositories 3** had its count right after the title, with Group and Sort at the right. **Branches**, **Tags**, **Stashes** and **Submodules** had theirs at the right edge, and **Remotes** had its + there in place of its count.

Moving one to match the other would have hidden the real question, which is what those numbers are for. A gray number beside a title looks like the numbers that ask for something: a row's uncommitted files in the sidebar, a branch's commits ahead and behind, an unread count. These say only how many there are, which the rows show once the section is open, and nothing changes with them. While a filter is on, sections can't be collapsed, so the rows already show what it found.

Branch folders already went without a count on their row, with how many branches they hold in their tooltip ([decision 50](0050-branches-in-folders-at-each-slash-of-their-names.md)).

## Decision

**A header shows its title, and at its right only its commands.** The sidebar's has Group and Sort, Remotes has its +, and the others have nothing there yet.

**How many it has is in its tooltip,** as a folder's is, as in **12 branches** or **3 repositories**, and VoiceOver still says it.

## Consequences

- A number on its own in the sidebar or the refs panel says there's something to do, such as files to commit or commits to pull.
- A collapsed section doesn't say how big it is until the pointer rests on it.
- Headings over files, in the commit panel and the panel for uncommitted changes, keep how many files they have and how many lines change. There the number is the changes, which is what it looks like it says.
- History's number of commits keeps its word, as in **324 commits** ([decision 45](0045-fetch-and-new-branch-as-buttons-and-the-commit-count-with-history.md)), so it doesn't read as a badge.
- The right of a section's header is free for its commands, such as making a branch or a tag, which the spec has planned since the refs panel was built.
